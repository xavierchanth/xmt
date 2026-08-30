/// A validated positive acquisition-failure threshold.
struct KeyboardSafetyFailureThreshold: Equatable, Sendable {
    let value: Int

    init?(_ value: Int) {
        guard value > 0 else { return nil }
        self.value = value
    }
}

/// A pure reducer for the protected-input safety boundary. It performs no I/O;
/// commands are obligations for a future effectful owner.
struct KeyboardSafetyLifecycle: Equatable {
    enum Ownership: Equatable { case none, requested, owned }
    enum Lifecycle: Equatable { case stopped, running }
    enum Event: CaseIterable {
        case start, stop
        case outputReady, outputLost
        case leaseGranted, leaseLost
        case intentEnabled, intentDisabled
        case watchdogHealthy, watchdogLost
        case acquireSucceeded, acquireFailed
        case runtimeFailed
        case backoffElapsed
        case recoveryReset
    }
    enum Command: Equatable { case acquire, release }

    let failureThreshold: KeyboardSafetyFailureThreshold
    private(set) var lifecycle: Lifecycle = .stopped
    private(set) var outputIsReady = false
    private(set) var hasLease = false
    private(set) var hasSeizureIntent = false
    private(set) var watchdogIsHealthy = false
    private(set) var ownership: Ownership = .none
    private(set) var consecutiveFailures = 0
    private(set) var breakerIsOpen = false
    private(set) var backoffIsActive = false

    init(failureThreshold: KeyboardSafetyFailureThreshold) {
        self.failureThreshold = failureThreshold
    }

    var invariantsHold: Bool {
        let prerequisites = lifecycle == .running && outputIsReady && hasLease
            && hasSeizureIntent && watchdogIsHealthy && !breakerIsOpen && !backoffIsActive
        let ownershipSafe = ownership == .none || prerequisites
        let stoppedIsEmpty = lifecycle == .running ||
            (!hasLease && !hasSeizureIntent && !watchdogIsHealthy && ownership == .none)
        let breakerConsistent = !breakerIsOpen || consecutiveFailures >= failureThreshold.value
        return ownershipSafe && stoppedIsEmpty && consecutiveFailures >= 0 && breakerConsistent
    }

    mutating func handle(_ event: Event) -> [Command] {
        var commands: [Command] = []
        switch event {
        case .start: lifecycle = .running
        case .stop:
            if ownership != .none { commands.append(.release) }
            lifecycle = .stopped
            hasLease = false
            hasSeizureIntent = false
            watchdogIsHealthy = false
            ownership = .none
            backoffIsActive = false
        case .outputReady: outputIsReady = true
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
        case .acquireSucceeded where ownership == .requested:
            ownership = .owned
            backoffIsActive = false
        case .acquireSucceeded: break
        case .acquireFailed where ownership == .requested:
            ownership = .none
            recordFailure()
        case .acquireFailed: break
        case .runtimeFailed where ownership == .owned:
            commands.append(.release)
            ownership = .none
            recordFailure()
        case .runtimeFailed: break
        case .backoffElapsed: backoffIsActive = false
        case .recoveryReset:
            breakerIsOpen = false
            backoffIsActive = false
            consecutiveFailures = 0
        }
        requestIfSafe(into: &commands)
        assert(invariantsHold)
        return commands
    }

    private mutating func recordFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold.value {
            breakerIsOpen = true
            backoffIsActive = false
        } else {
            backoffIsActive = true
        }
    }

    private mutating func releaseIfNeeded(into commands: inout [Command]) {
        if ownership != .none { commands.append(.release) }
        ownership = .none
    }

    private mutating func requestIfSafe(into commands: inout [Command]) {
        guard lifecycle == .running, outputIsReady, hasLease, hasSeizureIntent,
              watchdogIsHealthy, !breakerIsOpen, !backoffIsActive, ownership == .none else { return }
        ownership = .requested
        commands.append(.acquire)
    }
}
