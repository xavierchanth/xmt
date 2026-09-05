protocol KeyboardProtectionBackend: Sendable {
    /// Acquisition must observe task cancellation at its finite operation boundary.
    func acquire(attempt: KeyboardSafetyAttemptID) async throws
    func release(attempt: KeyboardSafetyAttemptID) async throws
}

/// Event-driven executor for the pure safety lifecycle. Acquisition and release use independent
/// tasks, allowing stop and prerequisite-loss events to start teardown even when acquisition stalls.
actor KeyboardSafetyRuntime {
    private(set) var lifecycle: KeyboardSafetyLifecycle
    private(set) var pendingRelease: KeyboardSafetyAttemptID?

    private let backend: any KeyboardProtectionBackend
    private var acquireTasks: [KeyboardSafetyAttemptID: Task<Void, Never>] = [:]
    private var releaseTasks: [KeyboardSafetyAttemptID: Task<Void, Never>] = [:]

    init(failureThreshold: KeyboardSafetyFailureThreshold,
         backend: any KeyboardProtectionBackend) {
        lifecycle = KeyboardSafetyLifecycle(failureThreshold: failureThreshold)
        self.backend = backend
    }

    func handle(_ event: KeyboardSafetyLifecycle.Event) {
        execute(lifecycle.handle(event))
    }

    func retryPendingRelease() {
        guard let pendingRelease, releaseTasks[pendingRelease] == nil else { return }
        startRelease(pendingRelease)
    }

    /// Waits for the currently triggered finite backend operations and any lifecycle commands
    /// they produce. This performs no idle polling and is primarily useful at explicit boundaries.
    func waitForEffects() async {
        while !acquireTasks.isEmpty || !releaseTasks.isEmpty {
            let tasks = Array(acquireTasks.values) + Array(releaseTasks.values)
            for task in tasks { await task.value }
        }
    }

    private func execute(_ commands: [KeyboardSafetyLifecycle.Command]) {
        for command in commands {
            switch command {
            case .acquire(let id):
                startAcquire(id)
            case .release(let id):
                acquireTasks[id]?.cancel()
                startRelease(id)
            }
        }
    }

    private func startAcquire(_ id: KeyboardSafetyAttemptID) {
        guard acquireTasks[id] == nil else { return }
        let backend = self.backend
        acquireTasks[id] = Task { [weak self] in
            let succeeded: Bool
            do {
                try await backend.acquire(attempt: id)
                succeeded = true
            } catch {
                succeeded = false
            }
            await self?.acquireFinished(id, succeeded: succeeded)
        }
    }

    private func acquireFinished(_ id: KeyboardSafetyAttemptID, succeeded: Bool) {
        acquireTasks[id] = nil
        execute(lifecycle.handle(succeeded ? .acquireSucceeded(id) : .acquireFailed(id)))
    }

    private func startRelease(_ id: KeyboardSafetyAttemptID) {
        guard releaseTasks[id] == nil else { return }
        pendingRelease = id
        let backend = self.backend
        releaseTasks[id] = Task { [weak self] in
            let succeeded: Bool
            do {
                try await backend.release(attempt: id)
                succeeded = true
            } catch {
                succeeded = false
            }
            await self?.releaseFinished(id, succeeded: succeeded)
        }
    }

    private func releaseFinished(_ id: KeyboardSafetyAttemptID, succeeded: Bool) {
        releaseTasks[id] = nil
        guard succeeded else { return }
        if pendingRelease == id { pendingRelease = nil }
        execute(lifecycle.handle(.releaseSucceeded(id)))
    }
}
