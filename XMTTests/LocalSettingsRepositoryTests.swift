import KeyboardShortcuts
import XCTest

@MainActor
final class LocalSettingsRepositoryTests: XCTestCase {
    func testSnapshotComposesModuleOwnedValues() {
        let window = WindowAdapter(
            settings: .init(enabled: false, shortcut: .key(key: "m", modifiers: ["command"]))
        )
        let voice = VoiceAdapter(settings: voiceSettings(enabled: true, locale: "fr-FR"))
        let snapshot = LocalSettingsRepository(windowMover: window, voice: voice).snapshot()

        XCTAssertEqual(snapshot.windowMoverEnabled, false)
        XCTAssertEqual(snapshot.windowMoverShortcut, .key(key: "m", modifiers: ["command"]))
        XCTAssertEqual(snapshot.voiceEnabled, true)
        XCTAssertEqual(snapshot.locale, "fr-FR")
    }

    func testManagedAndConflictingWindowShortcutsAreRejectedAndRestored() throws {
        let window = WindowAdapter(settings: .init(enabled: nil, shortcut: nil))
        let voice = VoiceAdapter(settings: voiceSettings())
        let repository = LocalSettingsRepository(windowMover: window, voice: voice)
        let managed = try ConfigFile.decode(Data(#"{"version":1,"windowMover":{"shortcut":{"key":"m","modifiers":["command"]}}}"#.utf8))
        let managedEffective = EffectiveSettings.resolve(config: managed)

        XCTAssertFalse(repository.acceptWindowMoverShortcut(nil, effective: managedEffective))
        XCTAssertEqual(window.restoredManaged, [managedEffective.windowMoverShortcut])

        let localEffective = EffectiveSettings.resolve(config: nil)
        let paste = try localEffective.pasteLatestTranscriptShortcut.value.keyboardShortcut()
        XCTAssertFalse(repository.acceptWindowMoverShortcut(paste, effective: localEffective))
        XCTAssertEqual(window.unmanagedRestoreCount, 1)

        let accepted = KeyboardShortcuts.Shortcut(.k, modifiers: [.command])
        XCTAssertTrue(repository.acceptWindowMoverShortcut(accepted, effective: localEffective))
        XCTAssertEqual(window.accepted, [accepted])
    }

    func testRestoreShortcutStorageDelegatesToBothOwners() {
        let window = WindowAdapter(settings: .init(enabled: nil, shortcut: nil))
        let voice = VoiceAdapter(settings: voiceSettings())
        let repository = LocalSettingsRepository(windowMover: window, voice: voice)
        let effective = EffectiveSettings.resolve(config: nil)

        repository.restoreShortcutStorage(from: effective)

        XCTAssertEqual(window.restoredManaged, [effective.windowMoverShortcut])
        XCTAssertEqual(voice.restoredPaste, [effective.pasteLatestTranscriptShortcut])
    }

    func testManagedAndConflictingVoicePasteShortcutsAreRejectedAndRestored() throws {
        let window = WindowAdapter(settings: .init(enabled: nil, shortcut: nil))
        let voice = VoiceAdapter(settings: voiceSettings())
        let repository = LocalSettingsRepository(windowMover: window, voice: voice)
        let managed = try ConfigFile.decode(Data(#"{"version":1,"voice":{"pasteLatestTranscriptShortcut":{"key":"p","modifiers":["command"]}}}"#.utf8))
        let managedEffective = EffectiveSettings.resolve(config: managed)

        XCTAssertFalse(repository.acceptVoicePasteLatestShortcut(nil, effective: managedEffective))
        XCTAssertEqual(voice.restoredPaste, [managedEffective.pasteLatestTranscriptShortcut])

        let localEffective = EffectiveSettings.resolve(config: nil)
        let windowShortcut = try localEffective.windowMoverShortcut.value.keyboardShortcut()
        XCTAssertFalse(repository.acceptVoicePasteLatestShortcut(windowShortcut, effective: localEffective))
        XCTAssertEqual(voice.unmanagedRestoreCount, 1)

        let accepted = KeyboardShortcuts.Shortcut(.p, modifiers: [.command])
        XCTAssertTrue(repository.acceptVoicePasteLatestShortcut(accepted, effective: localEffective))
        XCTAssertEqual(voice.accepted, [accepted])
    }

    private func voiceSettings(enabled: Bool? = nil, locale: String? = nil) -> VoiceLocalSettings {
        .init(
            enabled: enabled,
            holdToTalkBindings: nil,
            toggleRecordingBindings: nil,
            cancelBindings: nil,
            pasteLatestTranscriptShortcut: nil,
            outputMode: nil,
            historyEnabled: nil,
            historyRetentionDays: nil,
            historyMaxEntries: nil,
            locale: locale,
            inputDevicePriority: nil,
            fallbackToSystemDefault: nil
        )
    }
}

@MainActor
private final class WindowAdapter: WindowMoverLocalSettingsAdapter {
    let settings: WindowMoverLocalSettings
    var accepted: [KeyboardShortcuts.Shortcut?] = []
    var unmanagedRestoreCount = 0
    var restoredManaged: [ResolvedSetting<ShortcutDTO>] = []

    init(settings: WindowMoverLocalSettings) { self.settings = settings }

    func readWindowMoverLocalSettings() -> WindowMoverLocalSettings { settings }
    func acceptUnmanagedWindowMoverShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) { accepted.append(shortcut) }
    func restoreUnmanagedWindowMoverShortcut() { unmanagedRestoreCount += 1 }
    func restoreWindowMoverShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>) { restoredManaged.append(shortcut) }
}

@MainActor
private final class VoiceAdapter: VoiceLocalSettingsAdapter {
    let settings: VoiceLocalSettings
    var accepted: [KeyboardShortcuts.Shortcut?] = []
    var unmanagedRestoreCount = 0
    var restoredPaste: [ResolvedSetting<ShortcutDTO>] = []

    init(settings: VoiceLocalSettings) { self.settings = settings }

    func readVoiceLocalSettings() -> VoiceLocalSettings { settings }
    func acceptUnmanagedVoicePasteLatestShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) { accepted.append(shortcut) }
    func restoreUnmanagedVoicePasteLatestShortcut() { unmanagedRestoreCount += 1 }
    func restoreVoicePasteLatestShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>) { restoredPaste.append(shortcut) }
}
