import XCTest

final class KeyboardSafetyLifecycleTests: XCTestCase {
    private let threshold = KeyboardSafetyFailureThreshold(2)!

    private func ready() -> KeyboardSafetyLifecycle {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        for event in [KeyboardSafetyLifecycle.Event.start, .outputReady, .leaseGranted,
                      .intentEnabled, .watchdogHealthy] { _ = model.handle(event) }
        return model
    }

    func testThresholdMustBePositive() {
        XCTAssertNil(KeyboardSafetyFailureThreshold(0))
        XCTAssertNil(KeyboardSafetyFailureThreshold(-1))
        XCTAssertEqual(KeyboardSafetyFailureThreshold(1)?.value, 1)
    }

    func testEveryPrerequisiteIsRequiredRegardlessOfArrivalOrder() {
        let prerequisites: [KeyboardSafetyLifecycle.Event] = [.start, .outputReady, .leaseGranted,
                                                               .intentEnabled, .watchdogHealthy]
        for omitted in prerequisites {
            var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
            for event in prerequisites where event != omitted { XCTAssertEqual(model.handle(event), []) }
            XCTAssertEqual(model.ownership, .none)
        }
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        XCTAssertEqual(model.handle(.watchdogHealthy), [])
        for event in prerequisites { _ = model.handle(event) }
        XCTAssertEqual(model.ownership, .requested)
    }

    func testEachSafetyLossReleasesRequestedAndOwnedSeizure() {
        let losses: [KeyboardSafetyLifecycle.Event] = [.outputLost, .leaseLost, .intentDisabled,
                                                        .watchdogLost, .stop]
        for owned in [false, true] {
            for loss in losses {
                var model = ready()
                if owned { _ = model.handle(.acquireSucceeded) }
                XCTAssertEqual(model.handle(loss), [.release], "\(loss), owned=\(owned)")
                XCTAssertEqual(model.ownership, .none)
                XCTAssertTrue(model.invariantsHold)
            }
        }
    }

    func testBreakerTripsAtThresholdAndIgnoresAutomaticChurn() {
        var model = ready()
        XCTAssertEqual(model.handle(.acquireFailed), [])
        XCTAssertFalse(model.breakerIsOpen)
        XCTAssertTrue(model.backoffIsActive)
        XCTAssertEqual(model.handle(.backoffElapsed), [.acquire])
        XCTAssertEqual(model.handle(.acquireFailed), [])
        XCTAssertTrue(model.breakerIsOpen)
        XCTAssertFalse(model.backoffIsActive)

        for event in [KeyboardSafetyLifecycle.Event.backoffElapsed, .outputLost, .outputReady,
                      .leaseLost, .leaseGranted, .watchdogLost, .watchdogHealthy,
                      .intentDisabled, .intentEnabled] {
            XCTAssertFalse(model.handle(event).contains(.acquire), "automatic event \(event) retried")
        }
        XCTAssertTrue(model.breakerIsOpen)
    }

    func testRuntimeFailureReleasesAndContributesToThreshold() {
        var model = ready()
        _ = model.handle(.acquireSucceeded)
        XCTAssertEqual(model.handle(.runtimeFailed), [.release])
        XCTAssertEqual(model.consecutiveFailures, 1)
        XCTAssertTrue(model.backoffIsActive)
        XCTAssertEqual(model.handle(.backoffElapsed), [.acquire])
        XCTAssertEqual(model.handle(.acquireSucceeded), [])
        XCTAssertEqual(model.consecutiveFailures, 1)
        XCTAssertEqual(model.handle(.runtimeFailed), [.release])
        XCTAssertTrue(model.breakerIsOpen)
        XCTAssertEqual(model.handle(.backoffElapsed), [])
    }

    func testOnlyExplicitRecoveryResetPermitsAcquisitionAfterTrip() {
        var model = ready()
        _ = model.handle(.acquireFailed)
        _ = model.handle(.backoffElapsed)
        _ = model.handle(.acquireFailed)
        XCTAssertEqual(model.handle(.stop), [])
        XCTAssertTrue(model.breakerIsOpen)
        _ = model.handle(.start)
        for event in [KeyboardSafetyLifecycle.Event.leaseGranted, .intentEnabled, .watchdogHealthy] {
            XCTAssertEqual(model.handle(event), [])
        }
        XCTAssertEqual(model.handle(.recoveryReset), [.acquire])
        XCTAssertFalse(model.breakerIsOpen)
        XCTAssertEqual(model.consecutiveFailures, 0)
    }

    func testStaleOwnerAcknowledgementsCannotCreateOwnershipOrTripBreaker() {
        var model = KeyboardSafetyLifecycle(failureThreshold: threshold)
        _ = model.handle(.acquireSucceeded)
        _ = model.handle(.acquireFailed)
        XCTAssertEqual(model.ownership, .none)
        XCTAssertEqual(model.consecutiveFailures, 0)
        XCTAssertFalse(model.breakerIsOpen)
    }

    func testExhaustiveEventSequencesPreserveAllModeledInvariants() {
        func walk(_ model: KeyboardSafetyLifecycle, depth: Int) {
            XCTAssertTrue(model.invariantsHold)
            guard depth > 0 else { return }
            for event in KeyboardSafetyLifecycle.Event.allCases {
                var next = model
                _ = next.handle(event)
                walk(next, depth: depth - 1)
            }
        }
        walk(KeyboardSafetyLifecycle(failureThreshold: threshold), depth: 5) // 16^5 paths
    }
}
