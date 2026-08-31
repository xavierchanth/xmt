import XCTest

/// View-model behavior only: every repository, clipboard, capture, and paste effect is injected, so
/// no test opens a panel, touches the pasteboard, or performs Accessibility or TCC work.
@MainActor
final class TranscriptHistoryViewModelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Counting repository stub. `failure` makes every operation throw, so diagnostics are testable.
    private final class SpyRepository: TranscriptHistoryRepository, @unchecked Sendable {
        enum Failure: Error { case denied }
        var stored: [TranscriptHistoryEntry]
        var failure: Failure?
        var reads = 0
        var deleted: [UUID] = []
        var clears = 0

        init(_ stored: [TranscriptHistoryEntry]) {
            self.stored = stored.enumerated().sorted {
                $0.element.recordedAt == $1.element.recordedAt
                    ? $0.offset < $1.offset : $0.element.recordedAt > $1.element.recordedAt
            }.map(\.element)
        }

        var requestedLimits: [Int?] = []

        func entries(limit: Int?) async throws -> [TranscriptHistoryEntry] {
            reads += 1
            requestedLimits.append(limit)
            if let failure { throw failure }
            guard let limit else { return stored }
            return Array(stored.prefix(max(0, limit)))
        }

        func delete(id: UUID) async throws {
            if let failure { throw failure }
            deleted.append(id)
            stored.removeAll { $0.id == id }
        }

        func deleteAll() async throws {
            if let failure { throw failure }
            clears += 1
            stored.removeAll()
        }
    }

    private func entry(_ text: String, offset: TimeInterval, id: UUID = UUID()) -> TranscriptHistoryEntry {
        TranscriptHistoryEntry(id: id, recordedAt: base.addingTimeInterval(offset), text: text, localeIdentifier: "en-US")
    }

    private struct Harness {
        let model: TranscriptHistoryViewModel
        let repository: SpyRepository
        let clipboard: Box
        let pastes: PasteBox

        final class Box: @unchecked Sendable { var value: String?; var failure: Error? }
        final class PasteBox: @unchecked Sendable {
            var outcome: CapturedTargetPaster.Outcome = .pasted(42)
            var requests: [(String, CapturedPasteTarget?)] = []
        }
    }

    private func makeHarness(
        entries: [TranscriptHistoryEntry],
        target: CapturedPasteTarget? = CapturedPasteTarget(pid: 42, bundleIdentifier: "com.example.editor",
                                                           localizedName: "Editor", capturedAt: Date())
    ) -> Harness {
        let repository = SpyRepository(entries)
        let clipboard = Harness.Box()
        let pastes = Harness.PasteBox()
        let model = TranscriptHistoryViewModel(dependencies: .init(
            repository: repository,
            setClipboard: { text in
                if let failure = clipboard.failure { throw failure }
                clipboard.value = text
            },
            captureFrontmostTarget: { target },
            paste: { text, capturedTarget in
                pastes.requests.append((text, capturedTarget))
                return pastes.outcome
            },
            openDiagnostic: nil))
        return Harness(model: model, repository: repository, clipboard: clipboard, pastes: pastes)
    }

    func testHistoryIsReadLazilyAndOnlyOnceForLoadIfNeeded() async {
        let harness = makeHarness(entries: [entry("one", offset: 1)])
        XCTAssertEqual(harness.repository.reads, 0)
        await harness.model.loadIfNeeded()
        await harness.model.loadIfNeeded()
        XCTAssertEqual(harness.repository.reads, 1)
        XCTAssertTrue(harness.model.hasEntries)
    }

    func testMenuShowsFiveNewestPreviewsNewestFirst() async {
        let harness = makeHarness(entries: (0..<8).map { entry("transcript \($0)", offset: TimeInterval($0)) })
        await harness.model.loadIfNeeded()
        XCTAssertEqual(harness.model.recentPreviews.map(\.title),
                       ["transcript 7", "transcript 6", "transcript 5", "transcript 4", "transcript 3"])
    }

    func testMenuPreviewsAreSingleLineAndTruncated() async {
        let harness = makeHarness(entries: [entry("line one\nline two " + String(repeating: "x", count: 80), offset: 1)])
        await harness.model.loadIfNeeded()
        let title = try? XCTUnwrap(harness.model.recentPreviews.first?.title)
        XCTAssertFalse(title?.contains("\n") ?? true)
        XCTAssertEqual(title?.count, TranscriptHistorySnapshot.previewCharacterLimit + 1)
    }

    func testCopyLatestCopiesNewestTranscript() async {
        let harness = makeHarness(entries: [entry("older", offset: 1), entry("newest", offset: 5)])
        await harness.model.loadIfNeeded()
        harness.model.copyLatest()
        XCTAssertEqual(harness.clipboard.value, "newest")
        XCTAssertEqual(harness.model.feedback, "Copied transcript")
    }

    func testCopyLatestOnEmptyHistoryCopiesNothing() async {
        let harness = makeHarness(entries: [])
        await harness.model.loadIfNeeded()
        harness.model.copyLatest()
        XCTAssertNil(harness.clipboard.value)
        XCTAssertEqual(harness.model.feedback, "No transcript to copy")
    }

    func testSearchFiltersNewestFirstWithoutMutatingHistory() async {
        let harness = makeHarness(entries: [entry("buy milk", offset: 1), entry("call bank", offset: 2), entry("milk run", offset: 3)])
        await harness.model.loadIfNeeded()
        harness.model.searchQuery = "MILK"
        XCTAssertEqual(harness.model.results.map(\.text), ["milk run", "buy milk"])
        harness.model.searchQuery = ""
        XCTAssertEqual(harness.model.results.count, 3)
    }

    func testPasteUsesTheTargetCapturedBeforeTheSurfaceTookFocus() async {
        let harness = makeHarness(entries: [entry("dictated", offset: 1)])
        await harness.model.loadIfNeeded()
        harness.model.captureTarget()
        XCTAssertEqual(harness.model.capturedTarget?.pid, 42)
        await harness.model.paste(harness.model.snapshot.entries[0])
        XCTAssertEqual(harness.pastes.requests.count, 1)
        XCTAssertEqual(harness.pastes.requests[0].0, "dictated")
        XCTAssertEqual(harness.pastes.requests[0].1?.pid, 42)
        XCTAssertEqual(harness.model.feedback, "Pasted transcript")
        harness.model.releaseTarget()
        XCTAssertNil(harness.model.capturedTarget)
    }

    func testPasteFailureReportsThatTheTranscriptRemainsCopied() async {
        let harness = makeHarness(entries: [entry("dictated", offset: 1)])
        await harness.model.loadIfNeeded()
        harness.pastes.outcome = .pasteFailed
        await harness.model.paste(harness.model.snapshot.entries[0])
        XCTAssertEqual(harness.model.feedback, "Paste failed; transcript copied")

        harness.pastes.outcome = .copiedOnly(.terminated)
        await harness.model.paste(harness.model.snapshot.entries[0])
        XCTAssertEqual(harness.model.feedback, "Target app quit; transcript copied")
    }

    func testEveryTargetRejectionExplainsThatTheTranscriptWasCopied() {
        for rejection in [CapturedTargetRejection.noCapturedTarget, .terminated, .identityChanged, .isSelf, .expired] {
            XCTAssertTrue(TranscriptHistoryViewModel.message(for: rejection).hasSuffix("transcript copied"))
        }
    }

    func testDeleteRemovesFromRepositoryAndSnapshot() async {
        let doomed = UUID()
        let harness = makeHarness(entries: [entry("keep", offset: 1), entry("drop", offset: 2, id: doomed)])
        await harness.model.loadIfNeeded()
        await harness.model.delete(harness.model.snapshot.entry(id: doomed)!)
        XCTAssertEqual(harness.repository.deleted, [doomed])
        XCTAssertEqual(harness.model.snapshot.entries.map(\.text), ["keep"])
    }

    func testDeleteFailureKeepsTheEntryAndReportsDiagnostic() async {
        let doomed = UUID()
        let harness = makeHarness(entries: [entry("drop", offset: 2, id: doomed)])
        await harness.model.loadIfNeeded()
        harness.repository.failure = .denied
        await harness.model.delete(harness.model.snapshot.entry(id: doomed)!)
        XCTAssertEqual(harness.model.snapshot.entries.count, 1)
        XCTAssertEqual(harness.model.diagnostic, "Transcript could not be deleted")
    }

    func testClearRequiresConfirmationAndIsIgnoredUntilRequested() async {
        let harness = makeHarness(entries: [entry("one", offset: 1)])
        await harness.model.loadIfNeeded()

        await harness.model.confirmClear()
        XCTAssertEqual(harness.repository.clears, 0)
        XCTAssertTrue(harness.model.hasEntries)

        harness.model.requestClear()
        XCTAssertTrue(harness.model.isClearConfirmationPending)
        harness.model.cancelClear()
        await harness.model.confirmClear()
        XCTAssertEqual(harness.repository.clears, 0)
        XCTAssertTrue(harness.model.hasEntries)

        harness.model.requestClear()
        await harness.model.confirmClear()
        XCTAssertEqual(harness.repository.clears, 1)
        XCTAssertFalse(harness.model.hasEntries)
        XCTAssertFalse(harness.model.isClearConfirmationPending)
    }

    func testClearIsNotOfferedForEmptyHistory() async {
        let harness = makeHarness(entries: [])
        await harness.model.loadIfNeeded()
        harness.model.requestClear()
        XCTAssertFalse(harness.model.isClearConfirmationPending)
    }

    func testUnreadableHistoryReportsDiagnosticInsteadOfEntries() async {
        let harness = makeHarness(entries: [entry("one", offset: 1)])
        harness.repository.failure = .denied
        await harness.model.loadIfNeeded()
        XCTAssertFalse(harness.model.hasEntries)
        XCTAssertEqual(harness.model.diagnostic, "History could not be read")
    }

    func testCopyFailureIsReportedAndLeavesClipboardUntouched() async {
        enum Expected: Error { case clipboard }
        let harness = makeHarness(entries: [entry("one", offset: 1)])
        await harness.model.loadIfNeeded()
        harness.clipboard.failure = Expected.clipboard
        harness.model.copyLatest()
        XCTAssertNil(harness.clipboard.value)
        XCTAssertEqual(harness.model.feedback, "Could not copy transcript")
    }

    // MARK: - Menu reads must not truncate the panel

    func testMenuRefreshDoesNotTruncateTheOpenPanelsHistory() async {
        let harness = makeHarness(entries: (0..<8).map { entry("transcript \($0)", offset: TimeInterval($0)) })
        // The panel is open and listing everything.
        await harness.model.loadIfNeeded()
        XCTAssertEqual(harness.model.results.count, 8)

        // Opening the menu refreshes with a menu-sized hint while the panel is still open.
        await harness.model.reload(limit: TranscriptHistorySnapshot.menuPreviewCount)

        XCTAssertEqual(harness.model.results.count, 8, "a menu refresh truncated the panel's history")
        XCTAssertEqual(harness.model.recentPreviews.count, TranscriptHistorySnapshot.menuPreviewCount)
        XCTAssertEqual(harness.repository.requestedLimits, [nil, nil],
                       "the menu's limit must be ignored while a full-history surface is open")
    }

    func testPanelOpenedAfterAMenuReadStillSeesEveryEntry() async {
        let harness = makeHarness(entries: (0..<8).map { entry("transcript \($0)", offset: TimeInterval($0)) })
        // Menu first: a bounded read is enough for five previews.
        await harness.model.reload(limit: TranscriptHistorySnapshot.menuPreviewCount)
        XCTAssertEqual(harness.model.results.count, TranscriptHistorySnapshot.menuPreviewCount)

        // Then the panel, which must upgrade rather than reuse the truncated snapshot.
        await harness.model.loadIfNeeded()
        XCTAssertEqual(harness.model.results.count, 8)
        XCTAssertEqual(harness.repository.requestedLimits,
                       [TranscriptHistorySnapshot.menuPreviewCount, nil])
    }

    func testMenuReadIsBoundedAgainAfterThePanelCloses() async {
        let harness = makeHarness(entries: (0..<8).map { entry("transcript \($0)", offset: TimeInterval($0)) })
        await harness.model.loadIfNeeded()
        harness.model.completeSnapshotNoLongerNeeded()
        await harness.model.reload(limit: TranscriptHistorySnapshot.menuPreviewCount)
        XCTAssertEqual(harness.repository.requestedLimits,
                       [nil, TranscriptHistorySnapshot.menuPreviewCount])
    }

    // MARK: - Disabled history

    func testDisabledHistoryPerformsNoRepositoryWork() async {
        let harness = makeHarness(entries: [entry("one", offset: 1), entry("two", offset: 2)])
        harness.model.setHistoryEnabled(false)

        await harness.model.loadIfNeeded()
        await harness.model.reload(limit: TranscriptHistorySnapshot.menuPreviewCount)
        await harness.model.delete(entry("one", offset: 1))
        harness.model.requestClear()
        await harness.model.confirmClear()

        XCTAssertEqual(harness.repository.reads, 0, "a disabled surface read history")
        XCTAssertTrue(harness.repository.deleted.isEmpty)
        XCTAssertEqual(harness.repository.clears, 0)
        XCTAssertFalse(harness.model.hasEntries)
        XCTAssertFalse(harness.model.isClearConfirmationPending)
    }

    func testDisablingHistoryDropsTheLoadedSnapshotAndPendingConfirmation() async {
        let harness = makeHarness(entries: [entry("private", offset: 1)])
        await harness.model.loadIfNeeded()
        harness.model.captureTarget()
        harness.model.searchQuery = "priv"
        harness.model.requestClear()
        XCTAssertTrue(harness.model.isClearConfirmationPending)

        harness.model.setHistoryEnabled(false)

        XCTAssertFalse(harness.model.hasEntries)
        XCTAssertTrue(harness.model.results.isEmpty)
        XCTAssertFalse(harness.model.isClearConfirmationPending)
        XCTAssertEqual(harness.model.searchQuery, "")
        XCTAssertNil(harness.model.capturedTarget)
    }

    func testDisabledHistoryCapturesNoPasteTargetAndCopiesNothing() async {
        let harness = makeHarness(entries: [entry("private", offset: 1)])
        harness.model.setHistoryEnabled(false)
        harness.model.captureTarget()
        XCTAssertNil(harness.model.capturedTarget)
        harness.model.copyLatest()
        XCTAssertNil(harness.clipboard.value)
    }

    func testReEnablingHistoryReadsAgain() async {
        let harness = makeHarness(entries: [entry("one", offset: 1)])
        harness.model.setHistoryEnabled(false)
        await harness.model.loadIfNeeded()
        XCTAssertEqual(harness.repository.reads, 0)

        harness.model.setHistoryEnabled(true)
        await harness.model.loadIfNeeded()
        XCTAssertEqual(harness.repository.reads, 1)
        XCTAssertTrue(harness.model.hasEntries)
    }

    func testDisabledPanelControllerBuildsNothingAndReadsNothing() async {
        let harness = makeHarness(entries: [entry("one", offset: 1)])
        harness.model.setHistoryEnabled(false)
        let controller = TranscriptHistoryPanelController(viewModel: harness.model)

        controller.show()

        XCTAssertFalse(controller.isPresented, "a disabled Show All built a panel")
        XCTAssertEqual(harness.repository.reads, 0)
        XCTAssertNil(harness.model.capturedTarget)
    }

    func testInMemoryRepositoryAdapterServesNewestFirstAndDeletes() async throws {
        let doomed = UUID()
        let repository = InMemoryTranscriptHistoryRepository([entry("old", offset: 1), entry("new", offset: 9, id: doomed)])
        var entries = try await repository.entries(limit: nil)
        XCTAssertEqual(entries.map(\.text), ["new", "old"])
        let limited = try await repository.entries(limit: 1)
        XCTAssertEqual(limited.map(\.text), ["new"])
        try await repository.delete(id: doomed)
        entries = try await repository.entries(limit: nil)
        XCTAssertEqual(entries.map(\.text), ["old"])
        try await repository.deleteAll()
        let remaining = try await repository.entries(limit: nil)
        XCTAssertTrue(remaining.isEmpty)
    }
}
