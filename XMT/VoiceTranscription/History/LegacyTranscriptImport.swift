import CryptoKit
import Foundation

/// One-time import of the pre-history one-slot cache (`last-transcript.txt`) into the durable store.
///
/// The import is crash-idempotent by construction, in two independent layers:
///
/// 1. **Deterministic identity.** The imported entry's id is derived from the file's bytes, so a
///    replay after a crash inserts the same primary key and is rejected as a duplicate.
/// 2. **Marker in the same transaction.** The completion marker is written with the entry inside a
///    single transaction, so the marker exists only if the entry does. Losing the marker costs a
///    harmless re-read; it can never produce a second row.
///
/// The legacy file is never modified or deleted: it remains the one-slot cache the existing
/// paste-latest path reads, and leaving it means a partial import has nothing to lose.
enum LegacyTranscriptImport {
    static let markerKey = "legacy_last_transcript_import"
    static let fileName = "last-transcript.txt"

    enum Outcome: Equatable, Sendable {
        /// No legacy file, or the file held nothing worth keeping. The marker still advances.
        case nothingToImport
        case imported(TranscriptHistoryEntry)
        /// The same legacy content was already imported, by a previous run or an interrupted one.
        case alreadyImported

        var entry: TranscriptHistoryEntry? { if case let .imported(entry) = self { return entry }; return nil }
    }

    /// Reads the legacy cache and returns the entry it should become, or `nil` when empty or absent.
    /// Pure with respect to the store: it performs no writes and decides nothing about idempotence.
    static func candidate(directory: URL, localeIdentifier: String, fileManager: FileManager = .default)
        -> (entry: TranscriptHistoryEntry, fingerprint: String)? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let fingerprint = Self.fingerprint(of: text)
        let recordedAt = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? Date()
        let entry = TranscriptHistoryEntry(
            id: identifier(fingerprint: fingerprint),
            recordedAt: recordedAt,
            text: text,
            localeIdentifier: localeIdentifier)
        return (entry, fingerprint)
    }

    /// Runs the import against a store. Safe to call on every launch and safe to interrupt at any
    /// point: the only durable effects are one conflict-guarded row and one marker, written together.
    @discardableResult
    static func run(store: TranscriptHistoryStore, directory: URL, localeIdentifier: String,
                    fileManager: FileManager = .default) async throws -> Outcome {
        let existingMarker = try await store.metadataValue(markerKey)
        guard let candidate = candidate(directory: directory, localeIdentifier: localeIdentifier,
                                        fileManager: fileManager) else {
            if existingMarker == nil { try await store.setMetadata(markerKey, "empty") }
            return .nothingToImport
        }
        if existingMarker == candidate.fingerprint { return .alreadyImported }
        let outcome = try await store.appendMarking(
            candidate.entry, marker: (markerKey, candidate.fingerprint))
        return outcome.didInsert ? .imported(candidate.entry) : .alreadyImported
    }

    /// Hex SHA-256 of the transcript text. Content-addressed so the same cache never imports twice,
    /// and so a rewritten cache with new text imports exactly once more.
    static func fingerprint(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable UUID for a fingerprint: the first sixteen digest bytes, stamped with the RFC 4122
    /// version-5 and variant bits so the value is a well-formed name-based UUID.
    static func identifier(fingerprint: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(fingerprint.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
