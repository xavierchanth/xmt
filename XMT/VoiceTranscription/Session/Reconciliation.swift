import AVFoundation
import Foundation

enum Reconciliation {
    enum Result: Equatable { case clean; case pending(PendingRecordingStore.Pending) }

    /// Converges every interrupted/corrupt write to exactly clean or one complete pending pair.
    /// Audio always wins over metadata: an unreadable sidecar is replaced with conservative `und`
    /// metadata rather than causing user audio to be discarded.
    static func run(store: PendingRecordingStore, transcriptWasCommitted: Bool = false) throws -> Result {
        let fm = store.fileManager
        try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        try sweepAtomicTemps(store: store)
        if transcriptWasCommitted {
            try store.deletePending(); try store.clearActive(); return .clean
        }

        let pendingAudio = usableAudio(at: store.pendingAudioURL, fileManager: fm)
        let activeAudio = usableAudio(at: store.activeAudioURL, fileManager: fm)
        // Existing but unreadable/header-only files have no recoverable user frames.
        if !pendingAudio {
            try store.removeIfPresent(store.pendingAudioURL)
            // A sidecar accompanying unusable/missing pending audio must not be borrowed by a
            // different valid active recording; preserve that recording's own locale instead.
            try store.removeIfPresent(store.pendingMetadataURL)
        }
        if !activeAudio { try store.removeIfPresent(store.activeAudioURL) }
        if pendingAudio {
            // Complete/repair the winning pending slot and discard stale active artifacts.
            if (try? store.metadata(at: store.pendingMetadataURL)) == nil {
                try store.removeIfPresent(store.pendingMetadataURL)
                try store.writeMetadata(synthetic(reason: "metadataCorrupt"), to: store.pendingMetadataURL)
            }
            try store.clearActive()
            return .pending(try store.loadPending()!)
        }

        if activeAudio {
            // An interrupted pending sidecar may already exist. Repair it, then move audio.
            var metadata = try? store.metadata(at: store.pendingMetadataURL)
            if metadata == nil { metadata = try? store.metadata(at: store.activeMetadataURL) }
            let repaired = metadata ?? synthetic(reason: "metadataCorrupt")
            try store.removeIfPresent(store.pendingMetadataURL)
            try store.writeMetadata(repaired, to: store.pendingMetadataURL)
            try fm.moveItem(at: store.activeAudioURL, to: store.pendingAudioURL)
            try store.removeIfPresent(store.activeMetadataURL)
            return .pending(try store.loadPending()!)
        }

        // Sidecars without audio cannot recover content and must not block future recording.
        try store.deletePending(); try store.clearActive()
        return .clean
    }

    private static func synthetic(reason: String) -> PendingRecordingMetadata {
        PendingRecordingMetadata(sessionID: UUID(), timestamp: Date(), localeIdentifier: "und", failureReason: reason)
    }

    private static func sweepAtomicTemps(store: PendingRecordingStore) throws {
        for url in try store.fileManager.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(".recovery-metadata-") && url.pathExtension == "tmp" {
            try store.removeIfPresent(url)
        }
    }

    private static func usableAudio(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }
}
