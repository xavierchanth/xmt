import XCTest

@MainActor final class CommitSequenceTests: XCTestCase {
    func testCommitPointPrecedesPasteAndAtomicReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent("last-transcript.txt"); try Data("old".utf8).write(to: final)
        var events: [String] = []
        let fm = FileManager.default
        let deps = TranscriptCommitter.Dependencies(
            setClipboard: { _ in events.append("clipboard") }, write: { try $0.write(to: $1); events.append("temp") },
            move: { try fm.moveItem(at: $0, to: $1) }, replace: { source, destination in _ = try fm.replaceItemAt(destination, withItemAt: source); events.append("replace") },
            remove: { if fm.fileExists(atPath: $0.path) { try fm.removeItem(at: $0) } }, exists: { fm.fileExists(atPath: $0.path) },
            paste: { _, _ in events.append("paste") }, deleteRecovery: { events.append("delete-audio") })
        let result = try await TranscriptCommitter(directory: root, dependencies: deps).commit("new", settings: .init(keepLastTranscript: true, autoPaste: true), targetPID: 1)
        XCTAssertNil(result.pasteError); XCTAssertEqual(String(data: try Data(contentsOf: final), encoding: .utf8), "new")
        XCTAssertEqual(events, ["clipboard", "temp", "replace", "delete-audio", "paste"])
    }

    func testRetentionOffRemovesStaleAndPasteFailureDoesNotUndoCommit() async throws {
        enum Expected: Error { case paste }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent("last-transcript.txt"); try Data("stale".utf8).write(to: final)
        var deleted = false; let fm = FileManager.default
        let deps = TranscriptCommitter.Dependencies(setClipboard: { _ in }, write: { _, _ in }, move: { _, _ in }, replace: { _, _ in },
            remove: { try fm.removeItem(at: $0) }, exists: { fm.fileExists(atPath: $0.path) }, paste: { _, _ in throw Expected.paste }, deleteRecovery: { deleted = true })
        let result = try await TranscriptCommitter(directory: root, dependencies: deps).commit("safe", settings: .init(keepLastTranscript: false, autoPaste: true), targetPID: 1)
        XCTAssertNotNil(result.pasteError); XCTAssertTrue(deleted); XCTAssertFalse(fm.fileExists(atPath: final.path))
    }

    func testCommitCleanupReconcilesRecoveryClean() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingRecordingStore(root: root); let metadata = PendingRecordingMetadata(sessionID: UUID(), timestamp: Date(), localeIdentifier: "en-US", failureReason: "x")
        let audio = try store.prepareActive(metadata); try Data("uncommitted".utf8).write(to: audio)
        var deps = TranscriptCommitter.Dependencies.live
        deps.deleteRecovery = { _ = try Reconciliation.run(store: store, transcriptWasCommitted: true) }
        _ = try await TranscriptCommitter(directory: root, dependencies: deps).commit("safe", settings: .init(keepLastTranscript: false, autoPaste: false), targetPID: nil)
        XCTAssertEqual(try Reconciliation.run(store: store), .clean)
    }

    func testRecoveryFailureOccursAfterTranscriptCommitAndBeforePaste() async {
        enum Expected: Error { case cleanup }; var events: [String] = []
        var deps = TranscriptCommitter.Dependencies.live
        deps.setClipboard = { _ in events.append("clipboard") }; deps.deleteRecovery = { events.append("cleanup"); throw Expected.cleanup }
        deps.paste = { _, _ in events.append("paste") }
        do { _ = try await TranscriptCommitter(directory: FileManager.default.temporaryDirectory, dependencies: deps).commit("safe", settings: .init(keepLastTranscript: false, autoPaste: true), targetPID: 1); XCTFail() }
        catch { guard case TranscriptCommitter.CommitError.recoveryCleanupFailed = error else { return XCTFail("wrong error") } }
        XCTAssertEqual(events, ["clipboard", "cleanup"])
    }

    func testClipboardFailureDoesNotReachRecoveryDeletion() async {
        enum Expected: Error { case clipboard }; var deleted = false
        var deps = TranscriptCommitter.Dependencies.live; deps.setClipboard = { _ in throw Expected.clipboard }; deps.deleteRecovery = { deleted = true }
        do { _ = try await TranscriptCommitter(directory: FileManager.default.temporaryDirectory, dependencies: deps).commit("x", settings: .init(keepLastTranscript: false, autoPaste: false), targetPID: nil); XCTFail() } catch {}
        XCTAssertFalse(deleted)
    }
}
