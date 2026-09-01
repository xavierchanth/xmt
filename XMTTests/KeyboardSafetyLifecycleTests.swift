import XCTest

final class KeyboardSafetyLifecycleTests: XCTestCase {
    private let threshold = KeyboardSafetyFailureThreshold(2)!
    private let allUntokenedEvents: [KeyboardSafetyLifecycle.Event] = [
        .start, .stop, .outputReady, .outputLost, .leaseGranted, .leaseLost,
        .intentEnabled, .intentDisabled, .watchdogHealthy, .watchdogLost,
        .backoffElapsed, .recoveryReset
    ]

    private func ready() -> (KeyboardSafetyLifecycle, KeyboardSafetyAttemptID) {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        var id: KeyboardSafetyAttemptID?
        for event in [KeyboardSafetyLifecycle.Event.start, .outputReady, .leaseGranted,
                      .intentEnabled, .watchdogHealthy] {
            for command in model.handle(event) { if case .acquire(let value) = command { id = value } }
        }
        return (model, id!)
    }

    func testThresholdMustBePositive() {
        XCTAssertNil(KeyboardSafetyFailureThreshold(0)); XCTAssertNil(KeyboardSafetyFailureThreshold(-1))
        XCTAssertEqual(KeyboardSafetyFailureThreshold(1)?.value, 1)
    }

    func testEveryPrerequisiteIsRequired() {
        let prerequisites: [KeyboardSafetyLifecycle.Event] = [.start, .outputReady, .leaseGranted, .intentEnabled, .watchdogHealthy]
        for omitted in prerequisites {
            var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
            for event in prerequisites where event != omitted { XCTAssertEqual(model.handle(event), []) }
            XCTAssertEqual(model.ownership, .none)
        }
        XCTAssertNotNil(ready().1)
    }

    func testSafetyLossWaitsForReleaseBeforeReacquiring() {
        var (model, id) = ready()
        XCTAssertEqual(model.handle(.acquireSucceeded(id)), [])
        XCTAssertEqual(model.handle(.leaseLost), [.release(id)])
        XCTAssertEqual(model.ownership, .releasing(id))
        XCTAssertEqual(model.handle(.leaseGranted), [])
        let commands = model.handle(.releaseSucceeded(id))
        guard case .acquire(let next)? = commands.first else { return XCTFail("expected reacquire") }
        XCTAssertNotEqual(next, id)
    }

    func testStaleAcquireSuccessIsReleasedAndCannotOwnNewAttempt() {
        var (model, first) = ready()
        XCTAssertEqual(model.handle(.leaseLost), [.release(first)])
        XCTAssertEqual(model.handle(.leaseGranted), [])
        XCTAssertEqual(model.handle(.acquireSucceeded(first)), [.release(first)])
        let release = model.handle(.releaseSucceeded(first))
        guard case .acquire(let second)? = release.first else { return XCTFail("expected second attempt") }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.handle(.acquireSucceeded(first)), [.release(first)])
        XCTAssertEqual(model.ownership, .requested(second))
    }

    func testBreakerTripsAtThresholdAndRequiresExplicitReset() {
        var (model, first) = ready()
        XCTAssertEqual(model.handle(.acquireFailed(first)), [])
        let retry = model.handle(.backoffElapsed)
        guard case .acquire(let second)? = retry.first else { return XCTFail("expected retry") }
        _ = model.handle(.acquireFailed(second))
        XCTAssertTrue(model.breakerIsOpen)
        for event in allUntokenedEvents where ![.recoveryReset, .start, .stop].contains(event) {
            var copy = model
            XCTAssertFalse(copy.handle(event).contains { if case .acquire = $0 { return true }; return false })
        }
        XCTAssertEqual(model.handle(.recoveryReset), [])
        XCTAssertFalse(model.breakerIsOpen)
        XCTAssertEqual(model.handle(.outputLost), [])
        XCTAssertTrue(model.handle(.outputReady).contains { if case .acquire = $0 { return true }; return false })
    }

    func testRuntimeFailureReleasesAndCountsOnlyCurrentAttempt() {
        var (model, id) = ready(); _ = model.handle(.acquireSucceeded(id))
        XCTAssertEqual(model.handle(.runtimeFailed(id)), [.release(id)])
        XCTAssertEqual(model.failuresSinceReset, 1)
        XCTAssertEqual(model.handle(.runtimeFailed(.init(value: 999))), [])
        XCTAssertEqual(model.failuresSinceReset, 1)
    }

    func testStopClearsReadinessAndNeedsFreshOutputConfirmation() {
        var (model, id) = ready()
        XCTAssertEqual(model.handle(.stop), [.release(id)])
        XCTAssertFalse(model.outputIsReady)
        _ = model.handle(.releaseSucceeded(id)); _ = model.handle(.start)
        for event in [KeyboardSafetyLifecycle.Event.leaseGranted, .intentEnabled, .watchdogHealthy] {
            XCTAssertEqual(model.handle(event), [])
        }
        XCTAssertEqual(model.handle(.outputReady).count, 1)
    }

    func testExhaustiveUntokenedSequencesPreserveInvariants() {
        func walk(_ model: KeyboardSafetyLifecycle, depth: Int) {
            XCTAssertTrue(model.invariantsHold)
            guard depth > 0 else { return }
            for event in allUntokenedEvents {
                var next = model; _ = next.handle(event); walk(next, depth: depth - 1)
            }
        }
        walk(KeyboardSafetyLifecycle(failureThreshold: threshold), depth: 5)
    }
}
