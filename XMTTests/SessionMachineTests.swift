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
        let s = session(); var m = VoiceSessionMachine(); _ = m.handle(.armed(.pushToTalk, s))
        XCTAssertEqual(m.handle(.pushToTalkEnded), .accepted([.stop(s)]))
    }

    func testAllTriggerKindsDropThroughoutSingleFlightStates() {
        let s = session(), other = session()
        let states: [VoiceSessionMachine.State] = [.finalizing(s), .committing(s), .degraded(.assetsMissing)]
        for state in states {
            var m = VoiceSessionMachine(); if case .degraded = state { _ = m.handle(.degrade(.assetsMissing)) }
            // Construct the reachable finalizing/committing states.
            if case .finalizing = state { _ = m.handle(.armed(.pushToTalk, s)); _ = m.handle(.pushToTalkEnded) }
            if case .committing = state { _ = m.handle(.armed(.pushToTalk, s)); _ = m.handle(.pushToTalkEnded); _ = m.handle(.finalized(s)) }
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
        _ = m.handle(.armed(.pushToTalk, retry)); _ = m.handle(.pushToTalkEnded); _ = m.handle(.finalized(retry))
        let failed = VoiceSessionMachine.Pending(id: UUID(), audioURL: URL(fileURLWithPath: "/failed.caf"))
        XCTAssertEqual(m.handle(.failed(failed)), .accepted([])); XCTAssertEqual(m.state, .failed(failed))
        XCTAssertEqual(m.handle(.toggle(session())), .dropped)
    }

    func testMaximumDurationUsesReducerStopForBothModes() {
        let ptt = session(); var first = VoiceSessionMachine(); _ = first.handle(.armed(.pushToTalk, ptt))
        XCTAssertEqual(first.handle(VoiceSessionMachine.maximumStopEvent(mode: .pushToTalk, session: ptt)), .accepted([.stop(ptt)]))
        let latched = session(); var second = VoiceSessionMachine(); _ = second.handle(.armed(.latched, latched))
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
        XCTAssertEqual(machine.handle(.armingRefused(.assetsMissing)), .refused(.assetsMissing))
        XCTAssertEqual(machine.handle(.pushToTalkBegan(first)), .accepted([.arm(.pushToTalk, first)]))
        // Refusing a later fresh idle attempt remains non-durable as well.
        machine = VoiceSessionMachine()
        XCTAssertEqual(machine.handle(.armingRefused(.noInputDevice)), .refused(.noInputDevice))
        XCTAssertEqual(machine.handle(.toggle(second)), .accepted([.arm(.latched, second)]))
    }

    func testArmingRefusalIsOutcomeNotState() {
        var m = VoiceSessionMachine()
        XCTAssertEqual(m.handle(.armingRefused(.noInputDevice)), .refused(.noInputDevice)); XCTAssertEqual(m.state, .idle)
    }
}
