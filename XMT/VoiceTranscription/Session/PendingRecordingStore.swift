import Foundation

struct PendingRecordingMetadata: Codable, Equatable {
    static let currentVersion = 1
    let version: Int
    let sessionID: UUID
    let timestamp: Date
    let localeIdentifier: String
    let failureReason: String

    init(sessionID: UUID, timestamp: Date, localeIdentifier: String, failureReason: String) {
        version = Self.currentVersion; self.sessionID = sessionID; self.timestamp = timestamp
        self.localeIdentifier = localeIdentifier; self.failureReason = failureReason
    }
}

/// Durable one-slot recovery storage. JSON contains metadata only; audio remains CAF.
struct PendingRecordingStore {
    enum StoreError: Error { case pendingAlreadyExists, incompletePending, invalidMetadata }
    struct Pending: Equatable { let metadata: PendingRecordingMetadata; let audioURL: URL }

    let root: URL
    let fileManager: FileManager
    var activeAudioURL: URL { root.appendingPathComponent("active.caf") }
    var activeMetadataURL: URL { root.appendingPathComponent("active.json") }
    var pendingAudioURL: URL { root.appendingPathComponent("pending.caf") }
    var pendingMetadataURL: URL { root.appendingPathComponent("pending.json") }

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.root = root ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.xavierchanth.xmt/VoiceTranscription", isDirectory: true)
        self.fileManager = fileManager
    }

    func prepareActive(_ metadata: PendingRecordingMetadata) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard try loadPending() == nil else { throw StoreError.pendingAlreadyExists }
        try removeIfPresent(activeAudioURL); try removeIfPresent(activeMetadataURL)
        try atomicWrite(try JSONEncoder.xmt.encode(metadata), to: activeMetadataURL)
        return activeAudioURL
    }

    func promoteActive(failureReason: String) throws -> Pending {
        guard !fileManager.fileExists(atPath: pendingAudioURL.path), !fileManager.fileExists(atPath: pendingMetadataURL.path) else {
            throw StoreError.pendingAlreadyExists
        }
        guard fileManager.fileExists(atPath: activeAudioURL.path), let active = try metadata(at: activeMetadataURL) else {
            throw StoreError.incompletePending
        }
        let pending = PendingRecordingMetadata(sessionID: active.sessionID, timestamp: active.timestamp,
                                               localeIdentifier: active.localeIdentifier, failureReason: failureReason)
        try atomicWrite(try JSONEncoder.xmt.encode(pending), to: pendingMetadataURL)
        do { try fileManager.moveItem(at: activeAudioURL, to: pendingAudioURL) }
        catch { try? fileManager.removeItem(at: pendingMetadataURL); throw error }
        try removeIfPresent(activeMetadataURL)
        return Pending(metadata: pending, audioURL: pendingAudioURL)
    }

    func loadPending() throws -> Pending? {
        let audio = fileManager.fileExists(atPath: pendingAudioURL.path), json = fileManager.fileExists(atPath: pendingMetadataURL.path)
        guard audio || json else { return nil }
        guard audio, json, let metadata = try metadata(at: pendingMetadataURL) else { throw StoreError.incompletePending }
        return Pending(metadata: metadata, audioURL: pendingAudioURL)
    }

    func deletePending() throws { try removeIfPresent(pendingAudioURL); try removeIfPresent(pendingMetadataURL) }
    func writeMetadata(_ metadata: PendingRecordingMetadata, to url: URL) throws {
        try atomicWrite(try JSONEncoder.xmt.encode(metadata), to: url)
    }
    func clearActive() throws { try removeIfPresent(activeAudioURL); try removeIfPresent(activeMetadataURL) }

    func metadata(at url: URL) throws -> PendingRecordingMetadata? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder.xmt.decode(PendingRecordingMetadata.self, from: Data(contentsOf: url))
        guard value.version == PendingRecordingMetadata.currentVersion else { throw StoreError.invalidMetadata }
        return value
    }
    func removeIfPresent(_ url: URL) throws { if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) } }
    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = root.appendingPathComponent(".recovery-metadata-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

private extension JSONEncoder { static var xmt: JSONEncoder { let x = JSONEncoder(); x.dateEncodingStrategy = .iso8601; return x } }
private extension JSONDecoder { static var xmt: JSONDecoder { let x = JSONDecoder(); x.dateDecodingStrategy = .iso8601; return x } }
