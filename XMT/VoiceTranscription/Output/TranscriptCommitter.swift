import AppKit
import Foundation

@MainActor
struct TranscriptCommitter {
    struct Settings { let keepLastTranscript: Bool; let autoPaste: Bool }
    struct Result { let pasteError: Error? }
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
        do { try await dependencies.deleteRecovery() }
        catch { throw CommitError.recoveryCleanupFailed(error) }
        var pasteError: Error?
        if settings.autoPaste {
            do { try await dependencies.paste(transcript, targetPID) } catch { pasteError = error }
        }
        return Result(pasteError: pasteError)
    }
}
