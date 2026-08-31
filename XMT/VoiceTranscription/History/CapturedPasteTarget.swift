import Foundation

/// The application that was frontmost when a history surface was opened. XMT's own panel takes key
/// focus, so the destination for a paste must be captured before that happens and re-verified
/// immediately before any event is posted.
struct CapturedPasteTarget: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let capturedAt: Date

    init(pid: pid_t, bundleIdentifier: String? = nil, localizedName: String? = nil, capturedAt: Date) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.capturedAt = capturedAt
    }
}

/// Why a captured target may no longer be pasted into. Every rejection is a refusal to post events,
/// never a fallback to "whatever is frontmost now".
enum CapturedTargetRejection: Equatable, Sendable {
    case noCapturedTarget
    case terminated
    case identityChanged
    case isSelf
    case expired
}

enum CapturedTargetVerification: Equatable, Sendable {
    case valid(pid_t)
    case rejected(CapturedTargetRejection)

    var pid: pid_t? { if case .valid(let pid) = self { return pid }; return nil }
    var rejection: CapturedTargetRejection? { if case .rejected(let reason) = self { return reason }; return nil }
}

/// Pure verification of a captured target against injected process facts. It performs no
/// Accessibility, TCC, or event work, so it is fully testable.
struct CapturedTargetVerifier {
    struct Dependencies {
        var isRunning: (pid_t) -> Bool
        var bundleIdentifier: (pid_t) -> String?
        var ownPID: () -> pid_t
        var now: () -> Date
    }

    /// A captured target is only trusted for a bounded time; PIDs are reused by the system.
    var maximumAge: TimeInterval
    var dependencies: Dependencies

    init(maximumAge: TimeInterval = 300, dependencies: Dependencies) {
        self.maximumAge = maximumAge
        self.dependencies = dependencies
    }

    func verify(_ target: CapturedPasteTarget?) -> CapturedTargetVerification {
        guard let target else { return .rejected(.noCapturedTarget) }
        guard target.pid != dependencies.ownPID() else { return .rejected(.isSelf) }
        guard dependencies.now().timeIntervalSince(target.capturedAt) <= maximumAge else { return .rejected(.expired) }
        guard dependencies.isRunning(target.pid) else { return .rejected(.terminated) }
        if let captured = target.bundleIdentifier, dependencies.bundleIdentifier(target.pid) != captured {
            return .rejected(.identityChanged)
        }
        return .valid(target.pid)
    }
}

/// Copies text to the clipboard, verifies the captured target, and only then asks the paste service
/// to post Command-V. The clipboard write always happens first and is never undone, so every failure
/// still leaves the transcript available for a manual paste.
struct CapturedTargetPaster {
    enum Outcome: Equatable {
        case pasted(pid_t)
        case noText
        case clipboardFailed
        case copiedOnly(CapturedTargetRejection)
        case pasteFailed
    }

    struct Dependencies {
        var setClipboard: (String) throws -> Void
        var verify: (CapturedPasteTarget?) -> CapturedTargetVerification
        var paste: (String, pid_t) async throws -> Void
    }

    var dependencies: Dependencies

    func paste(_ text: String, to target: CapturedPasteTarget?) async -> Outcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noText }
        do { try dependencies.setClipboard(text) } catch { return .clipboardFailed }
        switch dependencies.verify(target) {
        case .rejected(let reason):
            return .copiedOnly(reason)
        case .valid(let pid):
            do {
                try await dependencies.paste(text, pid)
                return .pasted(pid)
            } catch {
                // The transcript deliberately stays on the clipboard for a manual paste.
                return .pasteFailed
            }
        }
    }
}
