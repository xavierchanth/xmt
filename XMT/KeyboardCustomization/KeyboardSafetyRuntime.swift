protocol KeyboardProtectionBackend: Sendable {
    func acquire(attempt: KeyboardSafetyAttemptID) async throws
    func release(attempt: KeyboardSafetyAttemptID) async throws
}

/// Serial executor for the pure safety lifecycle. A failed release remains pending and prevents
/// reacquisition until an explicit, event-driven retry succeeds.
actor KeyboardSafetyRuntime {
    private(set) var lifecycle: KeyboardSafetyLifecycle
    private(set) var pendingRelease: KeyboardSafetyAttemptID?

    private let backend: any KeyboardProtectionBackend
    private var isExecuting = false
    private var queuedEvents: [KeyboardSafetyLifecycle.Event] = []
    private var releaseRetryRequested = false

    init(failureThreshold: KeyboardSafetyFailureThreshold,
         backend: any KeyboardProtectionBackend) {
        lifecycle = KeyboardSafetyLifecycle(failureThreshold: failureThreshold)
        self.backend = backend
    }

    func handle(_ event: KeyboardSafetyLifecycle.Event) async {
        queuedEvents.append(event)
        await drain()
    }

    func retryPendingRelease() async {
        guard pendingRelease != nil else { return }
        releaseRetryRequested = true
        await drain()
    }

    private func drain() async {
        guard !isExecuting else { return }
        isExecuting = true
        defer { isExecuting = false }

        while !queuedEvents.isEmpty || releaseRetryRequested {
            if !queuedEvents.isEmpty {
                let event = queuedEvents.removeFirst()
                let commands = lifecycle.handle(event)
                for command in commands { await execute(command) }
            } else {
                releaseRetryRequested = false
                if let pendingRelease { await execute(.release(pendingRelease)) }
            }
        }
    }

    private func execute(_ command: KeyboardSafetyLifecycle.Command) async {
        switch command {
        case .acquire(let id):
            do {
                try await backend.acquire(attempt: id)
                queuedEvents.append(.acquireSucceeded(id))
            } catch {
                queuedEvents.append(.acquireFailed(id))
            }
        case .release(let id):
            do {
                try await backend.release(attempt: id)
                if pendingRelease == id { pendingRelease = nil }
                queuedEvents.append(.releaseSucceeded(id))
            } catch {
                pendingRelease = id
            }
        }
    }
}
