/// A validated positive acquisition-failure threshold.
struct KeyboardSafetyFailureThreshold: Equatable, Sendable {
    let value: Int
    init?(_ value: Int) { guard value > 0 else { return nil }; self.value = value }
}

struct KeyboardSafetyAttemptID: Equatable, Hashable, Sendable { let value: UInt64 }

/// Pure reducer for the protected-input safety boundary. Attempt tokens make stale effect
/// acknowledgements explicit; no late completion can silently become current ownership.
struct KeyboardSafetyLifecycle: Equatable {
    enum Ownership: Equatable {
        case none
        case requested(KeyboardSafetyAttemptID)
        case owned(KeyboardSafetyAttemptID)
        case releasing(KeyboardSafetyAttemptID)
    }
    enum Lifecycle: Equatable { case stopped, running }
    enum Event: Equatable {
        case start, stop
        case outputReady, outputLost
        case leaseGranted, leaseLost
        case intentEnabled, intentDisabled
        case watchdogHealthy, watchdogLost
        case acquireSucceeded(KeyboardSafetyAttemptID), acquireFailed(KeyboardSafetyAttemptID)
        case releaseSucceeded(KeyboardSafetyAttemptID)
        case runtimeFailed(KeyboardSafetyAttemptID)
        case backoffElapsed
        case recoveryReset
    }
    enum Command: Equatable { case acquire(KeyboardSafetyAttemptID); case release(KeyboardSafetyAttemptID) }

    let failureThreshold: KeyboardSafetyFailureThreshold
    private(set) var lifecycle: Lifecycle = .stopped
    private(set) var outputIsReady = false
    private(set) var hasLease = false
    private(set) var hasSeizureIntent = false
    private(set) var watchdogIsHealthy = false
    private(set) var ownership: Ownership = .none
    private(set) var failuresSinceReset = 0
    private(set) var breakerIsOpen = false
    private(set) var backoffIsActive = false
    private var nextAttemptValue: UInt64 = 1

    init(failureThreshold: KeyboardSafetyFailureThreshold) { self.failureThreshold = failureThreshold }

    var consecutiveFailures: Int { failuresSinceReset }

    var invariantsHold: Bool {
        let prerequisites = lifecycle == .running && outputIsReady && hasLease
            && hasSeizureIntent && watchdogIsHealthy && !breakerIsOpen && !backoffIsActive
        let ownershipSafe: Bool
        switch ownership {
        case .requested, .owned: ownershipSafe = prerequisites
        case .none, .releasing: ownershipSafe = true
        }
        let stoppedIsEmpty = lifecycle == .running ||
            (!outputIsReady && !hasLease && !hasSeizureIntent && !watchdogIsHealthy
             && { if case .none = ownership { return true }; if case .releasing = ownership { return true }; return false }())
        let breakerConsistent = !breakerIsOpen || failuresSinceReset >= failureThreshold.value
        return ownershipSafe && stoppedIsEmpty && failuresSinceReset >= 0 && breakerConsistent
    }

    mutating func handle(_ event: Event) -> [Command] {
        var commands: [Command] = []
        var mayAcquire = true
        switch event {
        case .start: lifecycle = .running
        case .stop:
            releaseIfNeeded(into: &commands)
            lifecycle = .stopped; outputIsReady = false; hasLease = false
            hasSeizureIntent = false; watchdogIsHealthy = false; backoffIsActive = false
        case .outputReady where lifecycle == .running: outputIsReady = true
        case .outputReady: break
        case .outputLost: outputIsReady = false; releaseIfNeeded(into: &commands)
        case .leaseGranted where lifecycle == .running: hasLease = true
        case .leaseGranted: break
        case .leaseLost: hasLease = false; releaseIfNeeded(into: &commands)
        case .intentEnabled where lifecycle == .running: hasSeizureIntent = true
        case .intentEnabled: break
        case .intentDisabled: hasSeizureIntent = false; releaseIfNeeded(into: &commands)
        case .watchdogHealthy where lifecycle == .running: watchdogIsHealthy = true
        case .watchdogHealthy: break
        case .watchdogLost: watchdogIsHealthy = false; releaseIfNeeded(into: &commands)
        case .acquireSucceeded(let id):
            if ownership == .requested(id) { ownership = .owned(id); backoffIsActive = false }
            else { commands.append(.release(id)) }
        case .acquireFailed(let id):
            if ownership == .requested(id) { ownership = .none; recordFailure() }
        case .runtimeFailed(let id):
            if ownership == .owned(id) {
                ownership = .releasing(id); commands.append(.release(id)); recordFailure()
            }
        case .releaseSucceeded(let id):
            if ownership == .releasing(id) { ownership = .none }
        case .backoffElapsed: backoffIsActive = false
        case .recoveryReset:
            breakerIsOpen = false; backoffIsActive = false; failuresSinceReset = 0
            mayAcquire = false // operator reset is not itself an immediate seizure request
        }
        if mayAcquire { requestIfSafe(into: &commands) }
        assert(invariantsHold)
        return commands
    }

    private mutating func recordFailure() {
        failuresSinceReset += 1
        if failuresSinceReset >= failureThreshold.value { breakerIsOpen = true; backoffIsActive = false }
        else { backoffIsActive = true }
    }

    private mutating func releaseIfNeeded(into commands: inout [Command]) {
        switch ownership {
        case .requested(let id), .owned(let id):
            ownership = .releasing(id); commands.append(.release(id))
        case .none, .releasing: break
        }
    }

    private mutating func requestIfSafe(into commands: inout [Command]) {
        guard lifecycle == .running, outputIsReady, hasLease, hasSeizureIntent,
              watchdogIsHealthy, !breakerIsOpen, !backoffIsActive, ownership == .none else { return }
        let id = KeyboardSafetyAttemptID(value: nextAttemptValue)
        nextAttemptValue &+= 1
        ownership = .requested(id)
        commands.append(.acquire(id))
    }
}
