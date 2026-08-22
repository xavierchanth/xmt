import XCTest

final class TriggerArbitratorTests: XCTestCase {
    func testIdleFnDownBecomesPendingWithoutOutput() {
        assert([.fnDown], state: .fnPending, events: [])
    }

    func testIdleInputsOtherThanFnDownAreIgnored() {
        for input in inputs.filter({ $0 != .fnDown }) { assert([input], state: .idle, events: []) }
    }

    func testPendingFnUpMakesBareTapInert() {
        assert([.fnDown, .fnUp], state: .idle, events: [])
    }

    func testPendingOtherKeyEntersChordPassthroughWithoutOutput() {
        assert([.fnDown, .otherKeyDown], state: .chordPassthrough, events: [])
    }

    func testChordPassthroughIgnoresKeysAndThreshold() {
        assert([.fnDown, .otherKeyDown, .spaceDown, .otherKeyDown, .holdThresholdElapsed],
               state: .chordPassthrough, events: [])
    }

    func testChordPassthroughFnUpReturnsIdle() {
        assert([.fnDown, .otherKeyDown, .fnUp], state: .idle, events: [])
    }

    func testPendingThresholdBeginsPushToTalk() {
        assert([.fnDown, .holdThresholdElapsed], state: .pttActive, events: [.pushToTalkBegan])
    }

    func testThresholdAfterFnReleaseCannotBeginPushToTalk() {
        assert([.fnDown, .fnUp, .holdThresholdElapsed], state: .idle, events: [])
    }

    func testActiveFnUpBalancesBeginWithEnd() {
        assert([.fnDown, .holdThresholdElapsed, .fnUp], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testPendingFnSpaceRequestsToggleAndPreventsPushToTalk() {
        assert([.fnDown, .spaceDown, .holdThresholdElapsed], state: .chordPassthrough,
               events: [.toggleRequested])
    }

    func testActiveFnSpaceRequestsToggleButRetainsActiveState() {
        assert([.fnDown, .holdThresholdElapsed, .spaceDown], state: .pttActive,
               events: [.pushToTalkBegan, .toggleRequested])
    }

    func testActiveFnSpaceStillBalancesOnRelease() {
        assert([.fnDown, .holdThresholdElapsed, .spaceDown, .fnUp], state: .idle,
               events: [.pushToTalkBegan, .toggleRequested, .pushToTalkEnded])
    }

    func testTapDisabledWhilePendingCancelsGesture() {
        assert([.fnDown, .tapDisabled], state: .idle, events: [])
    }

    func testSecureInputWhilePendingCancelsGesture() {
        assert([.fnDown, .secureInputInterrupted], state: .idle, events: [])
    }

    func testTapDisabledWhileActiveSynthesizesEnd() {
        assert([.fnDown, .holdThresholdElapsed, .tapDisabled], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testSecureInputWhileActiveSynthesizesEnd() {
        assert([.fnDown, .holdThresholdElapsed, .secureInputInterrupted], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testInterruptionWhileChordPassthroughReturnsIdleWithoutOutput() {
        assert([.fnDown, .otherKeyDown, .secureInputInterrupted], state: .idle, events: [])
    }

    func testDisableWhileChordPassthroughReturnsIdleWithoutOutput() {
        assert([.fnDown, .otherKeyDown, .tapDisabled], state: .idle, events: [])
    }

    func testRepeatedAndOutOfOrderInputsNeverEmitUnmatchedEnd() {
        var machine = TriggerArbitrator()
        var balance = 0
        for input in inputs + inputs + inputs.reversed() {
            for event in machine.receive(input) {
                if event == .pushToTalkBegan { balance += 1 }
                if event == .pushToTalkEnded { balance -= 1 }
                XCTAssertGreaterThanOrEqual(balance, 0)
            }
        }
    }

    private let inputs: [TriggerInput] = [
        .fnDown, .fnUp, .spaceDown, .otherKeyDown, .holdThresholdElapsed,
        .tapDisabled, .secureInputInterrupted
    ]

    private func assert(
        _ inputs: [TriggerInput],
        state: TriggerArbitrator.State,
        events expected: [TriggerEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var machine = TriggerArbitrator()
        let events = inputs.flatMap { machine.receive($0) }
        XCTAssertEqual(machine.state, state, file: file, line: line)
        XCTAssertEqual(events, expected, file: file, line: line)
    }
}
