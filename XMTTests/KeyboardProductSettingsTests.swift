import XCTest

final class KeyboardProductSettingsTests: XCTestCase {
    private func device(_ id: String = "desk") -> KeyboardCustomizationDTO.Device {
        .init(id: id, identity: .init(builtIn: false, vendorID: 10, productID: 20,
                                     serialNumber: id, locationID: nil, transport: nil))
    }

    func testDefaultOffAndEmptyDeviceScope() throws {
        let value = EffectiveKeyboardCustomizationSettings.resolve()
        XCTAssertFalse(value.hyperEnabled.value)
        XCTAssertFalse(value.homeRowEnabled.value)
        XCTAssertTrue(value.devices.isEmpty)
        let policy = try KeyboardProductPolicyCompiler.compile(value, revision: KeyboardPolicyRevision(1)!)
        XCTAssertTrue(policy.configuration.devices.isEmpty)
    }

    func testProductMappingsAndTimingAreCompiled() throws {
        var profile = device()
        profile.hyperHoldMs = 175; profile.homeRowHoldMs = 250; profile.homeRowQuickTapMs = 125
        profile.keyTiming = ["a": .init(holdMs: 300, quickTapMs: 90)]
        let settings = EffectiveKeyboardCustomizationSettings.resolve(local: .init(hyperEnabled: true, homeRowEnabled: true, devices: [profile]))
        let policy = try KeyboardProductPolicyCompiler.compile(settings, revision: KeyboardPolicyRevision(1)!)
        let configuration = try XCTUnwrap(policy.configuration.devices[KeyboardDeviceID("desk")])
        XCTAssertTrue(configuration.productSemantics)
        let keys = configuration.keys
        XCTAssertEqual(keys.count, 9)
        XCTAssertEqual(keys[KeyCode(0x39)]?.tap, KeyCode(0x29))
        XCTAssertEqual(keys[KeyCode(0x39)]?.hold, .hyper)
        XCTAssertEqual(keys[KeyCode(0x39)]?.timing, .init(holdMilliseconds: 175, quickTapMilliseconds: 0, rollover: .otherKeyPress))
        XCTAssertEqual(keys[KeyCode(0x04)]?.timing, .init(holdMilliseconds: 300, quickTapMilliseconds: 90))
        let pairs: [(UInt16, ModifierSet)] = [(0x04, .control), (0x33, .control), (0x16, .shift), (0x0F, .shift), (0x07, .option), (0x0E, .option), (0x09, .command), (0x0D, .command)]
        for (usage, modifier) in pairs {
            XCTAssertEqual(keys[KeyCode(usage)]?.hold, modifier)
            XCTAssertEqual(keys[KeyCode(usage)]?.tap, KeyCode(usage))
        }
    }

    func testMembershipIsAtomicAndIdentityMustMatchForLocalTiming() {
        var local = device(); local.homeRowHoldMs = 300
        let file = device()
        let resolved = EffectiveKeyboardCustomizationSettings.resolve(file: .init(devices: [file]), local: .init(devices: [local, device("other")]))
        XCTAssertEqual(resolved.devices.map(\.id), ["desk"])
        XCTAssertEqual(resolved.devices.first?.homeRowHoldMs.value, 300)
        local.identity = device("different").identity
        let mismatched = EffectiveKeyboardCustomizationSettings.resolve(file: .init(devices: [file]), local: .init(devices: [local]))
        XCTAssertEqual(mismatched.devices.first?.homeRowHoldMs.value, 200)
        XCTAssertTrue(EffectiveKeyboardCustomizationSettings.resolve(file: .init(devices: []), local: .init(devices: [local])).devices.isEmpty)
    }

    func testManagedDeviceTimingCannotBeBypassedByLocalKeyOverride() {
        var file = device(); file.homeRowHoldMs = 400
        var local = device(); local.keyTiming = ["a": .init(holdMs: 100)]
        let result = EffectiveKeyboardCustomizationSettings.resolve(file: .init(devices: [file]), local: .init(devices: [local]))
        XCTAssertEqual(result.devices.first?.keyTiming[.a]?.holdMs.value, 400)
        XCTAssertEqual(result.devices.first?.keyTiming[.a]?.holdMs.source, .configFile)
        XCTAssertEqual(EffectiveKeyboardCustomizationSettings.resolve(local: .init(devices: [local])).devices.first?.keyTiming[.a]?.holdMs.value, 100)
    }

    func testMalformedTimingsAndPositionsRejectedEvenWhenDisabled() {
        var value = device(); value.homeRowHoldMs = 0
        XCTAssertThrowsError(try KeyboardCustomizationDTO(devices: [value]).validate())
        value.homeRowHoldMs = nil; value.keyTiming = ["capsLock": .init(quickTapMs: 0)]
        XCTAssertThrowsError(try KeyboardCustomizationDTO(devices: [value]).validate())
        value.keyTiming = ["unknown": .init(holdMs: 200)]
        XCTAssertThrowsError(try KeyboardCustomizationDTO(devices: [value]).validate())
        value.keyTiming = nil; value.homeRowQuickTapMs = 60_001
        XCTAssertThrowsError(try KeyboardCustomizationDTO(devices: [value]).validate())
    }

    func testManagedEditGuardRechecksNewFileSnapshot() {
        let old = KeyboardCustomizationDTO(homeRowEnabled: false, devices: [device()])
        var proposed = old; proposed.homeRowEnabled = true
        let managed = EffectiveKeyboardCustomizationSettings.resolve(file: .init(homeRowEnabled: true), local: proposed)
        XCTAssertFalse(managed.permitsLocalChange(from: old, to: proposed))
        XCTAssertTrue(EffectiveKeyboardCustomizationSettings.resolve(local: proposed).permitsLocalChange(from: old, to: proposed))
    }

    func testDeviceRemovedByNewFileCannotAcceptStaleTimingEdit() {
        let original = KeyboardCustomizationDTO(devices: [device()])
        var changed = device(); changed.hyperHoldMs = 350
        let proposed = KeyboardCustomizationDTO(devices: [changed])
        let resolved = EffectiveKeyboardCustomizationSettings.resolve(file: .init(devices: []), local: proposed)
        XCTAssertFalse(resolved.permitsLocalChange(from: original, to: proposed))
    }

    func testInvalidReloadDoesNotPublishKeyboardChanges() async throws {
        let valid = ConfigFile(version: 1, keyboardCustomization: .init(hyperEnabled: true, devices: [device()]))
        let loader = ConfigReloader(read: { _ in try JSONEncoder().encode(valid) })
        let initial = try await loader.reload()
        var invalid = SettingsValues(); var profile = device(); profile.hyperHoldMs = -1
        invalid.keyboardCustomization = .init(devices: [profile])
        do { _ = try await loader.stageAndReload(local: invalid); XCTFail("expected rejection") } catch {}
        let effective = await loader.effective
        XCTAssertEqual(effective, initial.effective)
    }

    @MainActor
    func testPreferenceRoundTripAndRejectedWritePreservesLastGoodValue() throws {
        let name = "KeyboardProductSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = KeyboardSettingsStore(defaults: defaults)
        let original = KeyboardCustomizationDTO(hyperEnabled: true, devices: [device()])
        try store.persistKeyboardLocalSettings(original)
        XCTAssertEqual(store.readKeyboardLocalSettings(), original)
        var bad = device(); bad.homeRowHoldMs = 0
        XCTAssertThrowsError(try store.persistKeyboardLocalSettings(.init(devices: [bad])))
        XCTAssertEqual(store.readKeyboardLocalSettings(), original)
    }
}
