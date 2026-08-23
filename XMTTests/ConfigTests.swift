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
        let file = try decode(#"{"version":1,"windowMover":{"enabled":false},"voice":{"locale":"fr-FR","inputDevicePriority":[],"fallbackToSystemDefault":false}}"#)
        var local = SettingsValues(); local.autoPaste = false; local.locale = "de-DE"; local.fallbackToSystemDefault = true
        let result = EffectiveSettings.resolve(config: file, local: local)
        XCTAssertEqual(result.windowMoverEnabled.source, .configFile)
        XCTAssertTrue(result.windowMoverEnabled.isManaged)
        XCTAssertEqual(result.locale.value, "fr-FR"); XCTAssertEqual(result.locale.source, .configFile)
        XCTAssertEqual(result.autoPaste.value, false); XCTAssertEqual(result.autoPaste.source, .local); XCTAssertFalse(result.autoPaste.isManaged)
        XCTAssertEqual(result.voiceEnabled.source, .builtIn)
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

    func testUnsupportedMalformedAndInvalidKnownValues() {
        XCTAssertThrowsError(try decode(#"{"version":2}"#)) { XCTAssertEqual($0 as? ConfigDiagnostic, .unsupportedVersion(2)) }
        XCTAssertThrowsError(try decode("{"))
        for body in [
            #"{"version":1,"voice":{"fnHoldThresholdMs":49}}"#,
            #"{"version":1,"voice":{"fnHoldThresholdMs":501}}"#,
            #"{"version":1,"voice":{"maxSessionSeconds":0}}"#,
            #"{"version":1,"voice":{"maxSessionSeconds":3601}}"#,
            #"{"version":1,"voice":{"locale":"  "}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":" "}]}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":"Mic","uid":" "}]}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":"Mic","uid":" ABC "},{"name":"Other","uid":"abc"}]}}"#,
            #"{"version":1,"voice":{"inputDevicePriority":[{"name":" Mic "},{"name":"mic"}]}}"#,
            #"{"version":1,"windowMover":{"shortcut":{"modifier":"fn"}}}"#
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
        XCTAssertEqual(result.changedKeys, [.voiceEnabled, .autoPaste])
        XCTAssertTrue(result.effective.voiceEnabled.value); XCTAssertEqual(result.effective.voiceEnabled.source, .local)
        XCTAssertTrue(result.effective.autoPaste.value); XCTAssertEqual(result.effective.autoPaste.source, .builtIn)
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
}
