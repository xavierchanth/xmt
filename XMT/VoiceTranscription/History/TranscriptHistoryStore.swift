import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum TranscriptHistoryError: Error, Equatable {
    case open(code: Int32, message: String)
    case statement(sql: String, code: Int32, message: String)
    case unsupportedSchemaVersion(Int32)
    /// An existing file declares a `transcript_entries` this build cannot safely use — a foreign
    /// table of the same name, or one whose columns are not exactly the expected privacy surface.
    case incompatibleSchema(String)
    case closed
}

/// Owner of one SQLite handle. It is not concurrency-safe by itself; it exists so the actor below
/// can do real work in a synchronous initializer while remaining the single point of access.
final class SQLiteConnection {
    enum Value: Equatable { case text(String), integer(Int64) }

    private var handle: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unavailable"
            if let handle { sqlite3_close_v2(handle) }
            throw TranscriptHistoryError.open(code: code, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 3_000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var totalChanges: Int32 { handle.map(sqlite3_total_changes) ?? 0 }

    func execute(_ sql: String, binding values: [Value] = []) throws {
        try query(sql, binding: values) { _ in }
    }

    func scalar(_ sql: String, binding values: [Value] = []) throws -> Int64? {
        var result: Int64?
        try query(sql, binding: values) { statement in
            if result == nil { result = sqlite3_column_int64(statement, 0) }
        }
        return result
    }

    func query(_ sql: String, binding values: [Value] = [], row: (OpaquePointer) -> Void) throws {
        guard let handle else { throw TranscriptHistoryError.closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw TranscriptHistoryError.statement(
                sql: sql, code: prepared, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let bound: Int32
            switch value {
            case let .text(text): bound = sqlite3_bind_text(statement, position, text, -1, sqliteTransient)
            case let .integer(number): bound = sqlite3_bind_int64(statement, position, number)
            }
            guard bound == SQLITE_OK else {
                throw TranscriptHistoryError.statement(
                    sql: sql, code: bound, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row(statement); continue }
            if step == SQLITE_DONE || step == SQLITE_OK { return }
            throw TranscriptHistoryError.statement(
                sql: sql, code: step, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// All-or-nothing. A throwing body rolls back, so an insert whose prune failed is not a state
    /// the database can be left in.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do { try body() } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        do { try execute("COMMIT;") } catch {
            // A failed COMMIT can leave SQLite inside the transaction. Roll it back before the
            // connection is reused; otherwise every later BEGIN fails and poisons the actor.
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

/// Serialized SQLite repository for bounded transcript history.
///
/// Serialization is structural: the store is an actor owning one connection opened `FULLMUTEX`, so
/// there is one writer and no shared handle. Every mutation runs in one `IMMEDIATE` transaction that
/// both inserts and prunes, so no reader observes an over-long history and an interrupted write
/// leaves the last committed state intact.
actor TranscriptHistoryStore {
    typealias StoreError = TranscriptHistoryError

    enum AppendOutcome: Equatable, Sendable {
        /// The entry was new; `pruned` lists identifiers evicted by retention in the same transaction.
        case inserted(pruned: [UUID])
        /// The identifier already existed. Nothing was written and nothing was pruned.
        case duplicate

        var didInsert: Bool { if case .inserted = self { return true }; return false }
        var pruned: [UUID] { if case let .inserted(pruned) = self { return pruned }; return [] }
    }

    /// Bumped only together with a migration step in `migrate`.
    static let schemaVersion: Int32 = 1
    static let entriesTable = "transcript_entries"
    static let metadataTable = "schema_metadata"

    /// Expected entries columns, in order. Migration refuses any other shape rather than writing
    /// into it, so a foreign or drifted table can neither be read as history nor gain XMT's rows.
    static let entryColumns = ["id", "recorded_at_ms", "sequence", "text", "locale", "source"]
    /// Owner-only file and directory modes. Transcript text is personal data and the app is not
    /// sandboxed, so the database must not be readable by other users on the machine.
    static let filePermissions: Int16 = 0o600
    static let directoryPermissions: Int16 = 0o700

    let url: URL
    private(set) var retention: TranscriptRetentionPolicy
    private let db: SQLiteConnection

    init(url: URL, retention: TranscriptRetentionPolicy = .default) throws {
        self.url = url
        self.retention = retention
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Self.directoryPermissions)])
        let db = try SQLiteConnection(path: url.path)
        self.db = db
        do {
            try db.execute("PRAGMA journal_mode = WAL;")
            try db.execute("PRAGMA synchronous = FULL;")
            try db.execute("PRAGMA foreign_keys = ON;")
            try Self.migrate(db)
        } catch {
            db.close()
            throw error
        }
        // After migration, so the write-ahead and shared-memory side files exist to be tightened
        // too. Best effort by design: a permission that cannot be set must not deny the user their
        // history, and the directory itself already restricts traversal.
        Self.restrictPermissions(of: url)
    }

    /// Narrows the database and its side files to owner-only, and the containing directory with it.
    private static func restrictPermissions(of url: URL, fileManager: FileManager = .default) {
        let directory = url.deletingLastPathComponent()
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: directoryPermissions)], ofItemAtPath: directory.path)
        for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"]
        where fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes([.posixPermissions: NSNumber(value: filePermissions)], ofItemAtPath: path)
        }
    }

    /// Default location of the shipping store, beside the other Voice Transcription artifacts.
    static func defaultURL(directory: URL? = nil) -> URL {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.xavierchanth.xmt/VoiceTranscription", isDirectory: true)
        return base.appendingPathComponent("history.sqlite3")
    }

    func close() { db.close() }

    // MARK: - Schema

    /// Creates the strict schema and records its metadata. Safe on every open: creation is
    /// `IF NOT EXISTS`, metadata insertion is conflict-ignoring, and a file written by a newer build
    /// is rejected rather than silently reinterpreted.
    private static func migrate(_ db: SQLiteConnection) throws {
        let version = Int32(try db.scalar("PRAGMA user_version;") ?? 0)
        guard version <= schemaVersion else { throw StoreError.unsupportedSchemaVersion(version) }
        // A file may carry a newer version in metadata while `user_version` was never written —
        // a partially created database, or one restored from a newer build. Trust the stricter of
        // the two rather than creating tables over it.
        if let recorded = try metadataSchemaVersion(db), recorded > schemaVersion {
            throw StoreError.unsupportedSchemaVersion(recorded)
        }
        // An existing entries table is checked before anything is created against it, so a foreign
        // table of the same name is refused as such rather than surfacing as a confusing SQL error.
        if try tableExists(db, entriesTable) { try validate(db) }
        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS \(metadataTable) (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) STRICT;
                """)
            // Deliberately narrow: identity, time, order, text, locale. No application identity, no
            // audio path, no partial text — those columns do not exist, so they cannot be written.
            try db.execute("""
                CREATE TABLE IF NOT EXISTS \(entriesTable) (
                    id TEXT PRIMARY KEY NOT NULL,
                    recorded_at_ms INTEGER NOT NULL,
                    sequence INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    locale TEXT NOT NULL,
                    source TEXT NOT NULL CHECK(source IN ('live','recovery','legacy'))
                ) STRICT;
                """)
            try db.execute("""
                CREATE INDEX IF NOT EXISTS transcript_entries_order
                    ON \(entriesTable) (recorded_at_ms DESC, sequence DESC);
                """)
            for (key, value) in [("schema_version", String(schemaVersion)),
                                 ("application", "com.xavierchanth.xmt"),
                                 ("store", "voice-transcript-history")] {
                try db.execute("""
                    INSERT INTO \(metadataTable) (key, value) VALUES (?, ?) ON CONFLICT(key) DO NOTHING;
                    """, binding: [.text(key), .text(value)])
            }
            try db.execute("PRAGMA user_version = \(schemaVersion);")
        }
        try validate(db)
    }

    private static func tableExists(_ db: SQLiteConnection, _ name: String) throws -> Bool {
        var exists = false
        try db.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND name = ?;",
                     binding: [.text(name)]) { _ in exists = true }
        return exists
    }

    /// Reads the version metadata written alongside the schema, if the metadata table exists at all.
    private static func metadataSchemaVersion(_ db: SQLiteConnection) throws -> Int32? {
        guard try tableExists(db, metadataTable) else { return nil }
        var recorded: Int32?
        try db.query("SELECT value FROM \(metadataTable) WHERE key = 'schema_version';") { statement in
            recorded = Int32(String(cString: sqlite3_column_text(statement, 0)))
        }
        return recorded
    }

    /// Post-migration shape check. `CREATE TABLE IF NOT EXISTS` silently accepts an existing table
    /// of the same name whatever its columns, so the schema this build depends on — and the privacy
    /// boundary those columns *are* — is asserted rather than assumed.
    private static func validate(_ db: SQLiteConnection) throws {
        var columns: [String] = []
        try db.query("SELECT name FROM pragma_table_info('\(entriesTable)');") { statement in
            columns.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        guard columns == entryColumns else {
            throw StoreError.incompatibleSchema("unexpected columns: \(columns.joined(separator: ","))")
        }
        var declaration = ""
        try db.query("""
            SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = '\(entriesTable)';
            """) { statement in declaration = String(cString: sqlite3_column_text(statement, 0)) }
        guard declaration.uppercased().contains("STRICT") else {
            throw StoreError.incompatibleSchema("entries table is not STRICT")
        }
    }

    func schemaMetadata() throws -> [String: String] {
        var result: [String: String] = [:]
        try db.query("SELECT key, value FROM \(Self.metadataTable);") { statement in
            result[String(cString: sqlite3_column_text(statement, 0))] =
                String(cString: sqlite3_column_text(statement, 1))
        }
        return result
    }

    func userVersion() throws -> Int32 { Int32(try db.scalar("PRAGMA user_version;") ?? 0) }

    func columnNames() throws -> [String] {
        var names: [String] = []
        try db.query("SELECT name FROM pragma_table_info('\(Self.entriesTable)');") { statement in
            names.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return names
    }

    /// True when the entries table is declared `STRICT`, which is what makes its column types binding.
    func isStrictSchema() throws -> Bool {
        var strict = false
        try db.query("""
            SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = '\(Self.entriesTable)';
            """) { statement in
            strict = String(cString: sqlite3_column_text(statement, 0)).uppercased().contains("STRICT")
        }
        return strict
    }

    // MARK: - Writes

    /// Inserts one entry and applies retention, atomically and idempotently.
    ///
    /// Idempotence is by primary key: replaying an interrupted commit re-runs the insert, hits the
    /// conflict clause, and reports `.duplicate` without disturbing stored rows or retention.
    @discardableResult
    func append(_ entry: TranscriptHistoryEntry, retention: TranscriptRetentionPolicy? = nil,
                now: Date = Date()) throws -> AppendOutcome {
        try appendMarking(entry, marker: nil, retention: retention, now: now)
    }

    /// Inserts an entry and, optionally, a metadata marker in the **same** transaction. The marker is
    /// the legacy import's commit point: either both land or neither does, which is what makes an
    /// interrupted import safe to replay.
    @discardableResult
    func appendMarking(_ entry: TranscriptHistoryEntry, marker: (key: String, value: String)?,
                       retention: TranscriptRetentionPolicy? = nil, now: Date = Date()) throws -> AppendOutcome {
        var outcome = AppendOutcome.duplicate
        try db.transaction {
            let before = db.totalChanges
            try db.execute("""
                INSERT INTO \(Self.entriesTable) (id, recorded_at_ms, sequence, text, locale, source)
                SELECT ?, ?, COALESCE(MAX(sequence), 0) + 1, ?, ?, ? FROM \(Self.entriesTable)
                WHERE true -- required: it separates the SELECT from the upsert clause
                ON CONFLICT(id) DO NOTHING;
                """, binding: [
                    .text(entry.id.uuidString),
                    .integer(Self.milliseconds(entry.recordedAt)),
                    .text(entry.text),
                    .text(entry.localeIdentifier),
                    .text(entry.source.rawValue)])
            let inserted = db.totalChanges > before
            if let marker { try upsertMetadata(marker.key, marker.value) }
            guard inserted else { return }
            outcome = .inserted(pruned: try pruneRows(retention: retention ?? self.retention, now: now))
        }
        return outcome
    }

    /// Adopts a new retention policy and enforces it immediately, returning what that removed.
    ///
    /// Retention is otherwise applied only by an append, so without this a history tightened in
    /// settings would keep showing — and keep storing — entries the user has just excluded until
    /// the next transcript happened to arrive.
    @discardableResult
    func setRetention(_ policy: TranscriptRetentionPolicy, now: Date = Date()) throws -> [UUID] {
        retention = policy
        var removed: [UUID] = []
        try db.transaction { removed = try pruneRows(retention: policy, now: now) }
        return removed
    }

    /// Removes one entry by identity. Deleting an absent identifier is not an error, so a stale
    /// history surface cannot fail a user's delete.
    @discardableResult
    func delete(id: UUID) throws -> Bool {
        let existed = try contains(id)
        try db.transaction {
            try db.execute("DELETE FROM \(Self.entriesTable) WHERE id = ?;", binding: [.text(id.uuidString)])
        }
        return existed
    }

    /// Removes every entry in one transaction. Used only by the confirmed clear action.
    func deleteAll() throws {
        try db.transaction { try db.execute("DELETE FROM \(Self.entriesTable);") }
    }

    /// Records a metadata value on its own, for a legacy import that had nothing to carry over.
    func setMetadata(_ key: String, _ value: String) throws {
        try db.transaction { try upsertMetadata(key, value) }
    }

    func metadataValue(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM \(Self.metadataTable) WHERE key = ?;",
                     binding: [.text(key)]) { statement in
            value = String(cString: sqlite3_column_text(statement, 0))
        }
        return value
    }

    private func upsertMetadata(_ key: String, _ value: String) throws {
        try db.execute("""
            INSERT INTO \(Self.metadataTable) (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, binding: [.text(key), .text(value)])
    }

    /// Applies retention in bounded work: two single-row lookups on the ordering index and one
    /// delete. Retained rows are never read — only the newest row, the last row the count bound
    /// keeps, and the identifiers actually removed cross the SQLite boundary — so a prune costs the
    /// same whether history holds ten entries or ten thousand.
    ///
    /// The invariants are exactly those of the row-at-a-time version it replaces: rows ordered after
    /// the count cutoff go, rows recorded before the age cutoff go, and the newest row never goes.
    /// Removed identifiers are returned in delete order; callers treat them as a set.
    private func pruneRows(retention: TranscriptRetentionPolicy, now: Date) throws -> [UUID] {
        var newestID: String?
        try db.query("""
            SELECT id FROM \(Self.entriesTable) ORDER BY recorded_at_ms DESC, sequence DESC LIMIT 1;
            """) { statement in newestID = String(cString: sqlite3_column_text(statement, 0)) }
        guard let newestID else { return [] }

        var conditions: [String] = []
        var bindings: [SQLiteConnection.Value] = [.text(newestID)]
        // The last row the count bound retains. Anything ordered after it — an older instant, or the
        // same instant with a lower sequence — is beyond the bound. Absent when history is shorter
        // than the bound, in which case the count criterion prunes nothing.
        var cutoff: (milliseconds: Int64, sequence: Int64)?
        try db.query("""
            SELECT recorded_at_ms, sequence FROM \(Self.entriesTable)
            ORDER BY recorded_at_ms DESC, sequence DESC LIMIT 1 OFFSET ?;
            """, binding: [.integer(Int64(retention.maximumEntries - 1))]) { statement in
            cutoff = (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
        }
        if let cutoff {
            conditions.append("(recorded_at_ms, sequence) < (?, ?)")
            bindings.append(.integer(cutoff.milliseconds))
            bindings.append(.integer(cutoff.sequence))
        }
        if let earliest = retention.earliestRetained(now: now) {
            conditions.append("recorded_at_ms < ?")
            bindings.append(.integer(Self.milliseconds(earliest)))
        }
        guard !conditions.isEmpty else { return [] }

        var removed: [UUID] = []
        try db.query("""
            DELETE FROM \(Self.entriesTable)
            WHERE id <> ? AND (\(conditions.joined(separator: " OR ")))
            RETURNING id;
            """, binding: bindings) { statement in
            if let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) { removed.append(id) }
        }
        return removed
    }

    // MARK: - Reads

    /// Newest first. Ties on timestamp fall back to insertion sequence, so commit order is total.
    func entries(limit: Int? = nil) throws -> [TranscriptHistoryEntry] {
        var entries: [TranscriptHistoryEntry] = []
        let clause = limit.map { " LIMIT \(max($0, 0))" } ?? ""
        try db.query("""
            SELECT id, recorded_at_ms, text, locale, source FROM \(Self.entriesTable)
            ORDER BY recorded_at_ms DESC, sequence DESC\(clause);
            """) { statement in
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) else { return }
            entries.append(TranscriptHistoryEntry(
                id: id,
                recordedAt: Self.date(sqlite3_column_int64(statement, 1)),
                text: String(cString: sqlite3_column_text(statement, 2)),
                localeIdentifier: String(cString: sqlite3_column_text(statement, 3)),
                source: TranscriptSource(rawValue: String(cString: sqlite3_column_text(statement, 4))) ?? .live))
        }
        return entries
    }

    func count() throws -> Int { Int(try db.scalar("SELECT COUNT(*) FROM \(Self.entriesTable);") ?? 0) }

    func contains(_ id: UUID) throws -> Bool {
        (try db.scalar("SELECT COUNT(*) FROM \(Self.entriesTable) WHERE id = ?;",
                       binding: [.text(id.uuidString)]) ?? 0) > 0
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}
