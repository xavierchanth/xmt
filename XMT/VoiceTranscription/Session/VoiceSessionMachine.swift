import Foundation

/// Pure, single-flight voice-session reducer. Effects are interpreted by the module coordinator.
struct VoiceSessionMachine: Equatable {
    enum Mode: Equatable { case pushToTalk, latched }
    struct Session: Equatable { let id: UUID; let startedAt: Date; let localeIdentifier: String }
    struct Pending: Equatable { let id: UUID; let audioURL: URL }
    enum FailureReason: String, Codable, Equatable { case capture, transcription, commit, interrupted }
    enum DegradedReason: Error, Equatable { case unsupportedLocale, assetsMissing, noInputDevice, permissionDenied }
    enum State: Equatable {
        case idle
        case recording(Mode, Session)
        case finalizing(Session)
        case committing(Session)
        case failed(Pending)
        case degraded(DegradedReason)
    }
    enum Event {
        case pushToTalkBegan(Session)
        case pushToTalkEnded
        case toggle(Session)
        case armed(Mode, Session)
        case armingRefused(DegradedReason)
        case finalized(Session)
        case committed
        case failed(Pending)
        case retryBegan(Session)
        case pendingDeleted
        case recovered(Pending)
        case degrade(DegradedReason)
        case resetDegraded
    }
    enum Command: Equatable { case arm(Mode, Session); case stop(Session); case commit(Session); case retry(Pending); case deletePending(Pending) }
    enum Outcome: Equatable { case accepted([Command]); case dropped; case refused(DegradedReason) }

    private(set) var state: State = .idle

    static func maximumStopEvent(mode: Mode, session: Session) -> Event {
        mode == .latched ? .toggle(session) : .pushToTalkEnded
    }

    mutating func handle(_ event: Event) -> Outcome {
        switch (state, event) {
        case (.idle, .pushToTalkBegan(let s)):
            return .accepted([.arm(.pushToTalk, s)])
        case (.idle, .toggle(let s)):
            return .accepted([.arm(.latched, s)])
        case (.idle, .armed(let mode, let s)):
            state = .recording(mode, s); return .accepted([])
        case (.idle, .armingRefused(let reason)):
            return .refused(reason) // refusal is deliberately not durable state
        case (.recording(.pushToTalk, let active), .toggle):
            state = .recording(.latched, active); return .accepted([])
        case (.recording(.pushToTalk, let active), .pushToTalkEnded):
            state = .finalizing(active); return .accepted([.stop(active)])
        case (.recording(.latched, _), .pushToTalkEnded):
            return .accepted([])
        case (.recording(.latched, let active), .toggle):
            state = .finalizing(active); return .accepted([.stop(active)])
        case (.finalizing(let active), .finalized(let supplied)) where active == supplied:
            state = .committing(active); return .accepted([.commit(active)])
        case (.committing, .committed):
            state = .idle; return .accepted([])
        case (_, .failed(let pending)):
            state = .failed(pending); return .accepted([])
        case (.failed(let pending), .retryBegan(let session)):
            state = .finalizing(session); return .accepted([.retry(pending)])
        case (.failed(let pending), .pendingDeleted):
            state = .idle; return .accepted([.deletePending(pending)])
        case (.idle, .recovered(let pending)):
            state = .failed(pending); return .accepted([])
        case (.idle, .degrade(let reason)):
            state = .degraded(reason); return .accepted([])
        case (.failed, .pushToTalkBegan), (.failed, .toggle):
            return .dropped
        case (.degraded, .resetDegraded):
            state = .idle; return .accepted([])
        default:
            return .dropped
        }
    }
}
