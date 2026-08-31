import XCTest

final class TranscriptHistorySnapshotTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ text: String, offset: TimeInterval, id: UUID = UUID()) -> TranscriptHistoryEntry {
        TranscriptHistoryEntry(id: id, recordedAt: base.addingTimeInterval(offset), text: text, localeIdentifier: "en-US")
    }

    func testSnapshotOrdersNewestFirstRegardlessOfInputOrder() {
        let snapshot = TranscriptHistorySnapshot([entry("old", offset: 0), entry("newest", offset: 20), entry("middle", offset: 10)])
        XCTAssertEqual(snapshot.entries.map(\.text), ["newest", "middle", "old"])
        XCTAssertEqual(snapshot.latest?.text, "newest")
    }

    func testRecentIsBoundedToFiveNewestForTheMenu() {
        let snapshot = TranscriptHistorySnapshot((0..<9).map { entry("t\($0)", offset: TimeInterval($0)) })
        XCTAssertEqual(TranscriptHistorySnapshot.menuPreviewCount, 5)
        XCTAssertEqual(snapshot.recent().map(\.text), ["t8", "t7", "t6", "t5", "t4"])
        XCTAssertEqual(snapshot.recent(0).count, 0)
        XCTAssertEqual(snapshot.recent(100).count, 9)
    }

    func testSnapshotDropsEmptyTextAndDuplicateIdentities() {
        let shared = UUID()
        let snapshot = TranscriptHistorySnapshot([
            entry("kept", offset: 5, id: shared), entry("duplicate", offset: 6, id: shared), entry("", offset: 7)
        ])
        XCTAssertEqual(snapshot.entries.map(\.text), ["kept"])
    }

    func testSearchIsNewestFirstCaseAndDiacriticInsensitive() {
        let snapshot = TranscriptHistorySnapshot([
            entry("Café review", offset: 1), entry("unrelated", offset: 2), entry("later cafe visit", offset: 3)
        ])
        XCTAssertEqual(snapshot.search("cafe").map(\.text), ["later cafe visit", "Café review"])
        XCTAssertEqual(snapshot.search("   ").map(\.text), snapshot.entries.map(\.text))
        XCTAssertTrue(snapshot.search("absent").isEmpty)
    }

    func testRemoveAffectsOnlyTheNamedEntry() {
        let doomed = UUID()
        var snapshot = TranscriptHistorySnapshot([entry("keep", offset: 1), entry("drop", offset: 2, id: doomed)])
        XCTAssertTrue(snapshot.remove(id: doomed))
        XCTAssertFalse(snapshot.remove(id: doomed))
        XCTAssertEqual(snapshot.entries.map(\.text), ["keep"])
        snapshot.removeAll()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testPreviewCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(TranscriptHistorySnapshot.preview(of: " hello\n  there \t friend "), "hello there friend")
        let long = String(repeating: "a", count: 80)
        let preview = TranscriptHistorySnapshot.preview(of: long, limit: 10)
        XCTAssertEqual(preview, String(repeating: "a", count: 10) + "…")
        XCTAssertEqual(TranscriptHistorySnapshot.preview(of: "short", limit: 0), "short")
    }
}
