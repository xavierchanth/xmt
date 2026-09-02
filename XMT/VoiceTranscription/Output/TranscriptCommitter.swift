import AppKit
import Foundation

@MainActor
struct TranscriptCommitter {
    struct Settings {
        let autoPaste: Bool
        /// History is opt-in per commit; retries and non-final text never set it.
        var recordHistory: Bool = false
        /// Identity of the committing session. History rows are keyed by it, so a replayed commit
        /// after an interrupted run re-inserts the same row instead of a duplicate.
        var sessionID: UUID = UUID()
        var localeIdentifier: String = ""
        var historySource: TranscriptSource = .live
        var historyRetention: TranscriptRetentionPolicy = .default
    }

    struct Result { let pasteError: Error? }
    enum CommitError: Error { case historyStorageFailed(Error); case recoveryCleanupFailed(Error) }
    struct Dependencies {
        var setClipboard: (String) throws -> Void
        var paste: (String, pid_t?) async throws -> Void
        var deleteRecovery: () async throws -> Void
        /// Durable history append. Defaults to a no-op so a caller that wants no history writes none.
        var appendHistory: (TranscriptHistoryEntry, TranscriptRetentionPolicy) async throws -> Void = { _, _ in }

        @MainActor static var live: Dependencies {
            let board = NSPasteboard.general, service = PasteService()
            return Dependencies(
                setClipboard: { board.clearContents(); guard board.setString($0, forType: .string) else { throw CocoaError(.fileWriteUnknown) } },
                paste: { try await service.paste(text: $0, targetPID: $1) },
                deleteRecovery: {
                    _ = try Reconciliation.run(store: PendingRecordingStore(), transcriptWasCommitted: true)
                },
                appendHistory: { entry, retention in
                    try await SharedTranscriptHistoryStore.shared().append(entry, retention: retention)
                })
        }
    }

    var dependencies: Dependencies

    init(dependencies: Dependencies) { self.dependencies = dependencies }
    init() { self.init(dependencies: .live) }

    /// The deletion callback is the commit point: clipboard has succeeded and retention policy has
    /// been durably applied. Paste is intentionally subsequent and cannot invalidate that commit.
    func commit(_ transcript: String, settings: Settings, targetPID: pid_t?) async throws -> Result {
        try Task.checkCancellation()
        try dependencies.setClipboard(transcript)
        try Task.checkCancellation()
        // `last-transcript.txt` is legacy migration input only. New commits use SQLite history (or
        // process memory while history is disabled) and must never recreate the legacy file.
        // History is written before the commit point on purpose. A crash between the two replays the
        // whole commit from the surviving recovery artifact, and the append is idempotent by session
        // identity, so the replay restores the same single row rather than adding a second one.
        let entry = TranscriptHistoryPolicy.decide(TranscriptCommitContext(
            sessionID: settings.sessionID,
            recordedAt: Date(),
            text: transcript,
            localeIdentifier: settings.localeIdentifier,
            source: settings.historySource,
            historyEnabled: settings.recordHistory,
            secureInputActive: false,
            targetApplicationPID: targetPID)).entry
        if let entry {
            do { try await dependencies.appendHistory(entry, settings.historyRetention) }
            catch is CancellationError { throw CancellationError() }
            catch { throw CommitError.historyStorageFailed(error) }
        }
        try Task.checkCancellation()
        do { try await dependencies.deleteRecovery() }
        catch { throw CommitError.recoveryCleanupFailed(error) }
        try Task.checkCancellation()
        var pasteError: Error?
        if settings.autoPaste {
            do { try await dependencies.paste(transcript, targetPID) } catch { pasteError = error }
        }
        return Result(pasteError: pasteError)
    }
}
