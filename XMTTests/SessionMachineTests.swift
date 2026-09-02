import XCTest

final class SessionMachineTests: XCTestCase {
    private func session() -> VoiceSessionMachine.Session { .init(id: UUID(), startedAt: Date(), localeIdentifier: "en-US") }

    func testPTTStopsButToggleLatchesExistingSession() {
        let s = session(); var m = VoiceSessionMachine()
        XCTAssertEqual(m.handle(.pushToTalkBegan(s)), .accepted([.arm(.pushToTalk, s)]))
        _ = m.handle(.armed(.pushToTalk, s))
        XCTAssertEqual(m.handle(.toggle(session())), .accepted([]))
        XCTAssertEqual(m.state, .recording(.latched, s))
        XCTAssertEqual(m.handle(.pushToTalkEnded), .accepted([]))
        XCTAssertEqual(m.handle(.toggle(session())), .accepted([.stop(s)]))
        XCTAssertEqual(m.state, .finalizing(s))
    }

    func testUnlatchedPTTEndStops() {
        let s = session(); var m = VoiceSessionMachine(); _ = m.handle(.pushToTalkBegan(s)); _ = m.handle(.armed(.pushToTalk, s))
        XCTAssertEqual(m.handle(.pushToTalkEnded), .accepted([.stop(s)]))
    }

    func testAllTriggerKindsDropThroughoutSingleFlightStates() {
        let s = session(), other = session()
        let states: [VoiceSessionMachine.State] = [.finalizing(s), .committing(s), .degraded(.assetsMissing)]
        for state in states {
            var m = VoiceSessionMachine(); if case .degraded = state { _ = m.handle(.degrade(.assetsMissing)) }
            // Construct the reachable finalizing/committing states.
            if case .finalizing = state { _ = m.handle(.pushToTalkBegan(s)); _ = m.handle(.armed(.pushToTalk, s)); _ = m.handle(.pushToTalkEnded) }
            if case .committing = state { _ = m.handle(.pushToTalkBegan(s)); _ = m.handle(.armed(.pushToTalk, s)); _ = m.handle(.pushToTalkEnded); _ = m.handle(.finalized(s)) }
            XCTAssertEqual(m.handle(.pushToTalkBegan(other)), .dropped)
            XCTAssertEqual(m.handle(.toggle(other)), .dropped)
        }
    }

    func testPendingRefusesNewRecordingAndSupportsExplicitDelete() {
        let pending = VoiceSessionMachine.Pending(id: UUID(), audioURL: URL(fileURLWithPath: "/p.caf"))
        var m = VoiceSessionMachine(); _ = m.handle(.recovered(pending))
        XCTAssertEqual(m.handle(.pushToTalkBegan(session())), .dropped)
        XCTAssertEqual(m.handle(.pendingDeleted), .accepted([.deletePending(pending)])); XCTAssertEqual(m.state, .idle)
    }

    func testRetryThenCommitSuccessAndFailure() {
        let pending = VoiceSessionMachine.Pending(id: UUID(), audioURL: URL(fileURLWithPath: "/p.caf"))
        let retry = session(); var m = VoiceSessionMachine(); _ = m.handle(.recovered(pending))
        XCTAssertEqual(m.handle(.retryBegan(retry)), .accepted([.retry(pending)]))
        XCTAssertEqual(m.handle(.finalized(retry)), .accepted([.commit(retry)]))
        XCTAssertEqual(m.handle(.committed), .accepted([])); XCTAssertEqual(m.state, .idle)
        _ = m.handle(.pushToTalkBegan(retry)); _ = m.handle(.armed(.pushToTalk, retry)); _ = m.handle(.pushToTalkEnded); _ = m.handle(.finalized(retry))
        let failed = VoiceSessionMachine.Pending(id: UUID(), audioURL: URL(fileURLWithPath: "/failed.caf"))
        XCTAssertEqual(m.handle(.failed(failed)), .accepted([])); XCTAssertEqual(m.state, .failed(failed))
        XCTAssertEqual(m.handle(.toggle(session())), .dropped)
    }

    func testMaximumDurationUsesReducerStopForBothModes() {
        let ptt = session(); var first = VoiceSessionMachine(); _ = first.handle(.pushToTalkBegan(ptt)); _ = first.handle(.armed(.pushToTalk, ptt))
        XCTAssertEqual(first.handle(VoiceSessionMachine.maximumStopEvent(mode: .pushToTalk, session: ptt)), .accepted([.stop(ptt)]))
        let latched = session(); var second = VoiceSessionMachine(); _ = second.handle(.toggle(latched)); _ = second.handle(.armed(.latched, latched))
        XCTAssertEqual(second.handle(VoiceSessionMachine.maximumStopEvent(mode: .latched, session: latched)), .accepted([.stop(latched)]))
    }

    func testDegradedResetAllowsNextTriggerToArm() {
        let s = session(); var machine = VoiceSessionMachine()
        _ = machine.handle(.degrade(.permissionDenied))
        XCTAssertEqual(machine.handle(.pushToTalkBegan(s)), .dropped)
        XCTAssertEqual(machine.handle(.resetDegraded), .accepted([]))
        XCTAssertEqual(machine.handle(.pushToTalkBegan(s)), .accepted([.arm(.pushToTalk, s)]))
    }

    func testRepeatedArmingRefusalNeverWedgesReducer() {
        let first = session(), second = session(); var machine = VoiceSessionMachine()
        _ = machine.handle(.pushToTalkBegan(first))
        XCTAssertEqual(machine.handle(.armingRefused(first, .assetsMissing)), .refused(.assetsMissing))
        XCTAssertEqual(machine.handle(.pushToTalkBegan(second)), .accepted([.arm(.pushToTalk, second)]))
        XCTAssertEqual(machine.handle(.armingRefused(second, .noInputDevice)), .refused(.noInputDevice))
        XCTAssertEqual(machine.state, .idle)
    }

    func testArmingRefusalIsOutcomeNotState() {
        let s = session(); var m = VoiceSessionMachine()
        _ = m.handle(.pushToTalkBegan(s))
        XCTAssertEqual(m.handle(.armingRefused(s, .noInputDevice)), .refused(.noInputDevice)); XCTAssertEqual(m.state, .idle)
    }

    func testPushToTalkReleaseCancelsArmingAndRejectsStaleCompletion() {
        let s = session(); var m = VoiceSessionMachine()
        _ = m.handle(.pushToTalkBegan(s))
        XCTAssertEqual(m.state, .arming(.pushToTalk, s))
        XCTAssertEqual(m.handle(.pushToTalkEnded), .accepted([.cancelArm(s)]))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.handle(.armed(.pushToTalk, s)), .dropped)
    }

    func testToggleDuringPushToTalkArmingLatchesTheSameSession() {
        let s = session(); var m = VoiceSessionMachine()
        _ = m.handle(.pushToTalkBegan(s))
        XCTAssertEqual(m.handle(.toggle(session())), .accepted([]))
        XCTAssertEqual(m.state, .arming(.latched, s))
        XCTAssertEqual(m.handle(.pushToTalkEnded), .accepted([]))
        XCTAssertEqual(m.handle(.armed(.latched, s)), .accepted([]))
        XCTAssertEqual(m.state, .recording(.latched, s))
    }

    func testInterruptionCancelsArmingAndStopsEitherRecordingMode() {
        for mode in [VoiceSessionMachine.Mode.pushToTalk, .latched] {
            let s = session(); var arming = VoiceSessionMachine()
            _ = arming.handle(mode == .pushToTalk ? .pushToTalkBegan(s) : .toggle(s))
            XCTAssertEqual(arming.handle(.interrupted), .accepted([.discard(s)]))

            var recording = VoiceSessionMachine()
            _ = recording.handle(mode == .pushToTalk ? .pushToTalkBegan(s) : .toggle(s))
            _ = recording.handle(.armed(mode, s))
            XCTAssertEqual(recording.handle(.interrupted), .accepted([.discard(s)]))
        }
    }
    func testPartialUpdatesRequireLifecycleAndRecordingSessionIdentity() {
        let expected = UUID()
        XCTAssertTrue(VoicePartialUpdatePolicy.allows(capturedLifecycle: 4, currentLifecycle: 4,
                                                       expectedSession: expected, currentRecordingSession: expected))
        XCTAssertFalse(VoicePartialUpdatePolicy.allows(capturedLifecycle: 3, currentLifecycle: 4,
                                                        expectedSession: expected, currentRecordingSession: expected))
        XCTAssertFalse(VoicePartialUpdatePolicy.allows(capturedLifecycle: 4, currentLifecycle: 4,
                                                        expectedSession: expected, currentRecordingSession: UUID()))
        XCTAssertFalse(VoicePartialUpdatePolicy.allows(capturedLifecycle: 4, currentLifecycle: 4,
                                                        expectedSession: expected, currentRecordingSession: nil))
    }

    func testPrivacyCancellationNeverPromotesRecoveryAtLifecycleStop() {
        XCTAssertFalse(VoiceTeardownPolicy.shouldPromoteRecovery(for: .privacyCancellation))
        XCTAssertTrue(VoiceTeardownPolicy.shouldPromoteRecovery(for: .lifecycleStop))
    }

}
