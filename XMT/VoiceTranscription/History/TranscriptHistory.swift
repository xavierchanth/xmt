import Foundation

/// Pure newest-first presentation of transcript history. It holds a bounded snapshot of persisted
/// entries and answers everything the menu and the panel need — previews, search, latest — without
/// touching storage, clipboard, or any paste target.
///
/// Persistence and retention belong to `TranscriptHistoryStore` and `TranscriptHistoryPolicy`; this
/// type never writes and never invents entries.
struct TranscriptHistorySnapshot: Equatable, Sendable {
    static let menuPreviewCount = 5
    static let previewCharacterLimit = 60

    private(set) var entries: [TranscriptHistoryEntry]

    init(_ entries: [TranscriptHistoryEntry] = []) {
        var seen = Set<UUID>()
        // Repositories already provide their durable sequence order. A stable filter preserves it,
        // including timestamp ties, rather than inventing an unrelated UUID tie-break.
        self.entries = entries.filter { !$0.text.isEmpty && seen.insert($0.id).inserted }
    }

    var isEmpty: Bool { entries.isEmpty }
    var latest: TranscriptHistoryEntry? { entries.first }

    /// Newest-first prefix used by the menu. Never more than `count` entries.
    func recent(_ count: Int = TranscriptHistorySnapshot.menuPreviewCount) -> [TranscriptHistoryEntry] {
        Array(entries.prefix(max(0, count)))
    }

    func entry(id: UUID) -> TranscriptHistoryEntry? { entries.first { $0.id == id } }

    /// Case- and diacritic-insensitive substring search preserving newest-first order. A blank query
    /// matches everything rather than nothing.
    func search(_ query: String) -> [TranscriptHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Local removal after a repository delete succeeded. Returns false when the entry was already gone.
    @discardableResult
    mutating func remove(id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    mutating func removeAll() { entries.removeAll() }

    /// Single-line, length-bounded rendering for menu items and list rows.
    static func preview(of text: String, limit: Int = TranscriptHistorySnapshot.previewCharacterLimit) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard limit > 0, collapsed.count > limit else { return collapsed }
        return collapsed.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension TranscriptHistoryEntry: Identifiable {}
