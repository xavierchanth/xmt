import XCTest

final class TriggerArbitratorTests: XCTestCase {
    func testIdleFnDownBecomesPendingWithoutOutput() {
        assertSequence([.fnDown], state: .fnPending, events: [])
    }

    func testIdleInputsOtherThanFnDownAreIgnored() {
        for input in inputs.filter({ $0 != .fnDown }) { assertSequence([input], state: .idle, events: []) }
    }

    func testPendingFnUpMakesBareTapInert() {
        assertSequence([.fnDown, .fnUp], state: .idle, events: [])
    }

    func testPendingOtherKeyEntersChordPassthroughWithoutOutput() {
        assertSequence([.fnDown, .otherKeyDown], state: .chordPassthrough, events: [])
    }

    func testChordPassthroughIgnoresKeysAndThreshold() {
        assertSequence([.fnDown, .otherKeyDown, .spaceDown, .otherKeyDown, .holdThresholdElapsed],
               state: .chordPassthrough, events: [])
    }

    func testChordPassthroughFnUpReturnsIdle() {
        assertSequence([.fnDown, .otherKeyDown, .fnUp], state: .idle, events: [])
    }

    func testPendingThresholdBeginsPushToTalk() {
        assertSequence([.fnDown, .holdThresholdElapsed], state: .pttActive, events: [.pushToTalkBegan])
    }

    func testThresholdAfterFnReleaseCannotBeginPushToTalk() {
        assertSequence([.fnDown, .fnUp, .holdThresholdElapsed], state: .idle, events: [])
    }

    func testActiveFnUpBalancesBeginWithEnd() {
        assertSequence([.fnDown, .holdThresholdElapsed, .fnUp], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testPendingFnSpaceRequestsToggleAndPreventsPushToTalk() {
        assertSequence([.fnDown, .spaceDown, .holdThresholdElapsed], state: .chordPassthrough,
               events: [.toggleRequested])
    }

    func testActiveFnSpaceRequestsToggleButRetainsActiveState() {
        assertSequence([.fnDown, .holdThresholdElapsed, .spaceDown], state: .pttActive,
               events: [.pushToTalkBegan, .toggleRequested])
    }

    // Contract: the Voice module may latch recording on toggle and ignore the
    // balanced PTT end for recording semantics; this trigger layer stays balanced.
    func testActiveFnSpaceStillBalancesOnReleaseForVoiceModuleToInterpret() {
        assertSequence([.fnDown, .holdThresholdElapsed, .spaceDown, .fnUp], state: .idle,
               events: [.pushToTalkBegan, .toggleRequested, .pushToTalkEnded])
    }

    func testTapDisabledWhilePendingCancelsGesture() {
        assertSequence([.fnDown, .tapDisabled], state: .idle, events: [])
    }

    func testSecureInputWhilePendingCancelsGesture() {
        assertSequence([.fnDown, .secureInputInterrupted], state: .idle, events: [])
    }

    func testTapDisabledWhileActiveSynthesizesEnd() {
        assertSequence([.fnDown, .holdThresholdElapsed, .tapDisabled], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testSecureInputWhileActiveSynthesizesEnd() {
        assertSequence([.fnDown, .holdThresholdElapsed, .secureInputInterrupted], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testInterruptionWhileChordPassthroughReturnsIdleWithoutOutput() {
        assertSequence([.fnDown, .otherKeyDown, .secureInputInterrupted], state: .idle, events: [])
    }

    func testDisableWhileChordPassthroughReturnsIdleWithoutOutput() {
        assertSequence([.fnDown, .otherKeyDown, .tapDisabled], state: .idle, events: [])
    }

    func testRepeatedAndOutOfOrderInputsNeverEmitUnmatchedEnd() {
        var machine = TriggerArbitrator()
        var balance = 0
        for input in inputs + inputs + inputs.reversed() {
            for event in machine.receive(input) {
                if event == .pushToTalkBegan { balance += 1 }
                if event == .pushToTalkEnded { balance -= 1 }
                XCTAssertGreaterThanOrEqual(balance, 0)
                XCTAssertLessThanOrEqual(balance, 1)
            }
        }
        XCTAssertEqual(balance, 0)
    }

    func testPhysicalMapperConsumesSpaceDownAndMatchingUp() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        XCTAssertEqual(mapper.keyDown(code: 49, isRepeat: false),
                       .init(input: .chordDown(.toggle), consumesEvent: true))
        XCTAssertEqual(mapper.keyUp(code: 49), .init(input: .chordUp(.toggle), consumesEvent: true))
    }

    func testPhysicalMapperConsumesSpaceUpAfterFnRelease() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        _ = mapper.fnChanged(isDown: false)
        XCTAssertTrue(mapper.keyUp(code: 49).consumesEvent)
    }

    func testPhysicalMapperInterruptionClearsConsumedSpace() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        mapper.interrupt()
        XCTAssertFalse(mapper.keyUp(code: 49).consumesEvent)
        XCTAssertFalse(mapper.fnIsDown)
    }

    func testPhysicalMapperConsumesSpaceRepeatWithoutAnotherInput() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        XCTAssertEqual(mapper.keyDown(code: 49, isRepeat: true),
                       .init(input: nil, consumesEvent: true))
    }

    func testPhysicalMapperDoesNotConsumeUnrelatedLaterSpaceUp() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        mapper.interrupt()
        XCTAssertFalse(mapper.keyUp(code: 49).consumesEvent)
        XCTAssertFalse(mapper.keyUp(code: 49).consumesEvent)
    }

    func testConfiguredDefaultChordsCoexistWithBareHold() {
        assertSequence([.fnDown, .chordDown(.toggle), .chordUp(.toggle), .fnUp], state: .idle, events: [.toggleRequested])
        assertSequence([.fnDown, .chordDown(.cancel), .chordUp(.cancel), .fnUp], state: .idle, events: [.cancelRequested])
        assertSequence([.fnDown, .holdThresholdElapsed, .chordDown(.cancel), .fnUp], state: .idle,
                       events: [.pushToTalkBegan, .cancelRequested, .pushToTalkEnded])
    }

    func testConfiguredFnHoldBalancesOnKeyUpAndInterruption() {
        var mapper = FnPhysicalEventMapper(chords: [53: .hold])
        _ = mapper.fnChanged(isDown: true)
        XCTAssertEqual(mapper.keyDown(code: 53, isRepeat: false).input, .chordDown(.hold))
        XCTAssertNil(mapper.keyDown(code: 53, isRepeat: true).input)
        XCTAssertEqual(mapper.keyUp(code: 53).input, .chordUp(.hold))
        assertSequence([.fnDown, .chordDown(.hold), .chordUp(.hold)], state: .idle,
                       events: [.pushToTalkBegan, .pushToTalkEnded])
        assertSequence([.fnDown, .chordDown(.hold), .tapDisabled], state: .idle,
                       events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    private let inputs: [TriggerInput] = [
        .fnDown, .fnUp, .spaceDown, .chordDown(.toggle), .chordUp(.toggle), .otherKeyDown, .holdThresholdElapsed,
        .tapDisabled, .secureInputInterrupted
    ]

    private func assertSequence(
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
