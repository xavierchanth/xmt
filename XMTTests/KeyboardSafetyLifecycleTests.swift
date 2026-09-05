import XCTest

final class KeyboardSafetyLifecycleTests: XCTestCase {
    private let threshold = KeyboardSafetyFailureThreshold(2)!
    private let session = KeyboardSafetySessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let staleSession = KeyboardSafetySessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    private func context(for session: KeyboardSafetySessionID) -> (
        output: KeyboardOutputEndpointID,
        lease: KeyboardSafetyLeaseID,
        watchdog: KeyboardWatchdogID,
        revision: KeyboardPolicyRevision
    ) {
        (
            .init(session: session, generation: 1)!,
            .init(session: session, value: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!),
            .init(session: session, generation: 1)!,
            KeyboardPolicyRevision(1)!
        )
    }

    private func prerequisites(for session: KeyboardSafetySessionID) -> [KeyboardSafetyLifecycle.Event] {
        let value = context(for: session)
        return [
            .start(session),
            .outputReady(value.output),
            .leaseGranted(value.lease),
            .intentEnabled(session: session, revision: value.revision),
            .watchdogHealthy(value.watchdog)
        ]
    }

    private func ready() -> (KeyboardSafetyLifecycle, KeyboardSafetyAttemptID) {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        var id: KeyboardSafetyAttemptID?
        for event in prerequisites(for: session) {
            for command in model.handle(event) {
                if case .acquire(let value) = command { id = value }
            }
        }
        return (model, id!)
    }

    func testThresholdAndRevisionMustBePositive() {
        XCTAssertNil(KeyboardSafetyFailureThreshold(0))
        XCTAssertNil(KeyboardSafetyFailureThreshold(-1))
        XCTAssertEqual(KeyboardSafetyFailureThreshold(1)?.value, 1)
        XCTAssertNil(KeyboardPolicyRevision(0))
        XCTAssertEqual(KeyboardPolicyRevision(1)?.value, 1)
    }

    func testEveryCurrentSessionPrerequisiteIsRequired() {
        let events = prerequisites(for: session)
        for omitted in events.indices {
            var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
            for index in events.indices where index != omitted { _ = model.handle(events[index]) }
            XCTAssertEqual(model.ownership, .none)
        }
        XCTAssertNotNil(ready().1)
    }

    func testStalePrerequisitesCannotCompleteCurrentReadiness() {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        _ = model.handle(.start(session))
        let stale = context(for: staleSession)
        XCTAssertEqual(model.handle(.outputReady(stale.output)), [])
        XCTAssertEqual(model.handle(.leaseGranted(stale.lease)), [])
        XCTAssertEqual(model.handle(.intentEnabled(session: staleSession, revision: stale.revision)), [])
        XCTAssertEqual(model.handle(.watchdogHealthy(stale.watchdog)), [])
        XCTAssertFalse(model.isReadyToAcquire)
        XCTAssertEqual(model.ownership, .none)
    }

    func testStaleLossCannotReleaseCurrentOwnership() {
        var (model, id) = ready()
        _ = model.handle(.acquireSucceeded(id))
        let stale = context(for: staleSession)
        XCTAssertEqual(model.handle(.leaseLost(stale.lease)), [])
        XCTAssertEqual(model.handle(.outputLost(stale.output)), [])
        XCTAssertEqual(model.handle(.watchdogLost(stale.watchdog)), [])
        XCTAssertEqual(model.ownership, .owned(id))
    }

    func testSafetyLossWaitsForReleaseBeforeReacquiring() {
        var (model, id) = ready()
        let current = context(for: session)
        XCTAssertEqual(model.handle(.acquireSucceeded(id)), [])
        XCTAssertEqual(model.handle(.leaseLost(current.lease)), [.release(id)])
        XCTAssertEqual(model.ownership, .releasing(id))
        let replacementLease = KeyboardSafetyLeaseID(session: session)
        XCTAssertEqual(model.handle(.leaseGranted(replacementLease)), [])
        let commands = model.handle(.releaseSucceeded(id))
        guard case .acquire(let next)? = commands.first else { return XCTFail("expected reacquire") }
        XCTAssertNotEqual(next, id)
    }

    func testNewSessionWaitsForOldReleaseAcknowledgement() {
        var (model, oldAttempt) = ready()
        _ = model.handle(.acquireSucceeded(oldAttempt))
        XCTAssertEqual(model.handle(.start(staleSession)), [.release(oldAttempt)])
        for event in prerequisites(for: staleSession).dropFirst() { XCTAssertEqual(model.handle(event), []) }
        let commands = model.handle(.releaseSucceeded(oldAttempt))
        guard case .acquire(let newAttempt)? = commands.first else { return XCTFail("expected new-session acquire") }
        XCTAssertEqual(newAttempt.session, staleSession)
        XCTAssertEqual(newAttempt.sequence, 1)
    }

    func testStaleAcquireSuccessIsReleasedAndCannotOwnNewAttempt() {
        var (model, first) = ready()
        let current = context(for: session)
        XCTAssertEqual(model.handle(.leaseLost(current.lease)), [.release(first)])
        let replacementLease = KeyboardSafetyLeaseID(session: session)
        XCTAssertEqual(model.handle(.leaseGranted(replacementLease)), [])
        XCTAssertEqual(model.handle(.acquireSucceeded(first)), [.release(first)])
        let release = model.handle(.releaseSucceeded(first))
        guard case .acquire(let second)? = release.first else { return XCTFail("expected second attempt") }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.handle(.acquireSucceeded(first)), [.release(first)])
        XCTAssertEqual(model.ownership, .requested(second))
    }

    func testDuplicateAcquireSuccessDoesNotReleaseOwnedAttempt() {
        var (model, attempt) = ready()
        XCTAssertEqual(model.handle(.acquireSucceeded(attempt)), [])
        XCTAssertEqual(model.handle(.acquireSucceeded(attempt)), [])
        XCTAssertEqual(model.ownership, .owned(attempt))
    }

    func testLostSameSessionGenerationsCannotReviveReadiness() {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        _ = model.handle(.start(session))
        let output1 = KeyboardOutputEndpointID(session: session, generation: 1)!
        let output2 = KeyboardOutputEndpointID(session: session, generation: 2)!
        let watchdog1 = KeyboardWatchdogID(session: session, generation: 1)!
        let watchdog2 = KeyboardWatchdogID(session: session, generation: 2)!

        _ = model.handle(.outputLost(output1))
        _ = model.handle(.watchdogLost(watchdog1))
        _ = model.handle(.outputReady(output1))
        _ = model.handle(.watchdogHealthy(watchdog1))
        XCTAssertNil(model.output)
        XCTAssertNil(model.watchdog)

        _ = model.handle(.outputReady(output2))
        _ = model.handle(.watchdogHealthy(watchdog2))
        XCTAssertEqual(model.output, output2)
        XCTAssertEqual(model.watchdog, watchdog2)
    }

    func testLostLeaseAndDisabledRevisionCannotBeReplayed() {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        _ = model.handle(.start(session))
        let current = context(for: session)
        _ = model.handle(.leaseLost(current.lease))
        _ = model.handle(.leaseGranted(current.lease))
        XCTAssertNil(model.lease)

        _ = model.handle(.intentEnabled(session: session, revision: current.revision))
        _ = model.handle(.intentDisabled(session))
        _ = model.handle(.intentEnabled(session: session, revision: current.revision))
        XCTAssertNil(model.intentRevision)
        let nextRevision = KeyboardPolicyRevision(2)!
        _ = model.handle(.intentEnabled(session: session, revision: nextRevision))
        XCTAssertEqual(model.intentRevision, nextRevision)
    }

    func testReplacedLeaseCannotReplayOverCurrentLease() {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        _ = model.handle(.start(session))
        let first = context(for: session).lease
        let second = KeyboardSafetyLeaseID(session: session)
        _ = model.handle(.leaseGranted(first))
        _ = model.handle(.leaseGranted(second))
        _ = model.handle(.leaseGranted(first))
        XCTAssertEqual(model.lease, second)
    }

    func testStopAndRestartSameSessionPreservesLeaseTombstone() {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        let lease = context(for: session).lease
        _ = model.handle(.start(session))
        _ = model.handle(.leaseLost(lease))
        _ = model.handle(.stop)
        _ = model.handle(.start(session))
        _ = model.handle(.leaseGranted(lease))
        XCTAssertNil(model.lease)
    }

    func testStopAndRestartSameSessionDoesNotReuseAcquisitionAttempt() {
        var (model, first) = ready()
        _ = model.handle(.acquireSucceeded(first))
        XCTAssertEqual(model.handle(.stop), [.release(first)])
        _ = model.handle(.releaseSucceeded(first))

        _ = model.handle(.start(session))
        let output = KeyboardOutputEndpointID(session: session, generation: 2)!
        let watchdog = KeyboardWatchdogID(session: session, generation: 2)!
        var second: KeyboardSafetyAttemptID?
        for event in [
            KeyboardSafetyLifecycle.Event.outputReady(output),
            .leaseGranted(KeyboardSafetyLeaseID(session: session)),
            .intentEnabled(session: session, revision: KeyboardPolicyRevision(2)!),
            .watchdogHealthy(watchdog)
        ] {
            for command in model.handle(event) {
                if case .acquire(let id) = command { second = id }
            }
        }
        guard let second else { return XCTFail("expected a fresh attempt") }
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(model.handle(.acquireSucceeded(first)), [.release(first)])
        XCTAssertEqual(model.ownership, .requested(second))
    }

    func testBreakerTripsAtThresholdAndRequiresCurrentSessionReset() {
        var (model, first) = ready()
        XCTAssertEqual(model.handle(.acquireFailed(first)), [])
        let retry = model.handle(.backoffElapsed(session))
        guard case .acquire(let second)? = retry.first else { return XCTFail("expected retry") }
        _ = model.handle(.acquireFailed(second))
        XCTAssertTrue(model.breakerIsOpen)
        XCTAssertEqual(model.handle(.recoveryReset(staleSession)), [])
        XCTAssertTrue(model.breakerIsOpen)
        XCTAssertEqual(model.handle(.recoveryReset(session)), [])
        XCTAssertFalse(model.breakerIsOpen)
        let current = context(for: session)
        XCTAssertEqual(model.handle(.outputLost(current.output)), [])
        let replacementOutput = KeyboardOutputEndpointID(session: session, generation: 2)!
        XCTAssertTrue(model.handle(.outputReady(replacementOutput)).contains {
            if case .acquire = $0 { return true }; return false
        })
    }

    func testRuntimeFailureReleasesAndCountsOnlyCurrentAttempt() {
        var (model, id) = ready()
        _ = model.handle(.acquireSucceeded(id))
        XCTAssertEqual(model.handle(.runtimeFailed(id)), [.release(id)])
        XCTAssertEqual(model.failuresSinceReset, 1)
        let stale = KeyboardSafetyAttemptID(session: staleSession, sequence: 999)!
        XCTAssertEqual(model.handle(.runtimeFailed(stale)), [])
        XCTAssertEqual(model.failuresSinceReset, 1)
    }

    func testStopClearsReadinessAndNeedsFreshSessionConfirmation() {
        var (model, id) = ready()
        XCTAssertEqual(model.handle(.stop), [.release(id)])
        XCTAssertNil(model.output)
        _ = model.handle(.releaseSucceeded(id))
        _ = model.handle(.start(session))
        let current = context(for: session)
        for event in [KeyboardSafetyLifecycle.Event.leaseGranted(current.lease),
                      .intentEnabled(session: session, revision: current.revision),
                      .watchdogHealthy(current.watchdog)] {
            XCTAssertEqual(model.handle(event), [])
        }
        XCTAssertEqual(model.handle(.outputReady(current.output)).count, 1)
    }

    func testExhaustiveRepresentativeSequencesPreserveInvariants() {
        let current = context(for: session)
        let stale = context(for: staleSession)
        let events: [KeyboardSafetyLifecycle.Event] = [
            .start(session), .stop,
            .outputReady(current.output), .outputLost(current.output), .outputLost(stale.output),
            .leaseGranted(current.lease), .leaseLost(current.lease), .leaseLost(stale.lease),
            .intentEnabled(session: session, revision: current.revision), .intentDisabled(session),
            .watchdogHealthy(current.watchdog), .watchdogLost(current.watchdog),
            .backoffElapsed(session), .recoveryReset(session)
        ]
        func walk(_ model: KeyboardSafetyLifecycle, depth: Int) {
            XCTAssertTrue(model.invariantsHold)
            guard depth > 0 else { return }
            for event in events {
                var next = model
                _ = next.handle(event)
                walk(next, depth: depth - 1)
            }
        }
        walk(KeyboardSafetyLifecycle(failureThreshold: threshold), depth: 4)
    }

    func testRuntimeAcquiresOnlyAfterEveryPrerequisiteAndAcknowledgesRelease() async {
        let backend = FakeKeyboardProtectionBackend()
        let runtime = KeyboardSafetyRuntime(failureThreshold: threshold, backend: backend)

        for event in prerequisites(for: session) { await runtime.handle(event) }
        await runtime.waitForEffects()
        let lifecycle = await runtime.lifecycle
        guard case .owned(let id) = lifecycle.ownership else { return XCTFail("expected ownership") }
        let acquired = await backend.acquired()
        XCTAssertEqual(acquired, [id])

        await runtime.handle(.leaseLost(context(for: session).lease))
        await runtime.waitForEffects()
        let released = await backend.released()
        let releasedLifecycle = await runtime.lifecycle
        let pendingRelease = await runtime.pendingRelease
        XCTAssertEqual(released, [id])
        XCTAssertEqual(releasedLifecycle.ownership, .none)
        XCTAssertNil(pendingRelease)
    }

    func testRuntimeAcquireFailureWaitsForBackoffEvent() async {
        let backend = FakeKeyboardProtectionBackend(acquireFailures: 1)
        let runtime = KeyboardSafetyRuntime(failureThreshold: threshold, backend: backend)
        for event in prerequisites(for: session) { await runtime.handle(event) }
        await runtime.waitForEffects()
        var acquiredCount = await backend.acquired().count
        var lifecycle = await runtime.lifecycle
        XCTAssertEqual(acquiredCount, 1)
        XCTAssertEqual(lifecycle.ownership, .none)
        XCTAssertTrue(lifecycle.backoffIsActive)

        await runtime.handle(.watchdogHealthy(context(for: session).watchdog))
        acquiredCount = await backend.acquired().count
        XCTAssertEqual(acquiredCount, 1)
        await runtime.handle(.backoffElapsed(session))
        await runtime.waitForEffects()
        acquiredCount = await backend.acquired().count
        lifecycle = await runtime.lifecycle
        XCTAssertEqual(acquiredCount, 2)
        if case .owned = lifecycle.ownership {} else { XCTFail("expected retry ownership") }
    }

    func testRuntimeReleaseFailureRemainsFailClosedUntilExplicitRetry() async {
        let backend = FakeKeyboardProtectionBackend(releaseFailures: 1)
        let runtime = KeyboardSafetyRuntime(failureThreshold: threshold, backend: backend)
        for event in prerequisites(for: session) { await runtime.handle(event) }
        await runtime.waitForEffects()
        let ownedLifecycle = await runtime.lifecycle
        guard case .owned(let first) = ownedLifecycle.ownership else {
            return XCTFail("expected ownership")
        }

        await runtime.handle(.leaseLost(context(for: session).lease))
        await runtime.waitForEffects()
        var pendingRelease = await runtime.pendingRelease
        var lifecycle = await runtime.lifecycle
        XCTAssertEqual(pendingRelease, first)
        XCTAssertEqual(lifecycle.ownership, .releasing(first))
        await runtime.handle(.leaseGranted(.init(session: session)))
        var acquiredCount = await backend.acquired().count
        XCTAssertEqual(acquiredCount, 1)

        await runtime.retryPendingRelease()
        await runtime.waitForEffects()
        pendingRelease = await runtime.pendingRelease
        let released = await backend.released()
        acquiredCount = await backend.acquired().count
        XCTAssertNil(pendingRelease)
        XCTAssertEqual(released, [first, first])
        XCTAssertEqual(acquiredCount, 2)
        lifecycle = await runtime.lifecycle
        guard case .owned(let second) = lifecycle.ownership else {
            return XCTFail("expected ownership after release acknowledgement")
        }
        XCTAssertNotEqual(second, first)
    }

    func testStopStartsReleaseWhenAcquireIsStalled() async {
        let backend = FakeKeyboardProtectionBackend(blockAcquire: true)
        let runtime = KeyboardSafetyRuntime(failureThreshold: threshold, backend: backend)
        for event in prerequisites(for: session) { await runtime.handle(event) }
        await backend.waitUntilAcquireStarted()
        let requested = await runtime.lifecycle
        guard case .requested(let attempt) = requested.ownership else {
            return XCTFail("expected requested ownership")
        }

        await runtime.handle(.stop)
        await backend.waitUntilReleased(attempt)
        await runtime.waitForEffects()
        let stopped = await runtime.lifecycle
        XCTAssertEqual(stopped.lifecycle, .stopped)
        XCTAssertEqual(stopped.ownership, .none)
    }
}

private actor FakeKeyboardProtectionBackend: KeyboardProtectionBackend {
    enum Failure: Error { case injected }

    private var acquireFailuresRemaining: Int
    private var releaseFailuresRemaining: Int
    private var acquiredAttempts: [KeyboardSafetyAttemptID] = []
    private var releasedAttempts: [KeyboardSafetyAttemptID] = []
    private let blockAcquire: Bool
    private var acquireStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [(KeyboardSafetyAttemptID, CheckedContinuation<Void, Never>)] = []

    init(acquireFailures: Int = 0, releaseFailures: Int = 0, blockAcquire: Bool = false) {
        acquireFailuresRemaining = acquireFailures
        releaseFailuresRemaining = releaseFailures
        self.blockAcquire = blockAcquire
    }

    func acquire(attempt: KeyboardSafetyAttemptID) async throws {
        acquiredAttempts.append(attempt)
        let waiters = acquireStartedWaiters
        acquireStartedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if blockAcquire {
            try await Task.sleep(for: .seconds(60))
        }
        if acquireFailuresRemaining > 0 {
            acquireFailuresRemaining -= 1
            throw Failure.injected
        }
    }

    func release(attempt: KeyboardSafetyAttemptID) async throws {
        releasedAttempts.append(attempt)
        let matches = releaseWaiters.filter { $0.0 == attempt }
        releaseWaiters.removeAll { $0.0 == attempt }
        for (_, waiter) in matches { waiter.resume() }
        if releaseFailuresRemaining > 0 {
            releaseFailuresRemaining -= 1
            throw Failure.injected
        }
    }

    func acquired() -> [KeyboardSafetyAttemptID] { acquiredAttempts }
    func released() -> [KeyboardSafetyAttemptID] { releasedAttempts }

    func waitUntilAcquireStarted() async {
        if !acquiredAttempts.isEmpty { return }
        await withCheckedContinuation { acquireStartedWaiters.append($0) }
    }

    func waitUntilReleased(_ attempt: KeyboardSafetyAttemptID) async {
        if releasedAttempts.contains(attempt) { return }
        await withCheckedContinuation { releaseWaiters.append((attempt, $0)) }
    }
}
