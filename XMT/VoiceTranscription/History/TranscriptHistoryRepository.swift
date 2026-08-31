import Foundation

/// The read/delete surface the history user interface needs. It is deliberately narrower than the
/// store: surfaces never append, never prune, and never see retention policy, so the only writer of
/// history remains the commit path.
protocol TranscriptHistoryRepository: Sendable {
    /// Newest first; `limit` of `nil` means every retained entry.
    func entries(limit: Int?) async throws -> [TranscriptHistoryEntry]
    func delete(id: UUID) async throws
    func deleteAll() async throws
}

/// The shipping repository. It resolves the one process-wide store on first use, so opening the
/// database stays lazy: no history surface touches disk until the user opens one.
struct SharedTranscriptHistoryRepository: TranscriptHistoryRepository {
    var store: @Sendable () throws -> TranscriptHistoryStore = { try SharedTranscriptHistoryStore.shared() }

    func entries(limit: Int?) async throws -> [TranscriptHistoryEntry] { try await store().entries(limit: limit) }
    func delete(id: UUID) async throws { _ = try await store().delete(id: id) }
    func deleteAll() async throws { try await store().deleteAll() }
}

/// In-memory repository for tests, previews, and the degraded case where the durable store could not
/// be opened. It applies no retention of its own.
actor InMemoryTranscriptHistoryRepository: TranscriptHistoryRepository {
    private var storage: [TranscriptHistoryEntry]

    init(_ entries: [TranscriptHistoryEntry] = []) {
        storage = entries.enumerated().sorted {
            if $0.element.recordedAt != $1.element.recordedAt {
                return $0.element.recordedAt > $1.element.recordedAt
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    func entries(limit: Int?) async throws -> [TranscriptHistoryEntry] {
        guard let limit else { return storage }
        return Array(storage.prefix(max(0, limit)))
    }

    func delete(id: UUID) async throws { storage.removeAll { $0.id == id } }
    func deleteAll() async throws { storage.removeAll() }
}
