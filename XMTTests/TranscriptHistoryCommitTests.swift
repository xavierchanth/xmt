import XCTest

/// Where the durable history write sits in the commit sequence, and what a crash around it costs.
@MainActor final class TranscriptHistoryCommitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func recordingDependencies(
        into events: @escaping (String) -> Void,
        appendHistory: @escaping (TranscriptHistoryEntry, TranscriptRetentionPolicy) async throws -> Void
    ) -> TranscriptCommitter.Dependencies {
        let fm = FileManager.default
        return TranscriptCommitter.Dependencies(
            setClipboard: { _ in events("clipboard") },
            write: { try $0.write(to: $1); events("temp") },
            move: { try fm.moveItem(at: $0, to: $1); events("move") },
            replace: { source, destination in
                _ = try fm.replaceItemAt(destination, withItemAt: source); events("replace")
            },
            remove: { if fm.fileExists(atPath: $0.path) { try fm.removeItem(at: $0) } },
            exists: { fm.fileExists(atPath: $0.path) },
            paste: { _, _ in events("paste") },
            deleteRecovery: { events("delete-audio") },
            appendHistory: { entry, _ in events("history:\(entry.text)"); try await appendHistory(entry, .default) })
    }

    private func settings(sessionID: UUID, recordHistory: Bool = true, keepLastTranscript: Bool = true,
                          autoPaste: Bool = true) -> TranscriptCommitter.Settings {
        TranscriptCommitter.Settings(
            keepLastTranscript: keepLastTranscript, autoPaste: autoPaste, recordHistory: recordHistory,
            sessionID: sessionID, localeIdentifier: "en-US")
    }

    func testHistoryIsWrittenAfterRetentionAndBeforeTheCommitPointAndPaste() async throws {
        var events: [String] = []
        let deps = recordingDependencies(into: { events.append($0) }, appendHistory: { _, _ in })
        let result = try await TranscriptCommitter(directory: root, dependencies: deps)
            .commit("ordered", settings: settings(sessionID: UUID()), targetPID: 12)

        XCTAssertEqual(events, ["clipboard", "history:ordered", "delete-audio", "paste"])
        XCTAssertNil(result.pasteError)
        XCTAssertNil(result.historyError)
        XCTAssertEqual(result.historyEntry?.text, "ordered")
    }

    func testHistoryFailurePreservesRecoveryAndBlocksPaste() async throws {
        enum Expected: Error { case history }
        var events: [String] = []
        let deps = recordingDependencies(into: { events.append($0) }, appendHistory: { _, _ in throw Expected.history })
        do {
            _ = try await TranscriptCommitter(directory: root, dependencies: deps)
                .commit("resilient", settings: settings(sessionID: UUID()), targetPID: 12)
            XCTFail("enabled history failure must abort before the commit point")
        } catch {
            guard case TranscriptCommitter.CommitError.historyStorageFailed = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertEqual(events, ["clipboard", "history:resilient"])
        XCTAssertFalse(events.contains("delete-audio"))
        XCTAssertFalse(events.contains("paste"))
    }

    func testClipboardFailureNeverReachesHistory() async {
        enum Expected: Error { case clipboard }
        var events: [String] = []
        var deps = recordingDependencies(into: { events.append($0) }, appendHistory: { _, _ in })
        deps.setClipboard = { _ in throw Expected.clipboard }
        do {
            _ = try await TranscriptCommitter(directory: root, dependencies: deps)
                .commit("never", settings: settings(sessionID: UUID()), targetPID: nil)
            XCTFail("clipboard failure must abort the commit")
        } catch {}
        XCTAssertTrue(events.isEmpty)
    }

    func testHistoryDisabledOrNonFinalCommitsWriteNothing() async throws {
        var events: [String] = []
        let deps = recordingDependencies(into: { events.append($0) }, appendHistory: { _, _ in })
        let committer = TranscriptCommitter(directory: root, dependencies: deps)

        _ = try await committer.commit("off", settings: settings(sessionID: UUID(), recordHistory: false),
                                       targetPID: nil)
        var secure = settings(sessionID: UUID())
        secure.secureInputActive = true
        _ = try await committer.commit("secure", settings: secure, targetPID: nil)

        XCTAssertFalse(events.contains { $0.hasPrefix("history:") })
    }

    /// A crash between the history append and the recovery deletion leaves the recovery artifact, so
    /// the next run replays the same session. The replay must restore one row, not two.
    func testReplayAfterCrashBeforeCommitPointLeavesExactlyOneEntry() async throws {
        enum Crash: Error { case beforeCommitPoint }
        let store = try TranscriptHistoryStore(url: root.appendingPathComponent("history.sqlite3"))
        let sessionID = UUID()
        var deps = recordingDependencies(into: { _ in }, appendHistory: { entry, retention in
            try await store.append(entry, retention: retention)
        })
        deps.deleteRecovery = { throw Crash.beforeCommitPoint }

        do {
            _ = try await TranscriptCommitter(directory: root, dependencies: deps)
                .commit("interrupted", settings: settings(sessionID: sessionID), targetPID: nil)
            XCTFail("the interrupted commit must surface its cleanup failure")
        } catch {
            guard case TranscriptCommitter.CommitError.recoveryCleanupFailed = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let count = try await store.count()
        XCTAssertEqual(count, 1)

        var replayDeps = deps
        replayDeps.deleteRecovery = {}
        let replay = try await TranscriptCommitter(directory: root, dependencies: replayDeps)
            .commit("interrupted", settings: settings(sessionID: sessionID), targetPID: nil)

        XCTAssertNil(replay.historyError)
        let count2 = try await store.count()
        XCTAssertEqual(count2, 1, "a replayed commit must not duplicate its history row")
        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts, ["interrupted"])
    }

    func testCommittedRowsKeepCommitOrderAcrossSessions() async throws {
        let store = try TranscriptHistoryStore(url: root.appendingPathComponent("history.sqlite3"))
        let deps = recordingDependencies(into: { _ in }, appendHistory: { entry, retention in
            try await store.append(entry, retention: retention)
        })
        let committer = TranscriptCommitter(directory: root, dependencies: deps)
        for text in ["one", "two", "three"] {
            _ = try await committer.commit(text, settings: settings(sessionID: UUID(), autoPaste: false),
                                           targetPID: nil)
        }
        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts, ["three", "two", "one"])
    }

    func testCommitPersistsNoTargetApplicationIdentity() async throws {
        let url = root.appendingPathComponent("history.sqlite3")
        let store = try TranscriptHistoryStore(url: url)
        let deps = recordingDependencies(into: { _ in }, appendHistory: { entry, retention in
            try await store.append(entry, retention: retention)
        })
        _ = try await TranscriptCommitter(directory: root, dependencies: deps)
            .commit("private words", settings: settings(sessionID: UUID(), autoPaste: false), targetPID: 31_337)
        let entries = try await store.entries()
        await store.close()

        XCTAssertEqual(entries.map(\.text), ["private words"])
        XCTAssertEqual(entries.first?.localeIdentifier, "en-US")
        let stored = try Data(contentsOf: url)
        XCTAssertNil(stored.range(of: Data("31337".utf8)), "no target process identity may be persisted")
    }
}
