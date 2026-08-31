import XCTest

/// Repository, retention, legacy-import, and privacy invariants for the durable transcript history.
final class TranscriptHistoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var databaseURL: URL { root.appendingPathComponent("history.sqlite3") }

    func testCommitFailureRollsBackAndConnectionRemainsUsable() throws {
        let connection = try SQLiteConnection(path: root.appendingPathComponent("commit-failure.sqlite3").path)
        try connection.execute("PRAGMA foreign_keys = ON;")
        try connection.execute("CREATE TABLE parent(id INTEGER PRIMARY KEY);")
        try connection.execute("CREATE TABLE child(parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED);")
        XCTAssertThrowsError(try connection.transaction {
            try connection.execute("INSERT INTO child(parent_id) VALUES (99);")
        })
        XCTAssertEqual(try connection.scalar("SELECT COUNT(*) FROM child;"), 0)
        try connection.transaction { try connection.execute("INSERT INTO parent(id) VALUES (1);") }
        XCTAssertEqual(try connection.scalar("SELECT COUNT(*) FROM parent;"), 1)
    }

    private func makeStore(_ retention: TranscriptRetentionPolicy = .default) throws -> TranscriptHistoryStore {
        try TranscriptHistoryStore(url: databaseURL, retention: retention)
    }

    private func entry(_ text: String, at seconds: TimeInterval, id: UUID = UUID()) -> TranscriptHistoryEntry {
        TranscriptHistoryEntry(id: id, recordedAt: Date(timeIntervalSince1970: seconds),
                               text: text, localeIdentifier: "en-US")
    }

    // MARK: - Schema

    func testSchemaIsStrictVersionedAndDescribedByMetadata() async throws {
        let store = try makeStore()
        let metadata = try await store.schemaMetadata()
        XCTAssertEqual(metadata["schema_version"], String(TranscriptHistoryStore.schemaVersion))
        XCTAssertEqual(metadata["application"], "com.xavierchanth.xmt")
        XCTAssertEqual(metadata["store"], "voice-transcript-history")
        let version = try await store.userVersion()
        XCTAssertEqual(version, TranscriptHistoryStore.schemaVersion)
        let isStrict = try await store.isStrictSchema()
        XCTAssertTrue(isStrict)
    }

    func testReopeningMigratesIdempotentlyAndKeepsEntries() async throws {
        let first = try makeStore()
        try await first.append(entry("kept across launches", at: 100))
        await first.close()

        let second = try makeStore()
        let count = try await second.count()
        XCTAssertEqual(count, 1)
        let metadata = try await second.schemaMetadata()
        XCTAssertEqual(metadata["schema_version"], String(TranscriptHistoryStore.schemaVersion))
        let version = try await second.userVersion()
        XCTAssertEqual(version, TranscriptHistoryStore.schemaVersion)
        let newestText = try await second.entries().first?.text
        XCTAssertEqual(newestText, "kept across launches")
    }

    func testStoreFromNewerBuildIsRejectedRatherThanReinterpreted() async throws {
        let store = try makeStore()
        await store.close()
        let raw = try SQLiteConnection(path: databaseURL.path)
        try raw.execute("PRAGMA user_version = \(TranscriptHistoryStore.schemaVersion + 1);")
        raw.close()
        XCTAssertThrowsError(try makeStore()) { error in
            XCTAssertEqual(error as? TranscriptHistoryError,
                           .unsupportedSchemaVersion(TranscriptHistoryStore.schemaVersion + 1))
        }
    }

    func testStoreRecordingANewerVersionInMetadataIsRejected() async throws {
        let store = try makeStore()
        await store.close()
        let raw = try SQLiteConnection(path: databaseURL.path)
        // `user_version` is left at this build's value: metadata alone must be enough to refuse.
        try raw.execute("""
            INSERT INTO \(TranscriptHistoryStore.metadataTable) (key, value) VALUES ('schema_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, binding: [.text(String(TranscriptHistoryStore.schemaVersion + 1))])
        raw.close()
        XCTAssertThrowsError(try makeStore()) { error in
            XCTAssertEqual(error as? TranscriptHistoryError,
                           .unsupportedSchemaVersion(TranscriptHistoryStore.schemaVersion + 1))
        }
    }

    func testForeignEntriesTableIsRejectedRatherThanWrittenInto() throws {
        let raw = try SQLiteConnection(path: databaseURL.path)
        // Same name, wrong shape — and carrying a column history is not allowed to store.
        try raw.execute("""
            CREATE TABLE \(TranscriptHistoryStore.entriesTable) (
                id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, target_bundle_id TEXT
            ) STRICT;
            """)
        try raw.execute("INSERT INTO \(TranscriptHistoryStore.entriesTable) (id, text) VALUES ('x', 'y');")
        raw.close()
        XCTAssertThrowsError(try makeStore()) { error in
            guard case .incompatibleSchema = error as? TranscriptHistoryError else {
                return XCTFail("expected an incompatible-schema refusal, got \(error)")
            }
        }
    }

    func testNonStrictEntriesTableIsRejected() throws {
        let raw = try SQLiteConnection(path: databaseURL.path)
        try raw.execute("""
            CREATE TABLE \(TranscriptHistoryStore.entriesTable) (
                id TEXT PRIMARY KEY NOT NULL, recorded_at_ms INTEGER NOT NULL, sequence INTEGER NOT NULL,
                text TEXT NOT NULL, locale TEXT NOT NULL, source TEXT NOT NULL
            );
            """)
        raw.close()
        XCTAssertThrowsError(try makeStore()) { error in
            guard case .incompatibleSchema = error as? TranscriptHistoryError else {
                return XCTFail("expected an incompatible-schema refusal, got \(error)")
            }
        }
    }

    // MARK: - Permissions

    func testDatabaseAndSideFilesAreOwnerOnly() async throws {
        let store = try makeStore()
        try await store.append(entry("private", at: 1))
        let manager = FileManager.default

        let directoryMode = try XCTUnwrap(
            manager.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.int16Value, TranscriptHistoryStore.directoryPermissions)

        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        where manager.fileExists(atPath: path) {
            let mode = try XCTUnwrap(manager.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.int16Value, TranscriptHistoryStore.filePermissions, "world-readable: \(path)")
        }
    }

    func testOpeningAnExistingWorldReadableDatabaseTightensIt() async throws {
        let first = try makeStore()
        await first.close()
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))],
                                              ofItemAtPath: databaseURL.path)
        let second = try makeStore()
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value, TranscriptHistoryStore.filePermissions)
        await second.close()
    }

    // MARK: - Insert and prune

    func testAppendIsIdempotentByIdentity() async throws {
        let store = try makeStore()
        let id = UUID()
        let first = try await store.append(entry("only once", at: 10, id: id))
        let second = try await store.append(entry("only once", at: 10, id: id))
        let rewritten = try await store.append(entry("different text, same session", at: 99, id: id))

        XCTAssertTrue(first.didInsert)
        XCTAssertEqual(second, .duplicate)
        XCTAssertEqual(rewritten, .duplicate)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts, ["only once"])
    }

    func testAppendPrunesToTheEntryBoundInTheSameTransaction() async throws {
        let store = try makeStore(TranscriptRetentionPolicy(maximumEntries: 3))
        for index in 1...6 {
            let outcome = try await store.append(entry("t\(index)", at: Double(index)))
            let count = try await store.count()
            XCTAssertLessThanOrEqual(count, 3, "history is never observed over its bound")
            if index > 3 { XCTAssertEqual(outcome.pruned.count, 1) }
        }
        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts, ["t6", "t5", "t4"])
    }

    func testAgeBoundPrunesButNeverTheEntryJustWritten() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let store = try makeStore(TranscriptRetentionPolicy(maximumEntries: 100, maximumAge: 60))
        try await store.append(entry("stale", at: 1_000), now: now)
        let outcome = try await store.append(entry("fresh", at: 9_990), now: now)
        XCTAssertEqual(outcome.pruned.count, 1)
        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts, ["fresh"])

        // A back-dated entry beyond the age bound is evicted by the same transaction that wrote it,
        // so history never briefly shows a row retention would not keep.
        let ancient = entry("ancient", at: 0)
        let outcomeForAncient = try await store.append(ancient, now: now)
        XCTAssertEqual(outcomeForAncient.pruned, [ancient.id])
        let contains = try await store.contains(ancient.id)
        XCTAssertFalse(contains)
        let texts2 = try await store.entries().map(\.text)
        XCTAssertEqual(texts2, ["fresh"])
    }

    func testDeleteAndDeleteAllRemoveOnlyWhatWasAsked() async throws {
        let store = try makeStore()
        let doomed = entry("remove me", at: 5)
        try await store.append(doomed)
        try await store.append(entry("keep me", at: 6))

        let deleted = try await store.delete(id: doomed.id)
        XCTAssertTrue(deleted)
        let deleted2 = try await store.delete(id: doomed.id)
        XCTAssertFalse(deleted2, "deleting an absent entry is not an error")
        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts, ["keep me"])

        try await store.deleteAll()
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func testTighteningRetentionPrunesImmediatelyAndBindsLaterAppends() async throws {
        let store = try makeStore(TranscriptRetentionPolicy(maximumEntries: 10))
        for index in 1...5 { try await store.append(entry("t\(index)", at: Double(index))) }

        let removed = try await store.setRetention(TranscriptRetentionPolicy(maximumEntries: 2))
        XCTAssertEqual(removed.count, 3, "entries beyond the new bound go at once, not at next commit")
        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts, ["t5", "t4"])

        // The adopted policy is the one later appends enforce, with no per-call retention argument.
        try await store.append(entry("t6", at: 6))
        let after = try await store.entries().map(\.text)
        XCTAssertEqual(after, ["t6", "t5"])
    }

    func testLooseningRetentionPrunesNothing() async throws {
        let store = try makeStore(TranscriptRetentionPolicy(maximumEntries: 2))
        for index in 1...3 { try await store.append(entry("t\(index)", at: Double(index))) }
        let removed = try await store.setRetention(TranscriptRetentionPolicy(maximumEntries: 50))
        XCTAssertTrue(removed.isEmpty)
        let count = try await store.count()
        XCTAssertEqual(count, 2, "a wider bound cannot resurrect what earlier retention removed")
    }

    // MARK: - Ordering

    func testOrderingIsNewestFirstAndTotalWhenTimestampsCollide() async throws {
        let store = try makeStore()
        for index in 1...4 { try await store.append(entry("same-instant-\(index)", at: 500)) }
        try await store.append(entry("later", at: 900))

        let texts = try await store.entries().map(\.text)
        XCTAssertEqual(texts,
                       ["later", "same-instant-4", "same-instant-3", "same-instant-2", "same-instant-1"])
        let topTwo = try await store.entries(limit: 2).map(\.text)
        XCTAssertEqual(topTwo, ["later", "same-instant-4"])
    }

    func testOrderingSurvivesReopenAndPruning() async throws {
        let first = try makeStore(TranscriptRetentionPolicy(maximumEntries: 2))
        for index in 1...3 { try await first.append(entry("t\(index)", at: 42)) }
        await first.close()

        let second = try makeStore(TranscriptRetentionPolicy(maximumEntries: 2))
        let texts = try await second.entries().map(\.text)
        XCTAssertEqual(texts, ["t3", "t2"])
    }

    // MARK: - Privacy

    func testOnlyPermittedColumnsExistAndNoExcludedValueReachesTheFile() async throws {
        let store = try makeStore()
        let columns = try await store.columnNames()
        XCTAssertEqual(columns, ["id", "recorded_at_ms", "sequence", "text", "locale", "source"])

        let context = TranscriptCommitContext(
            sessionID: UUID(), recordedAt: Date(timeIntervalSince1970: 7), text: "  spoken words  ",
            localeIdentifier: "en-US",
            targetApplicationBundleID: "com.apple.TextEdit", targetApplicationPID: 4321,
            audioURL: root.appendingPathComponent("secret-recording.caf"),
            partialTranscript: "spoken wor")
        let entry = try XCTUnwrap(TranscriptHistoryPolicy.decide(context).entry)
        XCTAssertEqual(entry.text, "spoken words")
        try await store.append(entry)
        await store.close()

        let stored = try Data(contentsOf: databaseURL)
        for excluded in ["com.apple.TextEdit", "secret-recording.caf", "spoken wor "] {
            XCTAssertNil(stored.range(of: Data(excluded.utf8)), "\(excluded) must never be persisted")
        }
        XCTAssertNotNil(stored.range(of: Data("spoken words".utf8)))
    }

    func testPolicyRefusesEverythingItMayNotPersist() {
        var context = TranscriptCommitContext(sessionID: UUID(), recordedAt: Date(), text: "hello",
                                              localeIdentifier: "en-US")
        XCTAssertNotNil(TranscriptHistoryPolicy.decide(context).entry)

        context.historyEnabled = false
        XCTAssertEqual(TranscriptHistoryPolicy.decide(context).exclusion, .historyDisabled)
        context.historyEnabled = true

        context.secureInputActive = true
        XCTAssertEqual(TranscriptHistoryPolicy.decide(context).exclusion, .secureInput)
        context.secureInputActive = false

        context.isFinal = false
        XCTAssertEqual(TranscriptHistoryPolicy.decide(context).exclusion, .notFinal)
        context.isFinal = true

        context.text = "   \n "
        XCTAssertEqual(TranscriptHistoryPolicy.decide(context).exclusion, .emptyTranscript)
    }

    func testRetentionPolicyClampsAndPruneMathIsPure() {
        XCTAssertEqual(TranscriptRetentionPolicy(maximumEntries: 0).maximumEntries, 1)
        XCTAssertEqual(TranscriptRetentionPolicy(maximumEntries: 99_999).maximumEntries, 10_000)
        XCTAssertEqual(TranscriptRetentionPolicy(maximumEntries: 5, maximumAge: -9).maximumAge, 0)

        let now = Date(timeIntervalSince1970: 1_000)
        let rows = (0..<5).map { (id: UUID(), recordedAt: now.addingTimeInterval(Double(-$0) * 100)) }
        let byCount = TranscriptHistoryPolicy.identifiersToPrune(
            newestFirst: rows, policy: TranscriptRetentionPolicy(maximumEntries: 2), now: now)
        XCTAssertEqual(byCount, rows.dropFirst(2).map(\.id))

        let byAge = TranscriptHistoryPolicy.identifiersToPrune(
            newestFirst: rows, policy: TranscriptRetentionPolicy(maximumEntries: 100, maximumAge: 150), now: now)
        XCTAssertEqual(byAge, rows.dropFirst(2).map(\.id))

        let everythingExpired = TranscriptHistoryPolicy.identifiersToPrune(
            newestFirst: rows, policy: TranscriptRetentionPolicy(maximumEntries: 100, maximumAge: 0), now: now)
        XCTAssertFalse(everythingExpired.contains(rows[0].id), "the newest entry is never pruned")
        XCTAssertEqual(everythingExpired.count, rows.count - 1)
    }

    // MARK: - Legacy import

    private func writeLegacy(_ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(LegacyTranscriptImport.fileName))
    }

    func testLegacyImportCarriesTheOneSlotCacheOnce() async throws {
        let store = try makeStore()
        try writeLegacy("survives the upgrade")

        let first = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        XCTAssertEqual(first.entry?.text, "survives the upgrade")
        let count = try await store.count()
        XCTAssertEqual(count, 1)

        let second = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        XCTAssertEqual(second, .nothingToImport)
        let count2 = try await store.count()
        XCTAssertEqual(count2, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(LegacyTranscriptImport.fileName).path),
            "the legacy cache is deleted only after the transaction commits")
    }

    func testLegacyImportIsIdempotentWhenTheMarkerIsLost() async throws {
        let store = try makeStore()
        try writeLegacy("interrupted upgrade")
        _ = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")

        // Simulate a crash that lost the marker but kept the row: the content-addressed identity
        // still makes the replay a duplicate rather than a second copy.
        try await store.setMetadata(LegacyTranscriptImport.markerKey, "")
        try writeLegacy("interrupted upgrade")
        let replay = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        XCTAssertEqual(replay, .alreadyImported)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func testLegacyImportReplayAfterLosingBothRowAndMarkerRestoresOneEntry() async throws {
        let store = try makeStore()
        try writeLegacy("crashed before commit")
        let candidate = try XCTUnwrap(
            LegacyTranscriptImport.candidate(directory: root, localeIdentifier: "en-US"))
        // Nothing committed yet: the pre-crash state is an empty store with no marker.
        let count = try await store.count()
        XCTAssertEqual(count, 0)
        let marker = try await store.metadataValue(LegacyTranscriptImport.markerKey)
        XCTAssertNil(marker)

        let outcome = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        XCTAssertEqual(outcome.entry?.id, candidate.entry.id)
        let marker2 = try await store.metadataValue(LegacyTranscriptImport.markerKey)
        XCTAssertEqual(marker2, candidate.fingerprint)
        let count2 = try await store.count()
        XCTAssertEqual(count2, 1)
    }

    func testLegacyImportRecordsAMarkerWhenThereIsNothingToCarry() async throws {
        let store = try makeStore()
        let outcome = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        XCTAssertEqual(outcome, .nothingToImport)
        let marker = try await store.metadataValue(LegacyTranscriptImport.markerKey)
        XCTAssertEqual(marker, "absent")
        let count = try await store.count()
        XCTAssertEqual(count, 0)

        try writeLegacy("   \n\t ")
        let empty = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        XCTAssertEqual(empty, .nothingToImport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LegacyTranscriptImport.fileName).path))
    }

    func testManagedDisableLaunchOrdersConfigurationBeforeStorageAndCleansOnlyPlaintext() async throws {
        try writeLegacy("private stale text")
        let recovery = root.appendingPathComponent("pending-recording.caf")
        try Data("audio".utf8).write(to: recovery)
        let database = root.appendingPathComponent("history.sqlite3")
        var opened = false

        let newest = try await LegacyTranscriptImport.reconcileAfterConfiguration(
            enabled: false, directory: root, localeIdentifier: "en-US",
            openStore: {
                opened = true
                return try TranscriptHistoryStore(url: database)
            })

        XCTAssertNil(newest)
        XCTAssertFalse(opened, "managed disable must branch before resolving the store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LegacyTranscriptImport.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testDisabledHistoryDeletesOnlyLegacyPlaintextWithoutCreatingDatabase() throws {
        try writeLegacy("private stale text")
        let recovery = root.appendingPathComponent("pending-recording.caf")
        try Data("audio".utf8).write(to: recovery)
        let unopenedDatabase = root.appendingPathComponent("disabled-history.sqlite3")

        try LegacyTranscriptImport.removeWhenHistoryDisabled(directory: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LegacyTranscriptImport.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unopenedDatabase.path))
    }

    func testLegacyImportOfRewrittenCacheAddsExactlyOneMoreEntry() async throws {
        let store = try makeStore()
        try writeLegacy("first")
        _ = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        try writeLegacy("second")
        let outcome = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")

        XCTAssertEqual(outcome.entry?.text, "second")
        let count = try await store.count()
        XCTAssertEqual(count, 2)
        let replay = try await LegacyTranscriptImport.run(store: store, directory: root, localeIdentifier: "en-US")
        XCTAssertEqual(replay, .nothingToImport)
        let count2 = try await store.count()
        XCTAssertEqual(count2, 2)
    }

    func testLegacyIdentityIsContentAddressedAndWellFormed() {
        let identifier = LegacyTranscriptImport.identifier(
            fingerprint: LegacyTranscriptImport.fingerprint(of: "stable"))
        XCTAssertEqual(identifier, LegacyTranscriptImport.identifier(
            fingerprint: LegacyTranscriptImport.fingerprint(of: "stable")))
        XCTAssertNotEqual(identifier, LegacyTranscriptImport.identifier(
            fingerprint: LegacyTranscriptImport.fingerprint(of: "other")))
        XCTAssertEqual(identifier.uuidString.split(separator: "-")[2].first, "5", "RFC 4122 version nibble")
    }
}
