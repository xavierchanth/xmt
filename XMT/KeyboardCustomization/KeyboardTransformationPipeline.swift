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
        let result = resolver.receive(.configurationReplaced(replacement.configuration), at: instant)
        policy = replacement
        resolvedDevices = resolveInventory(inventory)
        deadline = result.deadline
        return result
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

/// Effectful wrapper used by the future owner helper and by fake integration tests. It schedules
/// only the deadline explicitly returned by the pure resolver; an idle pipeline requests none.
actor KeyboardTransformationRuntime {
    private var pipeline: KeyboardTransformationPipeline
    private let sink: any KeyboardVirtualOutputSink

    init(policy: ValidatedKeyboardOwnerPolicy, sink: any KeyboardVirtualOutputSink) {
        pipeline = KeyboardTransformationPipeline(policy: policy)
        self.sink = sink
    }

    func replaceInventory(_ inventory: [KeyboardAttachedDevice],
                          at instant: KeyboardInstant) async throws -> KeyboardInstant? {
        try await emit(pipeline.replaceInventory(inventory, at: instant))
    }

    func replacePolicy(_ policy: ValidatedKeyboardOwnerPolicy,
                       at instant: KeyboardInstant) async throws -> KeyboardInstant? {
        try await emit(try pipeline.replacePolicy(policy, at: instant))
    }

    func receive(_ event: KeyboardPhysicalEvent,
                 at instant: KeyboardInstant) async throws -> KeyboardResolution {
        let result = pipeline.receive(event, at: instant)
        try await sink.emit(result.outputs)
        return result
    }

    func teardown(at instant: KeyboardInstant) async throws {
        _ = try await emit(pipeline.teardown(at: instant))
    }

    private func emit(_ result: KeyboardResolution) async throws -> KeyboardInstant? {
        try await sink.emit(result.outputs)
        return result.deadline
    }
}
