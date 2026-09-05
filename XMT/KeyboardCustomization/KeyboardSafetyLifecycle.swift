import Foundation

struct KeyboardSafetyFailureThreshold: Equatable, Sendable {
    let value: Int
    init?(_ value: Int) { guard value > 0 else { return nil }; self.value = value }
}

struct KeyboardSafetySessionID: Codable, Equatable, Hashable, Sendable {
    let value: UUID
    init(_ value: UUID = UUID()) { self.value = value }
}

struct KeyboardSafetyLeaseID: Codable, Equatable, Hashable, Sendable {
    let session: KeyboardSafetySessionID
    let value: UUID
    init(session: KeyboardSafetySessionID, value: UUID = UUID()) {
        self.session = session
        self.value = value
    }
}

struct KeyboardOutputEndpointID: Codable, Equatable, Hashable, Sendable {
    let session: KeyboardSafetySessionID
    let generation: UInt64

    init?(session: KeyboardSafetySessionID, generation: UInt64) {
        guard generation > 0 else { return nil }
        self.session = session
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey { case session, generation }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let session = try box.decode(KeyboardSafetySessionID.self, forKey: .session)
        let generation = try box.decode(UInt64.self, forKey: .generation)
        guard let value = Self(session: session, generation: generation) else {
            throw DecodingError.dataCorruptedError(forKey: .generation, in: box, debugDescription: "generation must be positive")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(session, forKey: .session)
        try box.encode(generation, forKey: .generation)
    }
}

struct KeyboardWatchdogID: Codable, Equatable, Hashable, Sendable {
    let session: KeyboardSafetySessionID
    let generation: UInt64

    init?(session: KeyboardSafetySessionID, generation: UInt64) {
        guard generation > 0 else { return nil }
        self.session = session
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey { case session, generation }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let session = try box.decode(KeyboardSafetySessionID.self, forKey: .session)
        let generation = try box.decode(UInt64.self, forKey: .generation)
        guard let value = Self(session: session, generation: generation) else {
            throw DecodingError.dataCorruptedError(forKey: .generation, in: box, debugDescription: "generation must be positive")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(session, forKey: .session)
        try box.encode(generation, forKey: .generation)
    }
}

struct KeyboardPolicyRevision: Codable, Equatable, Hashable, Comparable, Sendable {
    let value: UInt64
    init?(_ value: UInt64) { guard value > 0 else { return nil }; self.value = value }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt64.self)
        guard let revision = Self(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "revision must be positive")
        }
        self = revision
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct KeyboardSafetyAttemptID: Codable, Equatable, Hashable, Sendable {
    let session: KeyboardSafetySessionID
    let sequence: UInt64

    init?(session: KeyboardSafetySessionID, sequence: UInt64) {
        guard sequence > 0 else { return nil }
        self.session = session
        self.sequence = sequence
    }

    fileprivate init(session: KeyboardSafetySessionID, validatedSequence: UInt64) {
        self.session = session
        sequence = validatedSequence
    }

    private enum CodingKeys: String, CodingKey { case session, sequence }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let session = try box.decode(KeyboardSafetySessionID.self, forKey: .session)
        let sequence = try box.decode(UInt64.self, forKey: .sequence)
        guard let value = Self(session: session, sequence: sequence) else {
            throw DecodingError.dataCorruptedError(forKey: .sequence, in: box, debugDescription: "sequence must be positive")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(session, forKey: .session)
        try box.encode(sequence, forKey: .sequence)
    }
}

/// Pure reducer for the protected-input safety boundary. Every asynchronous prerequisite carries
/// its owner session, so a delayed message from a prior helper lifetime cannot become current.
struct KeyboardSafetyLifecycle: Equatable, Sendable {
    enum Ownership: Equatable, Sendable {
        case none
        case requested(KeyboardSafetyAttemptID)
        case owned(KeyboardSafetyAttemptID)
        case releasing(KeyboardSafetyAttemptID)
    }

    enum Lifecycle: Equatable, Sendable {
        case stopped
        case running(KeyboardSafetySessionID)
    }

    enum Event: Equatable, Sendable {
        case start(KeyboardSafetySessionID)
        case stop
        case outputReady(KeyboardOutputEndpointID)
        case outputLost(KeyboardOutputEndpointID)
        case leaseGranted(KeyboardSafetyLeaseID)
        case leaseLost(KeyboardSafetyLeaseID)
        case intentEnabled(session: KeyboardSafetySessionID, revision: KeyboardPolicyRevision)
        case intentDisabled(KeyboardSafetySessionID)
        case watchdogHealthy(KeyboardWatchdogID)
        case watchdogLost(KeyboardWatchdogID)
        case acquireSucceeded(KeyboardSafetyAttemptID)
        case acquireFailed(KeyboardSafetyAttemptID)
        case releaseSucceeded(KeyboardSafetyAttemptID)
        case runtimeFailed(KeyboardSafetyAttemptID)
        case backoffElapsed(KeyboardSafetySessionID)
        case recoveryReset(KeyboardSafetySessionID)
    }

    enum Command: Equatable, Sendable {
        case acquire(KeyboardSafetyAttemptID)
        case release(KeyboardSafetyAttemptID)
    }

    let failureThreshold: KeyboardSafetyFailureThreshold
    private(set) var lifecycle: Lifecycle = .stopped
    private(set) var output: KeyboardOutputEndpointID?
    private(set) var lease: KeyboardSafetyLeaseID?
    private(set) var intentRevision: KeyboardPolicyRevision?
    private(set) var watchdog: KeyboardWatchdogID?
    private(set) var ownership: Ownership = .none
    private(set) var failuresSinceReset = 0
    private(set) var breakerIsOpen = false
    private(set) var backoffIsActive = false
    private var nextAttemptSequence: UInt64 = 1
    private var lostOutputGeneration: [KeyboardSafetySessionID: UInt64] = [:]
    private var lostLeases: Set<KeyboardSafetyLeaseID> = []
    private var disabledIntentRevision: [KeyboardSafetySessionID: KeyboardPolicyRevision] = [:]
    private var lostWatchdogGeneration: [KeyboardSafetySessionID: UInt64] = [:]
    private var lastStartedSession: KeyboardSafetySessionID?

    init(failureThreshold: KeyboardSafetyFailureThreshold) {
        self.failureThreshold = failureThreshold
    }

    var consecutiveFailures: Int { failuresSinceReset }

    var activeSession: KeyboardSafetySessionID? {
        guard case .running(let session) = lifecycle else { return nil }
        return session
    }

    var isReadyToAcquire: Bool {
        guard let session = activeSession else { return false }
        return output?.session == session && lease?.session == session && intentRevision != nil
            && watchdog?.session == session && !breakerIsOpen && !backoffIsActive
    }

    var invariantsHold: Bool {
        let session = activeSession
        let prerequisitesBelongToSession = [output?.session, lease?.session, watchdog?.session]
            .compactMap { $0 }
            .allSatisfy { $0 == session }
        let ownershipSafe: Bool
        switch ownership {
        case .requested(let attempt), .owned(let attempt):
            ownershipSafe = attempt.session == session && isReadyToAcquire
        case .none, .releasing:
            ownershipSafe = true
        }
        let stoppedIsEmpty = session != nil || (output == nil && lease == nil && intentRevision == nil
            && watchdog == nil && !backoffIsActive
            && { if case .none = ownership { return true }; if case .releasing = ownership { return true }; return false }())
        let breakerConsistent = !breakerIsOpen || failuresSinceReset >= failureThreshold.value
        return prerequisitesBelongToSession && ownershipSafe && stoppedIsEmpty
            && failuresSinceReset >= 0 && breakerConsistent
    }

    mutating func handle(_ event: Event) -> [Command] {
        var commands: [Command] = []
        var mayAcquire = true

        switch event {
        case .start(let session):
            guard activeSession != session else { break }
            releaseIfNeeded(into: &commands)
            if lastStartedSession != session {
                lostOutputGeneration.removeAll()
                lostLeases.removeAll()
                disabledIntentRevision.removeAll()
                lostWatchdogGeneration.removeAll()
                lastStartedSession = session
                nextAttemptSequence = 1
            }
            lifecycle = .running(session)
            output = nil; lease = nil; intentRevision = nil; watchdog = nil
            failuresSinceReset = 0; breakerIsOpen = false; backoffIsActive = false

        case .stop:
            releaseIfNeeded(into: &commands)
            lifecycle = .stopped
            output = nil; lease = nil; intentRevision = nil; watchdog = nil
            backoffIsActive = false

        case .outputReady(let endpoint) where endpoint.session == activeSession:
            let floor = lostOutputGeneration[endpoint.session] ?? 0
            guard endpoint.generation > floor else { break }
            if let output, endpoint.generation < output.generation { break }
            if output != nil, output != endpoint { releaseIfNeeded(into: &commands) }
            output = endpoint
        case .outputReady:
            break

        case .outputLost(let endpoint) where endpoint.session == activeSession:
            lostOutputGeneration[endpoint.session] = max(
                lostOutputGeneration[endpoint.session] ?? 0,
                endpoint.generation
            )
            if let current = output, current.generation <= endpoint.generation {
                output = nil
                releaseIfNeeded(into: &commands)
            }
        case .outputLost:
            break

        case .leaseGranted(let granted) where granted.session == activeSession && !lostLeases.contains(granted):
            if let current = lease, current != granted {
                lostLeases.insert(current)
                releaseIfNeeded(into: &commands)
            }
            lease = granted
        case .leaseGranted:
            break

        case .leaseLost(let lost) where lost.session == activeSession:
            lostLeases.insert(lost)
            if lost == lease {
                lease = nil
                releaseIfNeeded(into: &commands)
            }
        case .leaseLost:
            break

        case .intentEnabled(let session, let revision) where session == activeSession:
            guard disabledIntentRevision[session].map({ revision > $0 }) ?? true,
                  intentRevision.map({ revision >= $0 }) ?? true else { break }
            if intentRevision != nil, intentRevision != revision { releaseIfNeeded(into: &commands) }
            intentRevision = revision
        case .intentEnabled:
            break

        case .intentDisabled(let session) where session == activeSession:
            if let intentRevision {
                disabledIntentRevision[session] = max(
                    disabledIntentRevision[session] ?? intentRevision,
                    intentRevision
                )
            }
            intentRevision = nil
            releaseIfNeeded(into: &commands)
        case .intentDisabled:
            break

        case .watchdogHealthy(let healthy) where healthy.session == activeSession:
            let floor = lostWatchdogGeneration[healthy.session] ?? 0
            guard healthy.generation > floor else { break }
            if let watchdog, healthy.generation < watchdog.generation { break }
            if watchdog != nil, watchdog != healthy { releaseIfNeeded(into: &commands) }
            watchdog = healthy
        case .watchdogHealthy:
            break

        case .watchdogLost(let lost) where lost.session == activeSession:
            lostWatchdogGeneration[lost.session] = max(
                lostWatchdogGeneration[lost.session] ?? 0,
                lost.generation
            )
            if let current = watchdog, current.generation <= lost.generation {
                watchdog = nil
                releaseIfNeeded(into: &commands)
            }
        case .watchdogLost:
            break

        case .acquireSucceeded(let id):
            if ownership == .requested(id) {
                ownership = .owned(id)
                backoffIsActive = false
            } else if ownership == .owned(id) {
                break
            } else {
                commands.append(.release(id))
            }

        case .acquireFailed(let id):
            if ownership == .requested(id) {
                ownership = .none
                recordFailure()
            }

        case .runtimeFailed(let id):
            if ownership == .owned(id) {
                ownership = .releasing(id)
                commands.append(.release(id))
                recordFailure()
            }

        case .releaseSucceeded(let id):
            if ownership == .releasing(id) { ownership = .none }

        case .backoffElapsed(let session) where session == activeSession:
            backoffIsActive = false
        case .backoffElapsed:
            break

        case .recoveryReset(let session) where session == activeSession:
            breakerIsOpen = false
            backoffIsActive = false
            failuresSinceReset = 0
            mayAcquire = false
        case .recoveryReset:
            break
        }

        if mayAcquire { requestIfSafe(into: &commands) }
        assert(invariantsHold)
        return commands
    }

    private mutating func recordFailure() {
        failuresSinceReset += 1
        if failuresSinceReset >= failureThreshold.value {
            breakerIsOpen = true
            backoffIsActive = false
        } else {
            backoffIsActive = true
        }
    }

    private mutating func releaseIfNeeded(into commands: inout [Command]) {
        switch ownership {
        case .requested(let id), .owned(let id):
            ownership = .releasing(id)
            commands.append(.release(id))
        case .none, .releasing:
            break
        }
    }

    private mutating func requestIfSafe(into commands: inout [Command]) {
        guard let session = activeSession, isReadyToAcquire, ownership == .none else { return }
        let id = KeyboardSafetyAttemptID(session: session, validatedSequence: nextAttemptSequence)
        nextAttemptSequence &+= 1
        ownership = .requested(id)
        commands.append(.acquire(id))
    }
}
