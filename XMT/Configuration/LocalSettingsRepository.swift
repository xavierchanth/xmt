import KeyboardShortcuts

struct WindowMoverLocalSettings: Equatable, Sendable {
    let enabled: Bool?
    let shortcut: ShortcutDTO?
}

struct VoiceLocalSettings: Equatable, Sendable {
    let enabled: Bool?
    let holdToTalkBindings: [ShortcutDTO]?
    let toggleRecordingBindings: [ShortcutDTO]?
    let cancelBindings: [ShortcutDTO]?
    let pasteLatestTranscriptShortcut: ShortcutDTO?
    let outputMode: VoiceOutputMode?
    let historyEnabled: Bool?
    let historyRetentionDays: Int?
    let historyMaxEntries: Int?
    let locale: String?
    let inputDevicePriority: [InputDeviceDTO]?
    let fallbackToSystemDefault: Bool?
}

@MainActor
protocol WindowMoverLocalSettingsAdapter: AnyObject {
    func readWindowMoverLocalSettings() -> WindowMoverLocalSettings
    func acceptUnmanagedWindowMoverShortcut(_ shortcut: KeyboardShortcuts.Shortcut?)
    func restoreUnmanagedWindowMoverShortcut()
    func restoreWindowMoverShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>)
}

@MainActor
protocol VoiceLocalSettingsAdapter: AnyObject {
    func readVoiceLocalSettings() -> VoiceLocalSettings
    func acceptUnmanagedVoicePasteLatestShortcut(_ shortcut: KeyboardShortcuts.Shortcut?)
    func restoreUnmanagedVoicePasteLatestShortcut()
    func restoreVoicePasteLatestShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>)
}

/// Shell-owned aggregate over module-specific preference boundaries. Modules remain responsible
/// for interpreting their own persisted representation; configuration sees only one value
/// snapshot and never reaches through one module to read or restore another module's state.
@MainActor
final class LocalSettingsRepository {
    private let windowMover: any WindowMoverLocalSettingsAdapter
    private let voice: any VoiceLocalSettingsAdapter

    init(windowMover: any WindowMoverLocalSettingsAdapter,
         voice: any VoiceLocalSettingsAdapter) {
        self.windowMover = windowMover
        self.voice = voice
    }

    func snapshot() -> SettingsValues {
        let window = windowMover.readWindowMoverLocalSettings()
        let voice = voice.readVoiceLocalSettings()
        return SettingsValues(
            windowMoverEnabled: window.enabled,
            windowMoverShortcut: window.shortcut,
            voiceEnabled: voice.enabled,
            holdToTalkBindings: voice.holdToTalkBindings,
            toggleRecordingBindings: voice.toggleRecordingBindings,
            cancelBindings: voice.cancelBindings,
            pasteLatestTranscriptShortcut: voice.pasteLatestTranscriptShortcut,
            outputMode: voice.outputMode,
            historyEnabled: voice.historyEnabled,
            historyRetentionDays: voice.historyRetentionDays,
            historyMaxEntries: voice.historyMaxEntries,
            locale: voice.locale,
            inputDevicePriority: voice.inputDevicePriority,
            fallbackToSystemDefault: voice.fallbackToSystemDefault
        )
    }

    /// Returns true when the candidate may be persisted and published. Rejected candidates restore
    /// the recorder immediately so library storage cannot diverge from the effective snapshot.
    func acceptWindowMoverShortcut(_ shortcut: KeyboardShortcuts.Shortcut?,
                                   effective: EffectiveSettings) -> Bool {
        guard !effective.windowMoverShortcut.isManaged else {
            windowMover.restoreWindowMoverShortcut(effective.windowMoverShortcut)
            return false
        }
        let activePasteShortcut = try? effective.pasteLatestTranscriptShortcut.value.keyboardShortcut()
        guard shortcut != activePasteShortcut else {
            windowMover.restoreUnmanagedWindowMoverShortcut()
            return false
        }
        windowMover.acceptUnmanagedWindowMoverShortcut(shortcut)
        return true
    }

    func acceptVoicePasteLatestShortcut(_ shortcut: KeyboardShortcuts.Shortcut?,
                                        effective: EffectiveSettings) -> Bool {
        guard !effective.pasteLatestTranscriptShortcut.isManaged else {
            voice.restoreVoicePasteLatestShortcut(effective.pasteLatestTranscriptShortcut)
            return false
        }
        let activeWindowShortcut = try? effective.windowMoverShortcut.value.keyboardShortcut()
        guard shortcut != activeWindowShortcut else {
            voice.restoreUnmanagedVoicePasteLatestShortcut()
            return false
        }
        voice.acceptUnmanagedVoicePasteLatestShortcut(shortcut)
        return true
    }

    func restoreShortcutStorage(from effective: EffectiveSettings) {
        windowMover.restoreWindowMoverShortcut(effective.windowMoverShortcut)
        voice.restoreVoicePasteLatestShortcut(effective.pasteLatestTranscriptShortcut)
    }
}
