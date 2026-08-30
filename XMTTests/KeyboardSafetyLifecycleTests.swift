import XCTest

final class KeyboardSafetyLifecycleTests: XCTestCase {
    private func ready() -> KeyboardSafetyLifecycle {
        var model = KeyboardSafetyLifecycle()
        for event in [KeyboardSafetyLifecycle.Event.start, .outputReady, .leaseGranted,
                      .intentEnabled, .watchdogHealthy] { _ = model.handle(event) }
        return model
    }

    func testEveryPrerequisiteIsRequiredRegardlessOfArrivalOrder() {
        let prerequisites: [KeyboardSafetyLifecycle.Event] = [.start, .outputReady, .leaseGranted,
                                                               .intentEnabled, .watchdogHealthy]
        for omitted in prerequisites {
            var model = KeyboardSafetyLifecycle()
            for event in prerequisites where event != omitted { XCTAssertEqual(model.handle(event), []) }
            XCTAssertEqual(model.ownership, .none)
        }
        var model = KeyboardSafetyLifecycle()
        XCTAssertEqual(model.handle(.watchdogHealthy), []) // ignored before lifecycle start
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

    func testBreakerBlocksRetriesUntilBackoffAndCountsConsecutiveFailures() {
        var model = ready()
        XCTAssertEqual(model.handle(.acquireFailed), [])
        XCTAssertTrue(model.breakerIsOpen)
        XCTAssertEqual(model.consecutiveFailures, 1)
        XCTAssertEqual(model.handle(.outputLost), [])
        XCTAssertEqual(model.handle(.outputReady), [])
        XCTAssertEqual(model.handle(.backoffElapsed), [.acquire])
        XCTAssertEqual(model.handle(.acquireFailed), [])
        XCTAssertEqual(model.consecutiveFailures, 2)
        XCTAssertEqual(model.handle(.backoffElapsed), [.acquire])
        _ = model.handle(.acquireSucceeded)
        XCTAssertEqual(model.consecutiveFailures, 0)
    }

    func testStaleOwnerAcknowledgementsCannotCreateOwnership() {
        var model = KeyboardSafetyLifecycle()
        _ = model.handle(.acquireSucceeded)
        _ = model.handle(.acquireFailed)
        XCTAssertEqual(model.ownership, .none)
        XCTAssertEqual(model.consecutiveFailures, 0)
    }

    func testStopIsIdempotentAndClearsAuthorityAndBreaker() {
        var model = ready()
        _ = model.handle(.acquireFailed)
        XCTAssertEqual(model.handle(.stop), [])
        XCTAssertEqual(model.handle(.stop), [])
        XCTAssertEqual(model.lifecycle, .stopped)
        XCTAssertFalse(model.hasLease)
        XCTAssertFalse(model.hasSeizureIntent)
        XCTAssertFalse(model.watchdogIsHealthy)
        XCTAssertFalse(model.breakerIsOpen)
        XCTAssertEqual(model.consecutiveFailures, 0)
        XCTAssertTrue(model.outputIsReady) // readiness is observation, not authority
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
        walk(KeyboardSafetyLifecycle(), depth: 5) // 14^5 transition paths
    }
}
