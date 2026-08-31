import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let transcriptHistoryLatestChanged = Notification.Name("TranscriptHistoryLatestChanged")
}

/// Main-actor owner of the transcript history surfaces. It holds a newest-first snapshot, mediates
/// every action the menu and the panel expose, and delegates persistence to a repository and paste
/// delivery to injected dependencies. It performs no Accessibility, clipboard, or SQLite work itself.
@MainActor
final class TranscriptHistoryViewModel: ObservableObject {
    struct MenuPreview: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    struct Dependencies {
        var repository: any TranscriptHistoryRepository
        var setClipboard: (String) throws -> Void
        var captureFrontmostTarget: () -> CapturedPasteTarget?
        var paste: (String, CapturedPasteTarget?) async -> CapturedTargetPaster.Outcome

        @MainActor static var live: Dependencies {
            let board = NSPasteboard.general
            let service = PasteService()
            let setClipboard: (String) throws -> Void = {
                board.clearContents()
                guard board.setString($0, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
            }
            let verifier = CapturedTargetVerifier(dependencies: .live)
            let paster = CapturedTargetPaster(dependencies: .init(
                setClipboard: setClipboard,
                verify: { verifier.verify($0) },
                paste: { try await service.paste(text: $0, targetPID: $1) }))
            return Dependencies(
                repository: SharedTranscriptHistoryRepository(),
                setClipboard: setClipboard,
                captureFrontmostTarget: { CapturedPasteTarget.frontmost() },
                paste: { await paster.paste($0, to: $1) })
        }
    }

    static let shared = TranscriptHistoryViewModel()

    @Published private(set) var snapshot = TranscriptHistorySnapshot()
    @Published var searchQuery = ""
    @Published private(set) var isClearConfirmationPending = false
    @Published private(set) var feedback: String?
    @Published private(set) var diagnostic: String?
    @Published private(set) var capturedTarget: CapturedPasteTarget?
    /// Effective history setting. While false every surface is inert: nothing reads, deletes, or
    /// clears, so no repository call — and therefore no database creation — can originate here.
    @Published private(set) var isHistoryEnabled = false

    private var dependencies: Dependencies
    /// True when the snapshot in hand holds every retained entry rather than a menu-sized prefix.
    private var isSnapshotComplete = false
    /// Set while a surface that lists everything (the panel) is open. It makes a menu-sized read
    /// upgrade to a full one, so refreshing the menu can never truncate what the panel is showing.
    private var requiresCompleteSnapshot = false
    private var feedbackGeneration: UInt64 = 0
    private var isPasting = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    convenience init() { self.init(dependencies: .live) }

    /// Newest-first results for the panel; a blank query lists everything.
    var results: [TranscriptHistoryEntry] { snapshot.search(searchQuery) }

    /// The bounded newest-first previews the menu shows inline.
    var recentPreviews: [MenuPreview] {
        snapshot.recent().map { MenuPreview(id: $0.id, title: TranscriptHistorySnapshot.preview(of: $0.text)) }
    }

    var hasEntries: Bool { !snapshot.isEmpty }

    /// Reads persisted history once, lazily: no storage is touched until a surface needs it. The
    /// caller is a surface that lists everything, so later menu-sized reads stay complete.
    func loadIfNeeded() async {
        guard isHistoryEnabled else { return }
        requiresCompleteSnapshot = true
        guard !isSnapshotComplete else { return }
        await reload()
    }

    /// Reads history newest first. `limit` is a hint, not a promise: while a surface needs the whole
    /// history the limit is ignored, because a menu refresh must never shrink the panel's list.
    func reload(limit: Int? = nil) async {
        guard isHistoryEnabled else { return }
        let effectiveLimit = requiresCompleteSnapshot ? nil : limit
        do {
            snapshot = TranscriptHistorySnapshot(try await dependencies.repository.entries(limit: effectiveLimit))
            isSnapshotComplete = effectiveLimit == nil
            } catch {
            diagnostic = "History could not be read"
        }
    }

    /// Applies the effective history setting. Disabling drops the in-memory snapshot and any pending
    /// confirmation immediately, so nothing recorded before the change stays visible or actionable.
    func setHistoryEnabled(_ enabled: Bool) {
        guard enabled != isHistoryEnabled else { return }
        isHistoryEnabled = enabled
        isSnapshotComplete = false
        requiresCompleteSnapshot = false
        if !enabled {
            snapshot = TranscriptHistorySnapshot()
            isClearConfirmationPending = false
            searchQuery = ""
            capturedTarget = nil
        }
    }

    /// A full-history surface closed. The next menu read may be menu-sized again.
    func completeSnapshotNoLongerNeeded() { requiresCompleteSnapshot = false }

    func copyLatest() {
        guard let latest = snapshot.latest else { return showFeedback("No transcript to copy") }
        copy(latest)
    }

    func copy(_ entry: TranscriptHistoryEntry) {
        do { try dependencies.setClipboard(entry.text); showFeedback("Copied transcript") }
        catch { showFeedback("Could not copy transcript") }
    }

    func copy(id: UUID) { if let entry = snapshot.entry(id: id) { copy(entry) } }

    /// Pastes into the target captured before this surface took key focus. Single-flight: an
    /// overlapping request is dropped rather than queued, and the clipboard always keeps the text.
    func paste(_ entry: TranscriptHistoryEntry) async {
        guard !isPasting else { return }
        isPasting = true
        let outcome = await dependencies.paste(entry.text, capturedTarget)
        isPasting = false
        switch outcome {
        case .pasted: showFeedback("Pasted transcript")
        case .noText: showFeedback("No transcript to paste")
        case .clipboardFailed: showFeedback("Could not copy transcript")
        case .pasteFailed: showFeedback("Paste failed; transcript copied")
        case .copiedOnly(let reason): showFeedback(Self.message(for: reason))
        }
    }

    func paste(id: UUID) async { if let entry = snapshot.entry(id: id) { await paste(entry) } }

    func delete(_ entry: TranscriptHistoryEntry) async {
        guard isHistoryEnabled else { return }
        do {
            try await dependencies.repository.delete(id: entry.id)
            // Re-read rather than deriving from the panel's load-once snapshot: a transcript may
            // have committed while the panel was open, and Paste Latest must follow the store.
            snapshot = TranscriptHistorySnapshot(try await dependencies.repository.entries(limit: nil))
            isSnapshotComplete = true
                NotificationCenter.default.post(name: .transcriptHistoryLatestChanged,
                                            object: snapshot.entries.first?.text ?? "")
            showFeedback("Deleted transcript")
        } catch {
            diagnostic = "Transcript could not be deleted"
        }
    }

    /// Clearing is destructive, so it is always two-step: request, then confirm.
    func requestClear() {
        guard isHistoryEnabled, hasEntries else { return }
        isClearConfirmationPending = true
    }

    func cancelClear() { isClearConfirmationPending = false }

    func confirmClear() async {
        guard isHistoryEnabled, isClearConfirmationPending else { return }
        isClearConfirmationPending = false
        do {
            try await dependencies.repository.deleteAll()
            var updated = snapshot
            updated.removeAll()
            snapshot = updated
                NotificationCenter.default.post(name: .transcriptHistoryLatestChanged, object: "")
            showFeedback("History cleared")
        } catch {
            diagnostic = "History could not be cleared"
        }
    }

    /// Captures the frontmost application before an XMT history surface takes key focus.
    func captureTarget() {
        guard isHistoryEnabled else { return }
        capturedTarget = dependencies.captureFrontmostTarget()
    }

    func releaseTarget() { capturedTarget = nil }

    private func showFeedback(_ message: String) {
        feedbackGeneration &+= 1
        let generation = feedbackGeneration
        feedback = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if feedbackGeneration == generation { feedback = nil }
        }
    }

    static func message(for rejection: CapturedTargetRejection) -> String {
        switch rejection {
        case .noCapturedTarget, .isSelf: return "No target app; transcript copied"
        case .terminated: return "Target app quit; transcript copied"
        case .identityChanged: return "Target app changed; transcript copied"
        case .expired: return "Target capture expired; transcript copied"
        }
    }
}

extension CapturedPasteTarget {
    /// Live capture of the frontmost application, excluding XMT itself.
    @MainActor static func frontmost(now: Date = Date()) -> CapturedPasteTarget? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else { return nil }
        return CapturedPasteTarget(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                                   localizedName: app.localizedName, capturedAt: now)
    }
}

extension CapturedTargetVerifier.Dependencies {
    /// Live process facts. Identity is re-read from the running application, so a reused PID
    /// belonging to a different application is rejected rather than pasted into.
    static var live: CapturedTargetVerifier.Dependencies {
        CapturedTargetVerifier.Dependencies(
            isRunning: { NSRunningApplication(processIdentifier: $0)?.isTerminated == false },
            bundleIdentifier: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
            ownPID: { ProcessInfo.processInfo.processIdentifier },
            now: Date.init)
    }
}
