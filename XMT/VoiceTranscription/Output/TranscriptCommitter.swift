import AppKit
import Foundation

@MainActor
struct TranscriptCommitter {
    struct Settings {
        let keepLastTranscript: Bool
        let autoPaste: Bool
        /// History is opt-in per commit; retries and non-final text never set it.
        var recordHistory: Bool = false
        /// Identity of the committing session. History rows are keyed by it, so a replayed commit
        /// after an interrupted run re-inserts the same row instead of a duplicate.
        var sessionID: UUID = UUID()
        var localeIdentifier: String = ""
        var secureInputActive: Bool = false
        var historyRetention: TranscriptRetentionPolicy = .default
    }

    struct Result {
        let pasteError: Error?
        /// History is an accessory of the commit, never a precondition: a failed append is reported
        /// but never withdraws the clipboard, the retained file, or the recovery deletion.
        var historyError: Error?
        var historyEntry: TranscriptHistoryEntry?
    }
    enum CommitError: Error { case recoveryCleanupFailed(Error) }
    struct Dependencies {
        var setClipboard: (String) throws -> Void
        var write: (Data, URL) throws -> Void
        var move: (URL, URL) throws -> Void
        var replace: (URL, URL) throws -> Void
        var remove: (URL) throws -> Void
        var exists: (URL) -> Bool
        var paste: (String, pid_t?) async throws -> Void
        var deleteRecovery: () async throws -> Void
        /// Durable history append. Defaults to a no-op so a caller that wants no history writes none.
        var appendHistory: (TranscriptHistoryEntry, TranscriptRetentionPolicy) async throws -> Void = { _, _ in }

        @MainActor static var live: Dependencies {
            let fm = FileManager.default, board = NSPasteboard.general, service = PasteService()
            return Dependencies(
                setClipboard: { board.clearContents(); guard board.setString($0, forType: .string) else { throw CocoaError(.fileWriteUnknown) } },
                write: { try $0.write(to: $1, options: [.atomic]) }, move: { try fm.moveItem(at: $0, to: $1) },
                replace: { source, destination in _ = try fm.replaceItemAt(destination, withItemAt: source) },
                remove: { if fm.fileExists(atPath: $0.path) { try fm.removeItem(at: $0) } },
                exists: { fm.fileExists(atPath: $0.path) },
                paste: { try await service.paste(text: $0, targetPID: $1) },
                deleteRecovery: {
                    _ = try Reconciliation.run(store: PendingRecordingStore(), transcriptWasCommitted: true)
                },
                appendHistory: { entry, retention in
                    try await SharedTranscriptHistoryStore.shared().append(entry, retention: retention)
                })
        }
    }

    let directory: URL
    var dependencies: Dependencies
    var transcriptURL: URL { directory.appendingPathComponent("last-transcript.txt") }

    init(directory: URL? = nil, dependencies: Dependencies) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.xavierchanth.xmt/VoiceTranscription", isDirectory: true)
        self.dependencies = dependencies
    }

    init(directory: URL? = nil) { self.init(directory: directory, dependencies: .live) }

    static func loadRetainedTranscript(directory: URL? = nil) throws -> String? {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.xavierchanth.xmt/VoiceTranscription", isDirectory: true)
        let url = base.appendingPathComponent("last-transcript.txt")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    /// The deletion callback is the commit point: clipboard has succeeded and retention policy has
    /// been durably applied. Paste is intentionally subsequent and cannot invalidate that commit.
    func commit(_ transcript: String, settings: Settings, targetPID: pid_t?) async throws -> Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try dependencies.setClipboard(transcript)
        if settings.keepLastTranscript {
            let temporary = directory.appendingPathComponent(".last-transcript-\(UUID().uuidString).tmp")
            do {
                try dependencies.write(Data(transcript.utf8), temporary)
                if dependencies.exists(transcriptURL) { try dependencies.replace(temporary, transcriptURL) }
                else { try dependencies.move(temporary, transcriptURL) }
            } catch { try? dependencies.remove(temporary); throw error }
        } else {
            try dependencies.remove(transcriptURL)
        }
        // History is written before the commit point on purpose. A crash between the two replays the
        // whole commit from the surviving recovery artifact, and the append is idempotent by session
        // identity, so the replay restores the same single row rather than adding a second one.
        var historyError: Error?
        let entry = TranscriptHistoryPolicy.decide(TranscriptCommitContext(
            sessionID: settings.sessionID,
            recordedAt: Date(),
            text: transcript,
            localeIdentifier: settings.localeIdentifier,
            historyEnabled: settings.recordHistory,
            secureInputActive: settings.secureInputActive,
            targetApplicationPID: targetPID)).entry
        if let entry {
            do { try await dependencies.appendHistory(entry, settings.historyRetention) }
            catch { historyError = error }
        }
        do { try await dependencies.deleteRecovery() }
        catch { throw CommitError.recoveryCleanupFailed(error) }
        var pasteError: Error?
        if settings.autoPaste {
            do { try await dependencies.paste(transcript, targetPID) } catch { pasteError = error }
        }
        return Result(pasteError: pasteError, historyError: historyError,
                      historyEntry: historyError == nil ? entry : nil)
    }
}
