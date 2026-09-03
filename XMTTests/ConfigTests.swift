import XCTest
import KeyboardShortcuts

final class ConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> ConfigFile { try ConfigFile.decode(Data(json.utf8)) }

    func testPartialNixStyleJSONAndUnknownKeys() throws {
        let value = try decode(#"{"version":1,"windowMover":{"enabled":false},"voice":{"autoPaste":false,"unknown":42},"future":true}"#)
        XCTAssertEqual(value.windowMover.enabled, false)
        XCTAssertNil(value.windowMover.shortcut)
        XCTAssertEqual(value.voice.autoPaste, false)
    }

    func testDefaultPaths() {
        XCTAssertEqual(ConfigFile.defaultURL(environment: ["XDG_CONFIG_HOME":"/tmp/config"], homeDirectory: URL(fileURLWithPath: "/home/me")).path, "/tmp/config/xmt/config.json")
        XCTAssertEqual(ConfigFile.defaultURL(environment: [:], homeDirectory: URL(fileURLWithPath: "/home/me")).path, "/home/me/.config/xmt/config.json")
        XCTAssertEqual(ConfigFile.defaultURL(environment: ["XDG_CONFIG_HOME":"relative"], homeDirectory: URL(fileURLWithPath: "/home/me")).path, "/home/me/.config/xmt/config.json")
    }

    func testEveryKeyResolvesIndependentlyAndReportsManagement() throws {
        let file = try decode(#"{"version":1,"windowMover":{"enabled":false},"voice":{"locale":"fr-FR","pasteLatestTranscriptShortcut":{"key":"p","modifiers":["command"]},"inputDevicePriority":[],"fallbackToSystemDefault":false}}"#)
        var local = SettingsValues(); local.autoPaste = false; local.locale = "de-DE"; local.fallbackToSystemDefault = true
        let result = EffectiveSettings.resolve(config: file, local: local)
        XCTAssertEqual(result.windowMoverEnabled.source, .configFile)
        XCTAssertTrue(result.windowMoverEnabled.isManaged)
        XCTAssertEqual(result.locale.value, "fr-FR"); XCTAssertEqual(result.locale.source, .configFile)
        XCTAssertEqual(result.autoPaste.value, false); XCTAssertEqual(result.autoPaste.source, .local); XCTAssertFalse(result.autoPaste.isManaged)
        XCTAssertEqual(result.voiceEnabled.source, .builtIn)
        XCTAssertEqual(result.pasteLatestTranscriptShortcut.value, .key(key: "p", modifiers: ["command"])); XCTAssertTrue(result.pasteLatestTranscriptShortcut.isManaged)
        XCTAssertEqual(result.inputDevicePriority.value, []); XCTAssertTrue(result.inputDevicePriority.isManaged)
        XCTAssertFalse(result.fallbackToSystemDefault.value); XCTAssertTrue(result.fallbackToSystemDefault.isManaged)
    }

    func testPrecedenceMatrix() throws {
        var local = SettingsValues(); local.voiceEnabled = true
        XCTAssertTrue(EffectiveSettings.resolve(config: nil, local: local).voiceEnabled.value)
        let file = try decode(#"{"version":1,"voice":{"enabled":false}}"#)
        XCTAssertFalse(EffectiveSettings.resolve(config: file, local: local).voiceEnabled.value)
        XCTAssertTrue(EffectiveSettings.resolve(config: nil).voiceEnabled.value)
    }

    func testCanonicalHistoryDefaultsAndPerKeyPrecedence() throws {
        let defaults = EffectiveSettings.resolve(config: nil)
        XCTAssertTrue(defaults.historyEnabled.value)
        XCTAssertEqual(defaults.historyRetentionDays.value, 30)
        XCTAssertEqual(defaults.historyMaxEntries.value, 500)
        XCTAssertEqual(defaults.historyEnabled.source, .builtIn)

        var local = SettingsValues()
        local.historyEnabled = false
        local.historyRetentionDays = 14
        local.historyMaxEntries = 200
        let file = try decode(#"{"version":1,"voice":{"history":{"retentionDays":60}}}"#)
        let resolved = EffectiveSettings.resolve(config: file, local: local)
        XCTAssertFalse(resolved.historyEnabled.value)
        XCTAssertEqual(resolved.historyEnabled.source, .local)
        XCTAssertEqual(resolved.historyRetentionDays.value, 60)
        XCTAssertTrue(resolved.historyRetentionDays.isManaged)
        XCTAssertEqual(resolved.historyMaxEntries.value, 200)
        XCTAssertEqual(resolved.historyMaxEntries.source, .local)
    }

    func testKeepLastTranscriptAliasDecodesButCanonicalEncodingIsUsed() throws {
        let aliased = try decode(#"{"version":1,"voice":{"keepLastTranscript":false,"history":{"retentionDays":7,"maxEntries":20}}}"#)
        XCTAssertEqual(aliased.voice.history?.enabled, false)
        XCTAssertEqual(aliased.voice.history?.retentionDays, 7)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(aliased)) as? [String: Any]
        let voice = encoded?["voice"] as? [String: Any]
        XCTAssertNil(voice?["keepLastTranscript"])
        XCTAssertEqual((voice?["history"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    func testKeepLastTranscriptAndCanonicalEnabledConflictRejectsWholeCandidate() async throws {
        XCTAssertThrowsError(try decode(#"{"version":1,"voice":{"keepLastTranscript":true,"history":{"enabled":true}}}"#)) {
            XCTAssertEqual($0 as? ConfigDiagnostic,
                           .invalidValue(path: "voice.keepLastTranscript", reason: "conflicts with voice.history.enabled"))
        }

        final class Box: @unchecked Sendable { var data = Data(#"{"version":1,"voice":{"history":{"enabled":false}}}"#.utf8) }
        let box = Box()
        let loader = ConfigReloader(url: URL(fileURLWithPath: "/unused"), read: { _ in box.data })
        _ = try await loader.reload()
        box.data = Data(#"{"version":1,"voice":{"keepLastTranscript":true,"history":{"enabled":false}}}"#.utf8)
        do { _ = try await loader.reload(); XCTFail("conflicting aliases were accepted") } catch {}
        let retained = await loader.effective
        XCTAssertFalse(retained.historyEnabled.value)
        XCTAssertTrue(retained.historyEnabled.isManaged)
    }

    func testHistoryDefaultsMigrationIsIdempotentAndCanonicalWins() {
        let suiteName = "ConfigTests.history-migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("could not create defaults suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: VoiceHistoryPreferences.legacyKeepLastTranscriptKey)
        VoiceHistoryPreferences.migrate(in: defaults)
        XCTAssertEqual(defaults.object(forKey: VoiceHistoryPreferences.enabledKey) as? Bool, false)
        XCTAssertNil(defaults.object(forKey: VoiceHistoryPreferences.legacyKeepLastTranscriptKey))
        let first = defaults.persistentDomain(forName: suiteName)
        VoiceHistoryPreferences.migrate(in: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName) as NSDictionary?, first as NSDictionary?)

        defaults.set(true, forKey: VoiceHistoryPreferences.enabledKey)
        defaults.set(false, forKey: VoiceHistoryPreferences.legacyKeepLastTranscriptKey)
        VoiceHistoryPreferences.migrate(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: VoiceHistoryPreferences.enabledKey))
        XCTAssertNil(defaults.object(forKey: VoiceHistoryPreferences.legacyKeepLastTranscriptKey))
    }

    func testUnsupportedMalformedAndInvalidKnownValues() {
        XCTAssertThrowsError(try decode(#"{"version":2}"#)) { XCTAssertEqual($0 as? ConfigDiagnostic, .unsupportedVersion(2)) }
        XCTAssertThrowsError(try decode("{"))
        for body in [
            #"{"version":1,"voice":{"fnHoldThresholdMs":49}}"#,
            #"{"version":1,"voice":{"fnHoldThresholdMs":501}}"#,
            #"{"version":1,"voice":{"maxSessionSeconds":0}}"#,
            #"{"version":1,"voice":{"maxSessionSeconds":3601}}"#,
            #"{"version":1,"voice":{"history":{"retentionDays":0}}}"#,
            #"{"version":1,"voice":{"history":{"maxEntries":0}}}"#,
            #"{"version":1,"voice":{"locale":"  "}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":" "}]}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":"Mic","uid":" "}]}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":"Mic","uid":" ABC "},{"name":"Other","uid":"abc"}]}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":" Mic "},{"name":"mic"}]}}"#,
            #"{"version":1,"windowMover":{"shortcut":{"modifier":"fn"}}}"#,
            #"{"version":1,"voice":{"pasteLatestTranscriptShortcut":{"modifier":"fn"}}}"#,
            #"{"version":1,"voice":{"pasteLatestTranscriptShortcut":{"key":"wat"}}}"#
        ] { XCTAssertThrowsError(try decode(body), body) }
    }

    func testShortcutVariantsConversionAndRejection() throws {
        let ordinary = ShortcutDTO.key(key: "K", modifiers: ["command", "shift"])
        let converted = try ordinary.keyboardShortcut()
        XCTAssertEqual(converted.key, .k)
        XCTAssertTrue(converted.modifiers.contains(.command)); XCTAssertTrue(converted.modifiers.contains(.shift))
        XCTAssertThrowsError(try ShortcutDTO.key(key: "wat", modifiers: []).validate())
        XCTAssertThrowsError(try ShortcutDTO.key(key: "k", modifiers: ["hyper"]).validate())
        XCTAssertThrowsError(try ShortcutDTO.key(key: "k", modifiers: ["shift", "shift"]).validate())
        XCTAssertNoThrow(try ShortcutDTO.modifierHold("fn").validate())
        XCTAssertThrowsError(try ShortcutDTO.modifierHold("fn").keyboardShortcut())
        XCTAssertEqual(ShortcutDTO.fromKeyboardShortcut(converted), .key(key: "k", modifiers: ["command", "shift"]))
        XCTAssertThrowsError(try decode(#"{"version":1,"voice":{"shortcut":{"type":"modifierHold","modifier":"command"}}}"#))
        XCTAssertNoThrow(try decode(#"{"version":1,"voice":{"shortcut":{"type":"modifierHold","modifier":"fn"},"pasteLatestTranscriptShortcut":{"type":"key","key":"v","modifiers":["control","command"]}}}"#))
        for value in [ordinary, .modifierHold("fn")] {
            XCTAssertEqual(try JSONDecoder().decode(ShortcutDTO.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testBoundaryAndEmptyDeviceSemantics() throws {
        XCTAssertNoThrow(try decode(#"{"version":1,"voice":{"fnHoldThresholdMs":50,"maxSessionSeconds":1,"inputDevicePriority":[],"fallbackToSystemDefault":false}}"#))
        XCTAssertNoThrow(try decode(#"{"version":1,"voice":{"fnHoldThresholdMs":500,"maxSessionSeconds":3600}}"#))
    }

    func testReloadSuccessFailureAndNoChange() async throws {
        final class Box: @unchecked Sendable { var data = Data(#"{"version":1,"voice":{"enabled":true}}"#.utf8) }
        let box = Box()
        let loader = ConfigReloader(url: URL(fileURLWithPath: "/unused"), read: { _ in box.data })
        let first = try await loader.reload()
        XCTAssertEqual(first.changedKeys, [.voiceEnabled]); XCTAssertTrue(first.effective.voiceEnabled.value)
        let unchanged = try await loader.reload(); XCTAssertTrue(unchanged.changedKeys.isEmpty)
        box.data = Data(#"{"version":1,"voice":{"fnHoldThresholdMs":1}}"#.utf8)
        do { _ = try await loader.reload(); XCTFail("invalid candidate accepted") } catch {}
        let retained = await loader.effective
        XCTAssertTrue(retained.voiceEnabled.value)
        let diagnostic = await loader.lastDiagnostic
        XCTAssertNotNil(diagnostic)
        box.data = Data(#"{"version":1,"voice":{"enabled":false}}"#.utf8)
        _ = try await loader.reload()
        let cleared = await loader.lastDiagnostic
        XCTAssertNil(cleared)
    }

    func testRemovalRevertsToLocalAndBuiltInsWithMultiKeyChanges() async throws {
        final class Box: @unchecked Sendable { var removed = false }
        let box = Box()
        var local = SettingsValues(); local.voiceEnabled = true
        let loader = ConfigReloader(url: URL(fileURLWithPath: "/unused"), local: local) { _ in
            if box.removed { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError) }
            return Data(#"{"version":1,"voice":{"enabled":false,"autoPaste":false}}"#.utf8)
        }
        _ = try await loader.reload(); box.removed = true
        let result = try await loader.reload()
        XCTAssertEqual(result.changedKeys, [.voiceEnabled, .autoPaste, .outputMode])
        XCTAssertTrue(result.effective.voiceEnabled.value); XCTAssertEqual(result.effective.voiceEnabled.source, .local)
        XCTAssertTrue(result.effective.autoPaste.value); XCTAssertEqual(result.effective.autoPaste.source, .builtIn)
    }

    func testReloadRejectsEffectiveGlobalShortcutConflict() async throws {
        let json = #"{"version":1,"windowMover":{"shortcut":{"type":"key","key":"v","modifiers":["control","command"]}}}"#
        let loader = ConfigReloader(local: .init(), read: { _ in Data(json.utf8) })
        do {
            _ = try await loader.reload()
            XCTFail("expected shortcut conflict")
        } catch {
            XCTAssertEqual(error as? ConfigDiagnostic,
                           .invalidValue(path: "voice.pasteLatestTranscriptShortcut", reason: "conflicts with windowMover.shortcut"))
        }
    }

    func testReloadUsesUpdatedLiveLocalBaseline() async throws {
        final class Box: @unchecked Sendable { var removed = false }
        let box = Box()
        var original = SettingsValues(); original.windowMoverEnabled = true; original.autoPaste = true
        let loader = ConfigReloader(url: URL(fileURLWithPath: "/unused"), local: original) { _ in
            if box.removed { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError) }
            return Data(#"{"version":1,"voice":{"locale":"fr-FR"}}"#.utf8)
        }
        _ = try await loader.reload()
        var edited = original; edited.windowMoverEnabled = false; edited.autoPaste = false
        await loader.updateLocal(edited); box.removed = true
        let result = try await loader.reload()
        XCTAssertFalse(result.effective.windowMoverEnabled.value)
        XCTAssertFalse(result.effective.autoPaste.value)
        XCTAssertEqual(result.effective.windowMoverEnabled.source, .local)
        XCTAssertEqual(result.effective.autoPaste.source, .local)
    }

    func testPasteLatestShortcutPrecedenceAndRemoval() throws {
        var local = SettingsValues()
        local.pasteLatestTranscriptShortcut = .key(key: "l", modifiers: ["option"])
        let builtIn = EffectiveSettings.resolve(config: nil)
        XCTAssertEqual(builtIn.pasteLatestTranscriptShortcut.value, .key(key: "v", modifiers: ["control", "command"]))
        let localResult = EffectiveSettings.resolve(config: nil, local: local)
        XCTAssertEqual(localResult.pasteLatestTranscriptShortcut.value, .key(key: "l", modifiers: ["option"]))
        XCTAssertEqual(localResult.pasteLatestTranscriptShortcut.source, .local)
        let managed = EffectiveSettings.resolve(
            config: try decode(#"{"version":1,"voice":{"pasteLatestTranscriptShortcut":{"key":"p","modifiers":["command","shift"]}}}"#),
            local: local
        )
        XCTAssertEqual(managed.pasteLatestTranscriptShortcut.value, .key(key: "p", modifiers: ["command", "shift"]))
        XCTAssertTrue(managed.pasteLatestTranscriptShortcut.isManaged)
        XCTAssertEqual(localResult.changedKeys(from: managed), [.pasteLatestTranscriptShortcut])
    }

    func testChangedKeysIncludesSourceOnlyManagementChange() throws {
        var local = SettingsValues(); local.voiceEnabled = true
        let unmanaged = EffectiveSettings.resolve(config: nil, local: local)
        let managed = EffectiveSettings.resolve(config: try decode(#"{"version":1,"voice":{"enabled":true}}"#), local: local)
        XCTAssertEqual(managed.changedKeys(from: unmanaged), [.voiceEnabled])
    }

    func testConcurrentReloadCallbacksDoNotInterleave() async throws {
        actor Gate {
            var events: [String] = []; var continuation: CheckedContinuation<Void, Never>?
            var secondInvocationStarted = false
            func callback(_ enabled: Bool) async {
                events.append("start-\(enabled)")
                if enabled { await withCheckedContinuation { continuation = $0 } }
                events.append("end-\(enabled)")
            }
            func markSecondInvocationStarted() { secondInvocationStarted = true }
            func hasStartedSecondInvocation() -> Bool { secondInvocationStarted }
            func release() { continuation?.resume(); continuation = nil }
            func snapshot() -> [String] { events }
        }
        final class Box: @unchecked Sendable { var data = Data(#"{"version":1,"voice":{"enabled":true}}"#.utf8) }
        let box = Box(), gate = Gate()
        let loader = ConfigReloader(url: URL(fileURLWithPath: "/unused"), read: { _ in box.data })
        await loader.addApplyCallback { await gate.callback($0.effective.voiceEnabled.value) }
        let first = Task { try await loader.reload() }
        while await gate.snapshot().isEmpty { await Task.yield() }
        box.data = Data(#"{"version":1,"voice":{"enabled":false}}"#.utf8)
        let second = Task {
            await gate.markSecondInvocationStarted()
            return try await loader.reload()
        }
        while !(await gate.hasStartedSecondInvocation()) { await Task.yield() }
        // Give an unchained second reload ample opportunity to enter its callback.
        // With publication chaining it must remain behind the suspended first callback.
        for _ in 0..<200 { await Task.yield() }
        let suspendedEvents = await gate.snapshot()
        XCTAssertEqual(suspendedEvents, ["start-true"])
        await gate.release()
        _ = try await first.value; _ = try await second.value
        let finalEvents = await gate.snapshot()
        XCTAssertEqual(finalEvents, ["start-true", "end-true", "start-false", "end-false"])
    }
    func testVoiceV2DefaultsAndLegacyMigration() throws {
        let defaults = EffectiveSettings.resolve(config: nil)
        XCTAssertEqual(defaults.holdToTalkShortcut.value, .modifierHold("fn"))
        XCTAssertEqual(defaults.toggleRecordingShortcut.value, .fnChord(key: "space"))
        XCTAssertEqual(defaults.cancelShortcut.value, .fnChord(key: "escape"))
        XCTAssertEqual(defaults.outputMode.value, .pasteImmediately)
        XCTAssertEqual(defaults.locale.value, "system")
        let migrated = EffectiveSettings.resolve(config: try decode(#"{"version":1,"voice":{"shortcut":{"type":"modifierHold","modifier":"fn"},"autoPaste":false}}"#))
        XCTAssertEqual(migrated.holdToTalkShortcut.value, .modifierHold("fn"))
        XCTAssertEqual(migrated.outputMode.value, .clipboardOnly)
    }

    func testThreeVoiceBindingsRejectConflictAtomically() async throws {
        let json = #"{"version":1,"voice":{"toggleRecordingShortcut":{"key":"escape"},"cancelShortcut":{"key":"escape"}}}"#
        let loader = ConfigReloader(local: .init(), read: { _ in Data(json.utf8) })
        do { _ = try await loader.reload(); XCTFail("expected conflict") }
        catch { XCTAssertNotNil(error as? ConfigDiagnostic) }
    }

    func testExplicitUnboundOverridesDefaultAndInvalidBindingsNeverConflict() async throws {
        var local = SettingsValues(); local.holdToTalkShortcut = .unbound; local.toggleRecordingShortcut = .unbound; local.cancelShortcut = .unbound
        let effective = EffectiveSettings.resolve(config: nil, local: local)
        XCTAssertEqual(effective.holdToTalkShortcut.value, .unbound)
        XCTAssertEqual(effective.toggleRecordingShortcut.value, .unbound)
        XCTAssertEqual(effective.cancelShortcut.value, .unbound)
        XCTAssertFalse(ShortcutDTO.key(key: "not-a-key", modifiers: []).conflicts(with: .key(key: "also-invalid", modifiers: [])))
    }

    func testConflictDiagnosticLeavesEffectiveSnapshotUnchanged() async throws {
        let loader = ConfigReloader(local: .init(), read: { _ in Data(#"{"version":1,"voice":{"toggleRecordingShortcut":{"key":"x","modifiers":["command"]},"cancelShortcut":{"key":"x","modifiers":["command"]}}}"#.utf8) })
        let before = await loader.effective
        do { _ = try await loader.reload(); XCTFail("expected conflict") }
        catch {
            XCTAssertEqual(error as? ConfigDiagnostic, .invalidValue(path: "voice.cancelShortcut", reason: "conflicts with voice.toggleRecordingShortcut"))
            let after = await loader.effective; XCTAssertEqual(after, before)
        }
    }

    func testVoiceShortcutRegistrationAndOverlayPolicies() {
        XCTAssertEqual(VoiceShortcutActivationPolicy.decide(moduleEnabled: true, phase: .idle),
                       .init(holdEnabled: true, toggleEnabled: true, cancelEnabled: false))
        XCTAssertTrue(VoiceShortcutActivationPolicy.decide(moduleEnabled: true, phase: .arming).cancelEnabled)
        XCTAssertFalse(VoiceShortcutActivationPolicy.decide(moduleEnabled: true, phase: .finalizing).cancelEnabled)
        XCTAssertEqual(VoiceShortcutActivationPolicy.decide(moduleEnabled: false, phase: .recording),
                       .init(holdEnabled: false, toggleEnabled: false, cancelEnabled: false))
        XCTAssertEqual(VoiceOverlayPolicy.presentation(for: .idle), .hidden)
        XCTAssertEqual(VoiceOverlayPolicy.presentation(for: .finalizing), .finalizing)
        XCTAssertEqual(VoiceOverlayPolicy.controls(for: .arming).cancel, true)
        XCTAssertEqual(VoiceOverlayPolicy.controls(for: .finalizing).cancel, false)
    }

    func testUnboundDiagnosticForActionsThatRequireBindings() {
        XCTAssertThrowsError(try decode(#"{"version":1,"windowMover":{"shortcut":{"type":"unbound"}}}"#)) {
            XCTAssertEqual($0 as? ConfigDiagnostic, .invalidValue(path: "windowMover.shortcut", reason: "must be a key shortcut; unbound is not supported"))
        }
        XCTAssertThrowsError(try decode(#"{"version":1,"voice":{"pasteLatestTranscriptShortcut":{"type":"unbound"}}}"#)) {
            XCTAssertEqual($0 as? ConfigDiagnostic, .invalidValue(path: "voice.pasteLatestTranscriptShortcut", reason: "must be a key shortcut; unbound is not supported"))
        }
    }

    func testVoiceActionListAllowsEmptyUniqueAddRemoveAndReorder() {
        var list = VoiceActionListModel()
        XCTAssertTrue(list.actions.isEmpty)
        XCTAssertTrue(list.add(.holdToTalk))
        XCTAssertTrue(list.add(.cancel))
        XCTAssertFalse(list.add(.holdToTalk))
        list.move(.cancel, by: -1)
        XCTAssertEqual(list.actions, [.cancel, .holdToTalk])
        list.remove(.cancel)
        XCTAssertEqual(list.actions, [.holdToTalk])
        list.remove(.holdToTalk)
        XCTAssertTrue(list.actions.isEmpty)
        XCTAssertEqual(list.availableActions, [.holdToTalk, .toggleRecording, .cancel])
    }

    func testCaptureLeaseRejectsStaleReleaseAndDisappearanceCancelsOwner() {
        var lease = VoiceBindingCaptureLease()
        let rowA = lease.acquire()
        let rowB = lease.acquire()
        XCTAssertTrue(lease.isActive)
        XCTAssertFalse(lease.release(rowA), "stale row A completion must not release row B")
        XCTAssertTrue(lease.isActive)
        XCTAssertTrue(lease.release(rowB))
        XCTAssertFalse(lease.isActive)
        let disappearing = lease.acquire()
        XCTAssertTrue(lease.cancelAll())
        XCTAssertFalse(lease.release(disappearing))
        XCTAssertFalse(lease.cancelAll())
    }

    func testAddCaptureCancelRollsBackPlaceholderAndStaleCompletionCannotTouchNewOperation() {
        var routingLease = VoiceBindingCaptureLease()
        var transaction = VoiceBindingCaptureTransaction()
        let original: [ShortcutDTO] = [.fnChord(key: "h")]

        let addToken = routingLease.acquire()
        transaction.begin(token: addToken, rollback: .init(action: .holdToTalk, bindings: original))
        var displayed = original + [.unbound]
        if let rollback = transaction.conclude(token: addToken, committed: false) {
            displayed = rollback.bindings
        }
        XCTAssertEqual(displayed, original, "cancelling Add must remove its provisional row")
        XCTAssertTrue(routingLease.release(addToken))

        let oldToken = routingLease.acquire()
        transaction.begin(token: oldToken)
        let newToken = routingLease.acquire()
        transaction.begin(token: newToken, rollback: .init(action: .cancel, bindings: []))
        XCTAssertNil(transaction.conclude(token: oldToken, committed: true))
        XCTAssertEqual(transaction.token, newToken, "an old operation completion must not conclude the current transaction")
        XCTAssertFalse(routingLease.release(oldToken), "an old operation completion must not restore live routing")
        XCTAssertNotNil(transaction.conclude(token: newToken, committed: false))
        XCTAssertTrue(routingLease.release(newToken))
    }

    func testCanonicalOrderedBindingArraysAndSingularMigration() throws {
        let file = try decode(#"{"version":1,"voice":{"holdToTalkBindings":[{"type":"fnChord","key":"h"},{"key":"k","modifiers":["control"]}],"toggleRecordingShortcut":{"type":"fnChord","key":"t"}}}"#)
        XCTAssertEqual(file.voice.holdToTalkBindings, [.fnChord(key: "h"), .key(key: "k", modifiers: ["control"])])
        XCTAssertEqual(file.voice.toggleRecordingShortcut, .fnChord(key: "t"))
        let voice = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])?["voice"] as? [String: Any]
        XCTAssertEqual((voice?["holdToTalkBindings"] as? [Any])?.count, 2)
        XCTAssertEqual((voice?["toggleRecordingBindings"] as? [Any])?.count, 1)
        XCTAssertNil(voice?["toggleRecordingShortcut"])
    }

    func testBindingArrayPrecedenceAndExplicitEmptyMeansUnbound() throws {
        var local = SettingsValues(); local.holdToTalkShortcut = .key(key: "l", modifiers: ["control"])
        let empty = try decode(#"{"version":1,"voice":{"holdToTalkBindings":[]}}"#)
        let resolved = EffectiveSettings.resolve(config: empty, local: local)
        XCTAssertEqual(resolved.holdToTalkShortcut.value, .unbound)
        XCTAssertTrue(resolved.holdToTalkShortcut.isManaged)
        let ordered = try decode(#"{"version":1,"voice":{"holdToTalkBindings":[{"key":"a","modifiers":["control"]},{"key":"b","modifiers":["option"]}]}}"#)
        let orderedEffective = EffectiveSettings.resolve(config: ordered, local: local)
        XCTAssertEqual(orderedEffective.holdToTalkShortcut.value, .key(key: "a", modifiers: ["control"]))
        XCTAssertEqual(orderedEffective.holdToTalkBindings.value, [
            .key(key: "a", modifiers: ["control"]), .key(key: "b", modifiers: ["option"])
        ])
    }

    func testBindingOverlapPolicyRejectsDuplicatesAndCrossActionOverlap() {
        let a = ShortcutDTO.key(key: "x", modifiers: ["command"])
        XCTAssertEqual(VoiceBindingPolicy.firstOverlap(in: [
            .init(path: "hold[0]", action: .holdToTalk, binding: a),
            .init(path: "hold[1]", action: .holdToTalk, binding: a)
        ])?.later, "hold[1]")
        XCTAssertEqual(VoiceBindingPolicy.firstOverlap(in: [
            .init(path: "hold[0]", action: .holdToTalk, binding: a),
            .init(path: "cancel[0]", action: .cancel, binding: a)
        ])?.earlier, "hold[0]")
        XCTAssertNil(VoiceBindingPolicy.firstOverlap(in: [
            .init(path: "hold[0]", action: .holdToTalk, binding: .unbound),
            .init(path: "cancel[0]", action: .cancel, binding: .unbound)
        ]))
        XCTAssertThrowsError(try decode(#"{"version":1,"voice":{"cancelBindings":[{"key":"escape"},{"key":"ESCAPE"}]}}"#)) {
            XCTAssertEqual($0 as? ConfigDiagnostic,
                           .invalidValue(path: "voice.cancelBindings[1]", reason: "conflicts with voice.cancelBindings[0]"))
        }
    }

    func testCanonicalBindingPersistenceAndOneReleaseScalarDecode() throws {
        let values: [ShortcutDTO] = [.fnChord(key: "a"), .fnChord(key: "b")]
        XCTAssertEqual(VoiceBindingPersistence.localBindings(explicit: true, canonicalData: try JSONEncoder().encode(values), legacyValue: nil), values)
        XCTAssertEqual(VoiceBindingPersistence.localBindings(explicit: true, canonicalData: try JSONEncoder().encode(values[0]), legacyValue: nil), [values[0]])
        XCTAssertEqual(VoiceBindingPersistence.localBindings(explicit: true, canonicalData: nil, legacyValue: nil), [])
        XCTAssertNil(VoiceBindingPersistence.localBindings(explicit: false, canonicalData: try JSONEncoder().encode(values), legacyValue: nil))
    }

    func testAllLegacyVoiceBindingsPreserveExplicitUnbound() throws {
        for action in [VoiceBindingAction.holdToTalk, .toggleRecording, .cancel] {
            XCTAssertEqual(VoiceBindingPersistence.localValue(explicit: true, canonicalData: nil, legacyValue: nil), .unbound, "failed for \(action)")
        }
        XCTAssertNil(VoiceBindingPersistence.localValue(explicit: false, canonicalData: nil, legacyValue: .key(key: "x", modifiers: ["control"])))
        let fn = ShortcutDTO.fnChord(key: "escape")
        XCTAssertEqual(VoiceBindingPersistence.localValue(explicit: true, canonicalData: try JSONEncoder().encode(fn), legacyValue: nil), fn)
    }

    func testManagedVoiceBindingsRestoreAllIndependentLocalValues() throws {
        var local = SettingsValues()
        local.holdToTalkBindings = [.key(key: "h", modifiers: ["control"]), .fnChord(key: "h")]
        local.toggleRecordingBindings = [.key(key: "t", modifiers: ["control"]), .fnChord(key: "t")]
        local.cancelBindings = [.fnChord(key: "f12"), .key(key: "escape", modifiers: ["command"])]
        let managed = try decode(#"{"version":1,"voice":{"holdToTalkShortcut":{"type":"fnChord","key":"h"},"toggleRecordingShortcut":{"type":"unbound"},"cancelShortcut":{"type":"key","key":"escape","modifiers":["control"]}}}"#)
        let effectiveManaged = EffectiveSettings.resolve(config: managed, local: local)
        XCTAssertEqual(effectiveManaged.holdToTalkShortcut.value, .fnChord(key: "h"))
        XCTAssertEqual(effectiveManaged.toggleRecordingShortcut.value, .unbound)
        XCTAssertEqual(effectiveManaged.cancelShortcut.value, .key(key: "escape", modifiers: ["control"]))
        let restored = EffectiveSettings.resolve(config: nil, local: local)
        XCTAssertEqual(restored.holdToTalkBindings.value, local.holdToTalkBindings)
        XCTAssertEqual(restored.toggleRecordingBindings.value, local.toggleRecordingBindings)
        XCTAssertEqual(restored.cancelBindings.value, local.cancelBindings)
    }

    func testVoiceRecorderEscapeFnClearAndCancelModel() throws {
        let escape = ShortcutDTO.key(key: "escape", modifiers: [])
        let controlEscape = ShortcutDTO.key(key: "escape", modifiers: ["control"])
        XCTAssertNil(VoiceBindingPolicy.validate(escape, for: .cancel))
        XCTAssertNil(VoiceBindingPolicy.validate(controlEscape, for: .holdToTalk))
        XCTAssertNil(VoiceBindingPolicy.validate(controlEscape, for: .toggleRecording))
        XCTAssertNil(VoiceBindingPolicy.validate(controlEscape, for: .cancel))
        XCTAssertEqual(VoiceBindingPolicy.validate(escape, for: .holdToTalk), .unsafeUnmodifiedKey)
        XCTAssertEqual(VoiceBindingPolicy.validate(.key(key: "a", modifiers: []), for: .toggleRecording), .unsafeUnmodifiedKey)
        XCTAssertEqual(VoiceBindingPolicy.validate(.key(key: "escape", modifiers: ["shift"]), for: .holdToTalk), .unsafeUnmodifiedKey)
        XCTAssertEqual(VoiceBindingPolicy.validate(.key(key: "a", modifiers: ["shift"]), for: .toggleRecording), .unsafeUnmodifiedKey)
        XCTAssertNil(VoiceBindingPolicy.validate(.modifierHold("fn"), for: .holdToTalk))
        XCTAssertEqual(VoiceBindingPolicy.validate(.modifierHold("fn"), for: .cancel), .modifierOnlyRequiresHold)
        XCTAssertEqual(ShortcutDTO.fromKeyboardShortcut(try controlEscape.keyboardShortcut()), controlEscape)

        var model = VoiceBindingRecorderModel()
        model.receive(.begin(.holdToTalk)); model.receive(.captured(.holdToTalk, escape))
        XCTAssertEqual(model.pendingCommit?.binding, escape); XCTAssertNil(model.activeAction)
        model.receive(.begin(.holdToTalk)); model.receive(.begin(.cancel))
        XCTAssertEqual(model.activeAction, .cancel, "starting one row replaces the prior capture")
        model.receive(.cancel(.holdToTalk)); XCTAssertEqual(model.activeAction, .cancel, "a stale row cannot cancel the active row")
        model.receive(.cancel(.cancel)); XCTAssertNil(model.activeAction)
        model.receive(.clear(.toggleRecording)); XCTAssertEqual(model.pendingCommit?.binding, .unbound)
        model.receive(.selectFn); XCTAssertEqual(model.pendingCommit?.action, .holdToTalk)
        XCTAssertEqual(model.pendingCommit?.binding, .modifierHold("fn"))
    }

    func testVoiceBindingCaptureDecoderCapturesEscapeVariantsAndBareFn() {
        var bareEscape = VoiceBindingCaptureDecoder()
        XCTAssertEqual(bareEscape.keyDown(keyCode: 53, modifiers: [], isRepeat: false),
                       .captured(.key(key: "escape", modifiers: [])))

        var controlEscape = VoiceBindingCaptureDecoder()
        XCTAssertEqual(controlEscape.keyDown(keyCode: 53, modifiers: [.control], isRepeat: false),
                       .captured(.key(key: "escape", modifiers: ["control"])))

        var fnEscape = VoiceBindingCaptureDecoder()
        XCTAssertEqual(fnEscape.flagsChanged([.function]), .ignored)
        XCTAssertEqual(fnEscape.keyDown(keyCode: 53, modifiers: [.function], isRepeat: false),
                       .captured(.fnChord(key: "escape")))
        XCTAssertEqual(fnEscape.flagsChanged([]), .ignored, "an Fn chord must not also decode as bare Fn")

        var bareFn = VoiceBindingCaptureDecoder()
        XCTAssertEqual(bareFn.flagsChanged([.function]), .ignored)
        XCTAssertEqual(bareFn.flagsChanged([]), .captured(.modifierHold("fn")))
    }

    func testVoiceBindingCaptureDecoderRejectsUnsupportedAndNonBareFn() {
        var decoder = VoiceBindingCaptureDecoder()
        XCTAssertEqual(decoder.keyDown(keyCode: .max, modifiers: [], isRepeat: false), .unsupported)
        XCTAssertEqual(decoder.keyDown(keyCode: 53, modifiers: [], isRepeat: true), .ignored)
        XCTAssertEqual(decoder.flagsChanged([.control, .function]), .ignored)
        XCTAssertEqual(decoder.flagsChanged([]), .ignored)
    }

    func testVoiceBindingPolicyAndConflictValidation() throws {
        let controlEscape = ShortcutDTO.key(key: "escape", modifiers: ["control"])
        XCTAssertTrue(controlEscape.conflicts(with: .key(key: "escape", modifiers: ["CONTROL"])))
        XCTAssertFalse(controlEscape.conflicts(with: .key(key: "escape", modifiers: [])))
        XCTAssertTrue(ShortcutDTO.fnChord(key: "escape").conflicts(with: .fnChord(key: "ESCAPE")))
        XCTAssertFalse(ShortcutDTO.modifierHold("fn").conflicts(with: .fnChord(key: "escape")))
        let value = ShortcutDTO.fnChord(key: "pageup")
        XCTAssertEqual(try JSONDecoder().decode(ShortcutDTO.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(try decode(#"{"version":1,"voice":{"toggleRecordingShortcut":{"type":"fnChord","key":"f12"}}}"#).voice.toggleRecordingShortcut, .fnChord(key: "f12"))
    }

    func testResolvedSecondaryBindingsValidateMaxDuplicatesAndCrossActionAtomically() async throws {
        let missing: @Sendable (URL) throws -> Data = { _ in throw CocoaError(.fileReadNoSuchFile) }

        var tooMany = SettingsValues()
        tooMany.holdToTalkBindings = (0...VoiceBindingPersistence.maximumBindingsPerAction).map { .fnChord(key: "f\($0 + 1)") }
        let maxLoader = ConfigReloader(local: tooMany, read: missing)
        let maxBefore = await maxLoader.effective
        do { _ = try await maxLoader.reload(); XCTFail("expected maximum rejection") }
        catch { XCTAssertEqual(error as? ConfigDiagnostic, .invalidValue(path: "voice.holdToTalkBindings", reason: "supports at most 8 bindings")) }
        let maxAfter = await maxLoader.effective
        let maxDiagnostic = await maxLoader.lastDiagnostic
        XCTAssertEqual(maxAfter, maxBefore)
        XCTAssertEqual(maxDiagnostic, .invalidValue(path: "voice.holdToTalkBindings", reason: "supports at most 8 bindings"))

        let duplicate = ShortcutDTO.key(key: "d", modifiers: ["command"])
        var locals = SettingsValues()
        locals.holdToTalkBindings = [.fnChord(key: "h"), duplicate]
        locals.cancelBindings = [.fnChord(key: "c"), duplicate]
        let conflictLoader = ConfigReloader(local: locals, read: missing)
        let conflictBefore = await conflictLoader.effective
        do { _ = try await conflictLoader.reload(); XCTFail("expected secondary cross-action conflict") }
        catch { XCTAssertEqual(error as? ConfigDiagnostic, .invalidValue(path: "voice.cancelBindings[1]", reason: "conflicts with voice.holdToTalkBindings[1]")) }
        let conflictAfter = await conflictLoader.effective
        XCTAssertEqual(conflictAfter, conflictBefore)

        locals.cancelBindings = [.fnChord(key: "c")]
        locals.holdToTalkBindings = [duplicate, duplicate]
        let duplicateLoader = ConfigReloader(local: locals, read: missing)
        do { _ = try await duplicateLoader.reload(); XCTFail("expected duplicate") }
        catch { XCTAssertEqual(error as? ConfigDiagnostic, .invalidValue(path: "voice.holdToTalkBindings[1]", reason: "conflicts with voice.holdToTalkBindings[0]")) }
    }

    func testManagedBackupMigrationRestoresScalarAndArrayAndRemovesStaleData() throws {
        let suite = "ConfigTests.managedBackup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefix = "voice.binding.hold"
        let scalar = ShortcutDTO.fnChord(key: "h")
        defaults.set(true, forKey: "\(prefix).backupActive")
        defaults.set(try JSONEncoder().encode(scalar), forKey: "\(prefix).backup")
        XCTAssertEqual(VoiceBindingPersistence.restoreManagedBackup(in: defaults, key: prefix), [scalar])
        XCTAssertNil(defaults.object(forKey: "\(prefix).backupActive"))
        XCTAssertNil(defaults.data(forKey: "\(prefix).backup"))

        let array = [scalar, .key(key: "j", modifiers: ["control"])]
        VoiceBindingPersistence.saveManagedBackup(array, in: defaults, key: prefix)
        XCTAssertEqual(VoiceBindingPersistence.restoreManagedBackup(in: defaults, key: prefix), array)

        defaults.set(try JSONEncoder().encode(array), forKey: "\(prefix).backup")
        VoiceBindingPersistence.saveManagedBackup(nil, in: defaults, key: prefix)
        XCTAssertNil(defaults.data(forKey: "\(prefix).backup"), "a nil local value must clear a stale backup")
        XCTAssertNil(VoiceBindingPersistence.restoreManagedBackup(in: defaults, key: prefix), "an absent local value must restore as absent")

        VoiceBindingPersistence.saveManagedBackup([], in: defaults, key: prefix)
        XCTAssertEqual(VoiceBindingPersistence.restoreManagedBackup(in: defaults, key: prefix), [], "explicit unbound must not restore stale bindings")

        defaults.set(try JSONEncoder().encode(scalar), forKey: "\(prefix).backup")
        XCTAssertNil(VoiceBindingPersistence.restoreManagedBackup(in: defaults, key: prefix))
        XCTAssertNil(defaults.data(forKey: "\(prefix).backup"), "inactive stale backup must be removed")
    }

    func testStagedLocalBindingFailureDoesNotChangeBaselineOrEffective() async throws {
        let missing: @Sendable (URL) throws -> Data = { _ in throw CocoaError(.fileReadNoSuchFile) }
        var local = SettingsValues(); local.holdToTalkShortcut = .key(key: "h", modifiers: ["control"])
        let loader = ConfigReloader(local: local, read: missing)
        let accepted = try await loader.reload()
        var staged = local
        staged.holdToTalkShortcut = .fnChord(key: "space")
        do { _ = try await loader.stageAndReload(local: staged); XCTFail("expected default toggle conflict") } catch {}
        let afterFailure = await loader.effective; XCTAssertEqual(afterFailure, accepted.effective)
        let reloaded = try await loader.reload()
        XCTAssertEqual(reloaded.effective.holdToTalkShortcut.value, .key(key: "h", modifiers: ["control"]))
    }

    func testShiftOnlyVoiceBindingsRejectInConfigAndEffectiveReload() async {
        XCTAssertThrowsError(try decode(#"{"version":1,"voice":{"holdToTalkShortcut":{"key":"h","modifiers":["shift"]}}}"#)) {
            XCTAssertEqual($0 as? ConfigDiagnostic, .invalidValue(path: "voice.holdToTalkShortcut", reason: "requires Control, Option, or Command; Shift alone is unsafe"))
        }
        var local = SettingsValues(); local.toggleRecordingShortcut = .key(key: "t", modifiers: ["shift"])
        let loader = ConfigReloader(local: local, read: { _ in throw CocoaError(.fileReadNoSuchFile) })
        do { _ = try await loader.reload(); XCTFail("expected safety rejection") }
        catch { XCTAssertEqual(error as? ConfigDiagnostic, .invalidValue(path: "voice.toggleRecordingShortcut", reason: "requires Control, Option, or Command; Shift alone is unsafe")) }
    }

    func testStagingAgainstNewlyUnreadableConfigIsAtomic() async throws {
        final class Box: @unchecked Sendable { var unreadable = false }
        let box = Box()
        let loader = ConfigReloader(local: .init(), read: { _ in
            if box.unreadable { throw CocoaError(.fileReadNoPermission) }
            throw CocoaError(.fileReadNoSuchFile)
        })
        let initial = try await loader.reload(); box.unreadable = true
        var staged = SettingsValues(); staged.cancelShortcut = .key(key: "escape", modifiers: [])
        do { _ = try await loader.stageAndReload(local: staged); XCTFail("expected unreadable config") } catch {}
        let after = await loader.effective
        XCTAssertEqual(after, initial.effective)
    }

    func testManagedBindingStageIsRejectedWithoutLaunderingLocalBaseline() async throws {
        final class Box: @unchecked Sendable { var managed = true }
        let box = Box()
        var local = SettingsValues(); local.holdToTalkShortcut = .key(key: "h", modifiers: ["control"])
        let loader = ConfigReloader(local: local, read: { _ in
            if box.managed { return Data(#"{"version":1,"voice":{"holdToTalkShortcut":{"key":"m","modifiers":["command"]}}}"#.utf8) }
            throw CocoaError(.fileReadNoSuchFile)
        })
        _ = try await loader.reload()
        var staged = local; staged.holdToTalkShortcut = .key(key: "n", modifiers: ["option"])
        do { _ = try await loader.stageAndReload(local: staged, requiringUnmanaged: .holdToTalk); XCTFail("expected managed rejection") }
        catch { XCTAssertEqual(error as? ConfigDiagnostic, .invalidValue(path: "voice.holdToTalkShortcut", reason: "is managed by configuration")) }
        box.managed = false
        let restored = try await loader.reload()
        XCTAssertEqual(restored.effective.holdToTalkShortcut.value, .key(key: "h", modifiers: ["control"]))
    }

    func testBuiltInLocalSnapshotIsTheExactCompleteFreshDefault() {
        let builtIn = BuiltInSettings.standard
        let local = builtIn.localSnapshot
        let resolved = EffectiveSettings.resolve(config: nil, local: local, builtIn: builtIn)

        XCTAssertEqual(resolved.windowMoverEnabled.value, true)
        XCTAssertEqual(resolved.windowMoverShortcut.value, .key(key: "space", modifiers: ["option"]))
        XCTAssertEqual(resolved.voiceEnabled.value, true)
        XCTAssertEqual(resolved.holdToTalkBindings.value, [.modifierHold("fn")])
        XCTAssertEqual(resolved.toggleRecordingBindings.value, [.fnChord(key: "space")])
        XCTAssertEqual(resolved.cancelBindings.value, [.fnChord(key: "escape")])
        XCTAssertEqual(resolved.pasteLatestTranscriptShortcut.value, .key(key: "v", modifiers: ["control", "command"]))
        XCTAssertEqual(resolved.outputMode.value, .pasteImmediately)
        XCTAssertEqual(resolved.historyEnabled.value, true)
        XCTAssertEqual(resolved.historyRetentionDays.value, 30)
        XCTAssertEqual(resolved.historyMaxEntries.value, 500)
        XCTAssertEqual(resolved.locale.value, "system")
        XCTAssertEqual(resolved.fnHoldThresholdMs.value, 150)
        XCTAssertEqual(resolved.maxSessionSeconds.value, 300)
        XCTAssertEqual(resolved.inputDevicePriority.value, [])
        XCTAssertEqual(resolved.fallbackToSystemDefault.value, true)
        XCTAssertTrue([resolved.windowMoverEnabled.source, resolved.voiceEnabled.source,
                       resolved.historyEnabled.source].allSatisfy { $0 == .local })
    }

    func testRestorePlanCanonicalizesCustomValuesAndPreservesManagedLocalShadows() throws {
        var current = SettingsValues()
        current.windowMoverEnabled = false
        current.windowMoverShortcut = .key(key: "w", modifiers: ["command"])
        current.voiceEnabled = false
        current.holdToTalkShortcut = .key(key: "h", modifiers: ["control"])
        current.toggleRecordingBindings = []
        current.cancelBindings = [.key(key: "c", modifiers: ["command"])]
        current.pasteLatestTranscriptShortcut = .key(key: "p", modifiers: ["command"])
        current.autoPaste = false
        current.historyEnabled = false
        current.historyRetentionDays = 2
        current.historyMaxEntries = 3
        current.locale = "fr-FR"
        current.fnHoldThresholdMs = 200
        current.maxSessionSeconds = 20
        current.inputDevicePriority = [.init(name: "Custom mic", uid: "custom")]
        current.fallbackToSystemDefault = false

        let unmanaged = SettingsRestorePlan.make(
            current: current, effective: .resolve(config: nil, local: current))
        XCTAssertEqual(unmanaged.candidate, BuiltInSettings.standard.localSnapshot)
        XCTAssertEqual(unmanaged.restoredKeys, Set(EffectiveSettings.Key.allCases))
        XCTAssertTrue(unmanaged.preservedManagedKeys.isEmpty)

        let file = try decode(#"{"version":1,"windowMover":{"enabled":true},"voice":{"holdToTalkBindings":[{"type":"modifierHold","modifier":"fn"}],"locale":"de-DE"}}"#)
        let effective = EffectiveSettings.resolve(config: file, local: current)
        let mixed = SettingsRestorePlan.make(current: current, effective: effective)
        XCTAssertEqual(mixed.candidate.windowMoverEnabled, false)
        XCTAssertEqual(mixed.candidate.holdToTalkBindings, [.key(key: "h", modifiers: ["control"])])
        XCTAssertEqual(mixed.candidate.locale, "fr-FR")
        XCTAssertEqual(mixed.candidate.voiceEnabled, true)
        XCTAssertEqual(mixed.candidate.cancelBindings, BuiltInSettings.standard.cancelBindings)
        XCTAssertEqual(mixed.preservedManagedKeys, [.windowMoverEnabled, .holdToTalkShortcut, .locale])
    }

    func testRestoreDefaultsPublishesOneCompleteSnapshotAndPreservesManagedValues() async throws {
        actor Recorder {
            var snapshots: [EffectiveSettings] = []
            var persistedLocal: SettingsValues?
            func willPersist(_ local: SettingsValues) { persistedLocal = local }
            func published(_ effective: EffectiveSettings) { snapshots.append(effective) }
        }
        final class Box: @unchecked Sendable { var removed = false }
        let recorder = Recorder(), box = Box()
        var local = BuiltInSettings.standard.localSnapshot
        local.windowMoverEnabled = false
        local.voiceEnabled = false
        local.outputMode = .clipboardOnly
        local.historyEnabled = false
        local.locale = "fr-FR"
        local.inputDevicePriority = [.init(name: "Custom mic", uid: "custom")]
        let loader = ConfigReloader(local: local, read: { _ in
            if box.removed { throw CocoaError(.fileReadNoSuchFile) }
            return Data(#"{"version":1,"voice":{"locale":"de-DE"}}"#.utf8)
        })
        await loader.addApplyCallback { await recorder.published($0.effective) }
        _ = try await loader.reload()

        let restored = try await loader.restoreDefaults(current: local) {
            await recorder.willPersist($0.local)
        }
        let persistedCandidate = await recorder.persistedLocal
        let persisted = try XCTUnwrap(persistedCandidate)
        XCTAssertEqual(persisted, restored.local)
        XCTAssertTrue(restored.effective.windowMoverEnabled.value)
        XCTAssertTrue(restored.effective.voiceEnabled.value)
        XCTAssertEqual(restored.effective.outputMode.value, .pasteImmediately)
        XCTAssertTrue(restored.effective.historyEnabled.value)
        XCTAssertEqual(restored.effective.inputDevicePriority.value, [])
        XCTAssertEqual(restored.effective.locale.value, "de-DE")
        XCTAssertEqual(restored.local.locale, "fr-FR", "managed local shadow must be preserved")
        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.count, 2, "restore publishes exactly one complete snapshot")
        XCTAssertEqual(snapshots.last, restored.effective)

        box.removed = true
        let unmanaged = try await loader.reload()
        XCTAssertEqual(unmanaged.effective.locale.value, "fr-FR", "removing management must reveal the preserved custom value")
    }

    func testRestoreDefaultsRejectsWholeCandidateBeforePersistenceOrPublication() async throws {
        actor Counter {
            var publications = 0
            var persistenceAttempts = 0
            func published() { publications += 1 }
            func persisted() { persistenceAttempts += 1 }
        }
        let counter = Counter()
        var local = BuiltInSettings.standard.localSnapshot
        local.pasteLatestTranscriptShortcut = .key(key: "p", modifiers: ["command"])
        let json = #"{"version":1,"windowMover":{"shortcut":{"key":"v","modifiers":["control","command"]}}}"#
        let loader = ConfigReloader(local: local, read: { _ in Data(json.utf8) })
        await loader.addApplyCallback { _ in await counter.published() }
        let accepted = try await loader.reload()

        do {
            _ = try await loader.restoreDefaults(current: local) { _ in await counter.persisted() }
            XCTFail("conflicting complete restore was accepted")
        } catch {
            XCTAssertEqual(error as? ConfigDiagnostic,
                           .invalidValue(path: "voice.pasteLatestTranscriptShortcut", reason: "conflicts with windowMover.shortcut"))
        }
        let after = await loader.effective
        let publications = await counter.publications
        let persistenceAttempts = await counter.persistenceAttempts
        XCTAssertEqual(after, accepted.effective)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(persistenceAttempts, 0)
        let reloaded = try await loader.reload()
        XCTAssertEqual(reloaded.effective.pasteLatestTranscriptShortcut.value,
                       .key(key: "p", modifiers: ["command"]), "failed restore must retain the old local baseline")
    }

    func testRestorePersistenceFailureDoesNotPublishOrCommitLocalBaseline() async throws {
        actor Counter {
            var publications = 0
            func published() { publications += 1 }
        }
        let counter = Counter()
        var local = BuiltInSettings.standard.localSnapshot
        local.voiceEnabled = false
        let loader = ConfigReloader(local: local, read: { _ in throw CocoaError(.fileReadNoSuchFile) })
        await loader.addApplyCallback { _ in await counter.published() }
        _ = try await loader.reload()

        do {
            _ = try await loader.restoreDefaults(current: local) { _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("persistence failure was accepted")
        } catch {
            guard let diagnostic = error as? ConfigDiagnostic,
                  case .localPersistence = diagnostic else {
                return XCTFail("unexpected diagnostic: \(error)")
            }
        }
        let retained = await loader.effective
        let publications = await counter.publications
        XCTAssertFalse(retained.voiceEnabled.value)
        XCTAssertEqual(publications, 1)
        let reloaded = try await loader.reload()
        XCTAssertFalse(reloaded.effective.voiceEnabled.value)
    }

}
