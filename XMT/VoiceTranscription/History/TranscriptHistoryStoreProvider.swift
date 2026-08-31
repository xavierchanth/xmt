import Foundation

/// Process-wide accessor for the one durable history store.
///
/// There is exactly one SQLite file and one connection to it, so every writer and reader in the app
/// must share this instance rather than opening its own. Opening is lazy: nothing touches disk until
/// a commit records history or a surface reads it, which keeps launch free of history work.
enum SharedTranscriptHistoryStore {
    private static let lock = NSLock()
    private static var cached: TranscriptHistoryStore?
    private static var openFailure: Error?

    /// Opens the store on first use. A previous failure is remembered and rethrown rather than
    /// retried on every commit, so a broken file cannot turn into repeated disk work.
    static func shared(retention: TranscriptRetentionPolicy = .default) throws -> TranscriptHistoryStore {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if let openFailure { throw openFailure }
        do {
            let store = try TranscriptHistoryStore(url: TranscriptHistoryStore.defaultURL(), retention: retention)
            cached = store
            return store
        } catch {
            openFailure = error
            throw error
        }
    }

    /// Test seam: replaces the shared instance and clears any remembered failure.
    static func override(_ store: TranscriptHistoryStore?) {
        lock.lock()
        defer { lock.unlock() }
        cached = store
        openFailure = nil
    }
}
