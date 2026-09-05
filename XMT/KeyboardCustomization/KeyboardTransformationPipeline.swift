import Foundation

struct KeyboardAttachmentID: Hashable, Sendable {
    let value: UUID
    init(_ value: UUID = UUID()) { self.value = value }
}

struct KeyboardAttachedDevice: Equatable, Sendable {
    let attachment: KeyboardAttachmentID
    let descriptor: KeyboardDeviceDescriptor
}

enum KeyboardPhysicalEvent: Equatable, Sendable {
    case keyDown(attachment: KeyboardAttachmentID, key: KeyCode, isRepeat: Bool)
    case keyUp(attachment: KeyboardAttachmentID, key: KeyCode)
    case deadline
}

enum KeyboardPipelineError: Error, Equatable, Sendable {
    case stalePolicy(current: KeyboardPolicyRevision, offered: KeyboardPolicyRevision)
    case admissionFull(limit: Int)
    case runtimeFailed
    case teardownInProgress
    case stopped
    case sinkFailed
    case resolutionFailed(KeyboardResolutionFailure)
    case operationTimedOut
}

/// Pure owner-side transformation boundary. Inventory identity is resolved before key state enters
/// the tap/hold resolver, and a policy replacement first balances all active virtual output.
struct KeyboardTransformationPipeline {
    private(set) var policy: ValidatedKeyboardOwnerPolicy
    private(set) var inventory: [KeyboardAttachedDevice] = []
    private(set) var resolvedDevices: [KeyboardAttachmentID: KeyboardDeviceID] = [:]
    private var resolver: TapHoldResolver
    private var deadline: KeyboardInstant?

    init(policy: ValidatedKeyboardOwnerPolicy) {
        self.policy = policy
        resolver = TapHoldResolver(configuration: policy.configuration)
    }

    mutating func replacePolicy(_ replacement: ValidatedKeyboardOwnerPolicy,
                                at instant: KeyboardInstant) throws -> KeyboardResolution {
        guard replacement.revision > policy.revision else {
            throw KeyboardPipelineError.stalePolicy(current: policy.revision, offered: replacement.revision)
        }
        let previousResolved = resolvedDevices
        policy = replacement
        let replacementResolved = resolveInventory(inventory)
        var outputs: [KeyboardOutput] = []
        var failure: KeyboardResolutionFailure?
        for (attachment, device) in previousResolved where replacementResolved[attachment] != device {
            let removal = resolver.receive(.deviceRemoved(device), at: instant)
            outputs += removal.outputs
            deadline = removal.deadline
            failure = failure ?? removal.failure
        }
        let update = resolver.receive(.configurationReplaced(replacement.configuration), at: instant)
        outputs += update.outputs
        resolvedDevices = replacementResolved
        deadline = update.deadline
        failure = failure ?? update.failure
        return .init(outputs: outputs, deadline: deadline, isInScope: true, failure: failure)
    }

    mutating func replaceInventory(_ replacement: [KeyboardAttachedDevice],
                                   at instant: KeyboardInstant) -> KeyboardResolution {
        var outputs: [KeyboardOutput] = []
        let replacementResolved = resolveInventory(replacement)
        for (attachment, device) in resolvedDevices where replacementResolved[attachment] != device {
            let result = resolver.receive(.deviceRemoved(device), at: instant)
            outputs += result.outputs
            deadline = result.deadline
        }
        inventory = replacement
        resolvedDevices = replacementResolved
        return .init(outputs: outputs, deadline: deadline, isInScope: true)
    }

    mutating func receive(_ event: KeyboardPhysicalEvent,
                          at instant: KeyboardInstant) -> KeyboardResolution {
        switch event {
        case .keyDown(let attachment, let key, let isRepeat):
            guard let device = resolvedDevices[attachment] else {
                return outOfScopeResult()
            }
            return record(resolver.receive(.keyDown(device: device, key: key, isRepeat: isRepeat), at: instant))
        case .keyUp(let attachment, let key):
            guard let device = resolvedDevices[attachment] else {
                return outOfScopeResult()
            }
            return record(resolver.receive(.keyUp(device: device, key: key), at: instant))
        case .deadline:
            return record(resolver.receive(.deadline, at: instant))
        }
    }

    mutating func teardown(at instant: KeyboardInstant) -> KeyboardResolution {
        resolvedDevices.removeAll()
        inventory.removeAll()
        return record(resolver.receive(.teardown, at: instant))
    }

    private func resolveInventory(_ candidate: [KeyboardAttachedDevice]) -> [KeyboardAttachmentID: KeyboardDeviceID] {
        let descriptors = candidate.map(\.descriptor)
        let attachmentCounts = Dictionary(grouping: candidate, by: \.attachment).mapValues(\.count)
        var replacement: [KeyboardAttachmentID: KeyboardDeviceID] = [:]
        for attached in candidate where attachmentCounts[attached.attachment] == 1 {
            if let id = policy.deviceID(for: attached.descriptor, in: descriptors) {
                replacement[attached.attachment] = id
            }
        }
        return replacement
    }

    private func outOfScopeResult() -> KeyboardResolution {
        .init(outputs: [], deadline: deadline, isInScope: false)
    }

    private mutating func record(_ result: KeyboardResolution) -> KeyboardResolution {
        deadline = result.deadline
        return result
    }
}

protocol KeyboardVirtualOutputSink: Sendable {
    func emit(_ outputs: [KeyboardOutput]) async throws
}

protocol KeyboardTransformationOperationDeadline: Sendable {
    func wait() async
}

struct KeyboardTransformationTwoSecondDeadline: KeyboardTransformationOperationDeadline {
    func wait() async {
        try? await Task.sleep(for: .seconds(2))
    }
}

/// Effectful wrapper used by the future owner helper and by fake integration tests. Calls are
/// admitted into an explicit bounded FIFO because actor reentrancy alone does not order awaits.
actor KeyboardTransformationRuntime {
    private enum State { case operating, failed, teardownQueued, stopped }
    private enum Result {
        case deadline(KeyboardInstant?)
        case resolution(KeyboardResolution)
        case tornDown
    }
    private enum Operation {
        case inventory([KeyboardAttachedDevice], KeyboardInstant, CheckedContinuation<Result, Error>)
        case policy(ValidatedKeyboardOwnerPolicy, KeyboardInstant, CheckedContinuation<Result, Error>)
        case event(KeyboardPhysicalEvent, KeyboardInstant, CheckedContinuation<Result, Error>)
        case teardown(KeyboardInstant, CheckedContinuation<Result, Error>)

        var continuation: CheckedContinuation<Result, Error> {
            switch self {
            case .inventory(_, _, let value), .policy(_, _, let value),
                 .event(_, _, let value), .teardown(_, let value): value
            }
        }
    }
    private struct QueuedOperation {
        let operation: Operation
        let admittedAt: ContinuousClock.Instant
    }

    private var pipeline: KeyboardTransformationPipeline
    private let sink: any KeyboardVirtualOutputSink
    private let admissionLimit: Int
    private let operationDeadline: any KeyboardTransformationOperationDeadline
    private let failureHandler: @Sendable (KeyboardPipelineError) -> Void
    private var state = State.operating
    private var queue: [QueuedOperation] = []
    private var drainIsRunning = false
    private var operationIsExecuting = false
    private var sinkOperationIsActive = false
    private var sinkCompletions: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var sinkTasks: [UUID: Task<Void, Never>] = [:]
    private var deadlineTasks: [UUID: Task<Void, Never>] = [:]
    private var timedOutSinkOperations: Set<UUID> = []
    private var pendingTeardownResolution: KeyboardResolution?
    /// Conservative output ledger. A failed batch may have been applied partially, so its downs
    /// are treated as live and its ups remain owed until a successful neutralizing batch.
    private var possiblyDownKeys: Set<KeyCode> = []
    private var possiblyDownModifiers: Set<KeyModifier> = []

    var queuedOperationCount: Int { queue.count }

    init(policy: ValidatedKeyboardOwnerPolicy,
         sink: any KeyboardVirtualOutputSink,
         admissionLimit: Int = 64,
         operationDeadline: any KeyboardTransformationOperationDeadline = KeyboardTransformationTwoSecondDeadline(),
         failureHandler: @escaping @Sendable (KeyboardPipelineError) -> Void) {
        precondition(admissionLimit > 0)
        pipeline = KeyboardTransformationPipeline(policy: policy)
        self.sink = sink
        self.admissionLimit = admissionLimit
        self.operationDeadline = operationDeadline
        self.failureHandler = failureHandler
    }

    func replaceInventory(_ inventory: [KeyboardAttachedDevice],
                          at instant: KeyboardInstant) async throws -> KeyboardInstant? {
        let result = try await submit { .inventory(inventory, instant, $0) }
        guard case .deadline(let deadline) = result else { preconditionFailure("invalid operation result") }
        return deadline
    }

    func replacePolicy(_ policy: ValidatedKeyboardOwnerPolicy,
                       at instant: KeyboardInstant) async throws -> KeyboardInstant? {
        let result = try await submit { .policy(policy, instant, $0) }
        guard case .deadline(let deadline) = result else { preconditionFailure("invalid operation result") }
        return deadline
    }

    func receive(_ event: KeyboardPhysicalEvent,
                 at instant: KeyboardInstant) async throws -> KeyboardResolution {
        let result = try await submit { .event(event, instant, $0) }
        guard case .resolution(let resolution) = result else { preconditionFailure("invalid operation result") }
        return resolution
    }

    func teardown(at instant: KeyboardInstant) async throws {
        let result = try await submit { .teardown(instant, $0) }
        guard case .tornDown = result else { preconditionFailure("invalid operation result") }
    }

    private func submit(_ makeOperation: (CheckedContinuation<Result, Error>) -> Operation) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            admit(makeOperation(continuation))
        }
    }

    private func admit(_ operation: Operation) {
        let isTeardown: Bool
        if case .teardown = operation { isTeardown = true } else { isTeardown = false }

        switch state {
        case .operating:
            break
        case .failed where isTeardown:
            guard !sinkOperationIsActive else {
                operation.continuation.resume(throwing: KeyboardPipelineError.teardownInProgress)
                return
            }
            break
        case .failed:
            operation.continuation.resume(throwing: KeyboardPipelineError.runtimeFailed)
            return
        case .teardownQueued:
            operation.continuation.resume(throwing: KeyboardPipelineError.teardownInProgress)
            return
        case .stopped:
            operation.continuation.resume(throwing: KeyboardPipelineError.stopped)
            return
        }

        let admittedCount = queue.count + (operationIsExecuting ? 1 : 0)
        guard admittedCount < admissionLimit || isTeardown else {
            state = .failed
            failureHandler(.admissionFull(limit: admissionLimit))
            rejectQueuedOperationsAfterFailure()
            operation.continuation.resume(throwing: KeyboardPipelineError.admissionFull(limit: admissionLimit))
            return
        }
        if isTeardown { state = .teardownQueued }
        queue.append(.init(operation: operation, admittedAt: .now))
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard !drainIsRunning else { return }
        drainIsRunning = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let queued = queue.removeFirst()
            let operation = queued.operation
            operationIsExecuting = true
            if case .teardown = operation, sinkOperationIsActive {
                state = .failed
                operation.continuation.resume(throwing: KeyboardPipelineError.teardownInProgress)
                operationIsExecuting = false
                continue
            }
            if ContinuousClock.now - queued.admittedAt >= .seconds(2) {
                state = .failed
                failureHandler(.operationTimedOut)
                rejectQueuedOperationsAfterFailure()
                operation.continuation.resume(throwing: KeyboardPipelineError.operationTimedOut)
                operationIsExecuting = false
                continue
            }
            do {
                let result = try await perform(operation)
                operation.continuation.resume(returning: result)
            } catch let error as KeyboardPipelineError {
                if case .stalePolicy = error {
                    operation.continuation.resume(throwing: error)
                    operationIsExecuting = false
                    continue
                }
                state = .failed
                failureHandler(error)
                if case .teardown = operation {} else { rejectQueuedOperationsAfterFailure() }
                operation.continuation.resume(throwing: error)
            } catch {
                if case .teardown = operation {
                    state = .failed
                    failureHandler(.sinkFailed)
                } else {
                    state = .failed
                    failureHandler(.sinkFailed)
                    rejectQueuedOperationsAfterFailure()
                }
                operation.continuation.resume(throwing: KeyboardPipelineError.sinkFailed)
            }
            operationIsExecuting = false
        }
        drainIsRunning = false
    }

    private func perform(_ operation: Operation) async throws -> Result {
        switch operation {
        case .inventory(let inventory, let instant, _):
            let resolution = pipeline.replaceInventory(inventory, at: instant)
            try await emit(resolution)
            return .deadline(resolution.deadline)
        case .policy(let policy, let instant, _):
            let resolution = try pipeline.replacePolicy(policy, at: instant)
            try await emit(resolution)
            return .deadline(resolution.deadline)
        case .event(let event, let instant, _):
            let resolution = pipeline.receive(event, at: instant)
            try await emit(resolution)
            return .resolution(resolution)
        case .teardown(let instant, _):
            let resolution: KeyboardResolution
            if let pendingTeardownResolution {
                resolution = pendingTeardownResolution
            } else {
                var candidate = pipeline.teardown(at: instant)
                let releasedKeys = Set(candidate.outputs.compactMap { output -> KeyCode? in
                    if case .keyUp(let key) = output { return key }
                    return nil
                })
                let releasedModifiers = Set(candidate.outputs.compactMap { output -> KeyModifier? in
                    if case .modifierUp(let modifier) = output { return modifier }
                    return nil
                })
                candidate.outputs += possiblyDownKeys.subtracting(releasedKeys).sorted().reversed().map(KeyboardOutput.keyUp)
                candidate.outputs += possiblyDownModifiers.subtracting(releasedModifiers).sorted().reversed().map(KeyboardOutput.modifierUp)
                resolution = candidate
                pendingTeardownResolution = candidate
            }
            try await emit(resolution)
            pendingTeardownResolution = nil
            possiblyDownKeys.removeAll()
            possiblyDownModifiers.removeAll()
            state = .stopped
            return .tornDown
        }
    }

    private func emit(_ resolution: KeyboardResolution) async throws {
        let operationID = UUID()
        sinkOperationIsActive = true
        let sink = self.sink
        let deadline = operationDeadline
        do {
            try await withCheckedThrowingContinuation { continuation in
                sinkCompletions[operationID] = continuation
                let sinkTask = Task { [weak self] in
                    do {
                        try await sink.emit(resolution.outputs)
                        await self?.finishSinkOperation(operationID, error: nil)
                    } catch {
                        await self?.finishSinkOperation(operationID, error: .sinkFailed)
                    }
                }
                sinkTasks[operationID] = sinkTask
                let deadlineTask = Task { [weak self] in
                    await deadline.wait()
                    guard !Task.isCancelled else { return }
                    await self?.timeoutSinkOperation(operationID)
                }
                deadlineTasks[operationID] = deadlineTask
            }
            recordSuccessfulEmission(resolution.outputs)
        } catch {
            recordPotentiallyPartialEmission(resolution.outputs)
            throw error
        }
        if let failure = resolution.failure {
            throw KeyboardPipelineError.resolutionFailed(failure)
        }
    }

    private func recordSuccessfulEmission(_ outputs: [KeyboardOutput]) {
        for output in outputs {
            switch output {
            case .keyDown(let key): possiblyDownKeys.insert(key)
            case .keyUp(let key): possiblyDownKeys.remove(key)
            case .modifierDown(let modifier): possiblyDownModifiers.insert(modifier)
            case .modifierUp(let modifier): possiblyDownModifiers.remove(modifier)
            }
        }
    }

    private func recordPotentiallyPartialEmission(_ outputs: [KeyboardOutput]) {
        for output in outputs {
            switch output {
            case .keyDown(let key): possiblyDownKeys.insert(key)
            case .modifierDown(let modifier): possiblyDownModifiers.insert(modifier)
            case .keyUp, .modifierUp: break
            }
        }
    }

    private func finishSinkOperation(_ id: UUID, error: KeyboardPipelineError?) {
        sinkOperationIsActive = false
        sinkTasks[id] = nil
        deadlineTasks.removeValue(forKey: id)?.cancel()
        timedOutSinkOperations.remove(id)
        guard let continuation = sinkCompletions.removeValue(forKey: id) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private func timeoutSinkOperation(_ id: UUID) {
        guard let continuation = sinkCompletions.removeValue(forKey: id) else { return }
        timedOutSinkOperations.insert(id)
        sinkTasks[id]?.cancel()
        deadlineTasks[id] = nil
        continuation.resume(throwing: KeyboardPipelineError.operationTimedOut)
    }

    private func rejectQueuedOperationsAfterFailure() {
        var teardown: QueuedOperation?
        for queued in queue {
            let operation = queued.operation
            if case .teardown = operation, teardown == nil {
                teardown = queued
            } else {
                operation.continuation.resume(throwing: KeyboardPipelineError.runtimeFailed)
            }
        }
        queue = teardown.map { [$0] } ?? []
        if teardown == nil { state = .failed }
    }
}
