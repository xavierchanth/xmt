import AVFoundation
import XCTest

final class ReconciliationTests: XCTestCase {
    private func fixture() throws -> (URL, PendingRecordingStore, PendingRecordingMetadata) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PendingRecordingStore(root: root)
        let metadata = PendingRecordingMetadata(sessionID: UUID(), timestamp: Date(timeIntervalSince1970: 1), localeIdentifier: "en-US", failureReason: "capture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, store, metadata)
    }

    private func writeValidCAF(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        try file.write(from: buffer)
    }

    func testActivePairBecomesPending() throws {
        let (_, store, metadata) = try fixture(); let audio = try store.prepareActive(metadata); try writeValidCAF(to: audio)
        guard case .pending(let pending) = try Reconciliation.run(store: store) else { return XCTFail() }
        XCTAssertEqual(pending.metadata.sessionID, metadata.sessionID); XCTAssertTrue(FileManager.default.fileExists(atPath: pending.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.activeAudioURL.path))
    }

    func testCommittedDeletesEveryArtifact() throws {
        let (_, store, metadata) = try fixture(); let audio = try store.prepareActive(metadata); try writeValidCAF(to: audio)
        XCTAssertEqual(try Reconciliation.run(store: store, transcriptWasCommitted: true), .clean)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [])
    }

    func testSidecarWithoutAudioConvergesClean() throws {
        let (_, store, metadata) = try fixture(); try store.writeMetadata(metadata, to: store.pendingMetadataURL)
        XCTAssertEqual(try Reconciliation.run(store: store), .clean)
        XCTAssertEqual(try Reconciliation.run(store: store), .clean)
    }

    func testCompletePendingWinsAndIsNeverOverwritten() throws {
        let (_, store, metadata) = try fixture(); let active = try store.prepareActive(metadata); try writeValidCAF(to: active)
        _ = try store.promoteActive(failureReason: "first")
        XCTAssertThrowsError(try store.prepareActive(metadata))
        guard case .pending(let value) = try Reconciliation.run(store: store) else { return XCTFail() }
        XCTAssertEqual(value.metadata.failureReason, "first")
    }

    func testAudioOnlyAndCorruptMetadataAreRepairedIdempotently() throws {
        for sidecar in [Data(), Data(#"{"version":999}"#.utf8)] {
            let (_, store, metadata) = try fixture()
            try writeValidCAF(to: store.pendingAudioURL)
            if !sidecar.isEmpty { try sidecar.write(to: store.pendingMetadataURL) }
            guard case .pending(let first) = try Reconciliation.run(store: store) else { return XCTFail() }
            XCTAssertEqual(first.metadata.localeIdentifier, "und")
            XCTAssertEqual(first.metadata.failureReason, "metadataCorrupt")
            guard case .pending(let second) = try Reconciliation.run(store: store) else { return XCTFail() }
            XCTAssertEqual(first, second)
            try store.deletePending()
            XCTAssertNoThrow(try store.prepareActive(metadata))
        }
    }

    func testSweepsOnlyStoreAtomicTemps() throws {
        let (root, store, _) = try fixture()
        let own = root.appendingPathComponent(".recovery-metadata-orphan.tmp")
        let transcript = root.appendingPathComponent(".last-transcript-orphan.tmp")
        try Data().write(to: own); try Data().write(to: transcript)
        XCTAssertEqual(try Reconciliation.run(store: store), .clean)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
    }

    func testUnusablePendingAudioCannotDonateSidecarToActiveAudio() throws {
        let (_, store, activeMetadata) = try fixture()
        let active = try store.prepareActive(activeMetadata); try writeValidCAF(to: active)
        let stale = PendingRecordingMetadata(sessionID: UUID(), timestamp: Date(), localeIdentifier: "fr-FR", failureReason: "stale")
        try Data("not audio".utf8).write(to: store.pendingAudioURL)
        try store.writeMetadata(stale, to: store.pendingMetadataURL)
        guard case .pending(let recovered) = try Reconciliation.run(store: store) else { return XCTFail() }
        XCTAssertEqual(recovered.metadata.sessionID, activeMetadata.sessionID)
        XCTAssertEqual(recovered.metadata.localeIdentifier, activeMetadata.localeIdentifier)
    }

    func testZeroFrameAndUnreadableAudioCannotWedgePending() throws {
        for corrupt in [false, true] {
            let (_, store, metadata) = try fixture()
            if corrupt { try Data("not audio".utf8).write(to: store.pendingAudioURL) }
            else {
                let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                _ = try AVAudioFile(forWriting: store.pendingAudioURL, settings: format.settings)
            }
            try store.writeMetadata(metadata, to: store.pendingMetadataURL)
            XCTAssertEqual(try Reconciliation.run(store: store), .clean)
            XCTAssertNoThrow(try store.prepareActive(metadata))
        }
    }

    func testCrashBetweenPendingJSONAndAudioRenameCompletesMove() throws {
        let (_, store, metadata) = try fixture(); let active = try store.prepareActive(metadata); try writeValidCAF(to: active)
        try FileManager.default.copyItem(at: store.activeMetadataURL, to: store.pendingMetadataURL)
        guard case .pending = try Reconciliation.run(store: store) else { return XCTFail() }
        XCTAssertNotNil(try store.loadPending())
    }
}
