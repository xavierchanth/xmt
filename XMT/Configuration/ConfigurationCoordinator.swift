import Combine
import Foundation
import KeyboardShortcuts
import OSLog

enum ConfigurationCoordinatorError: Error, Equatable {
    case notReady
}

/// Shell-owned configuration boundary. It is the sole owner of `ConfigReloader` and publishes
/// accepted cross-module snapshots on the main actor.
@MainActor
final class ConfigurationCoordinator: ObservableObject {
    static let shared = ConfigurationCoordinator(localSettings: .shared)

    @Published private(set) var diagnostic: String?
    @Published private(set) var effective = EffectiveSettings.resolve(config: nil)
    @Published private(set) var keyboardCommitIsActive = false

    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "Configuration")
    private let localSettings: LocalSettingsRepository
    private var reloader: ConfigReloader?
    private var registrationTask: Task<Void, Never>?
    private var hasPublishedConfiguration = false

    init(localSettings: LocalSettingsRepository) {
        self.localSettings = localSettings
    }

    func register() {
        guard registrationTask == nil else { return }
        registrationTask = Task { [weak self] in
            guard let self else { return }
            await self.configureAndReload()
        }
    }

    func reload() {
        Task { [weak self] in await self?.reloadNow() }
    }

    func stageAndReload(requiringUnmanaged actions: [VoiceBindingAction] = [],
                        beforePublish: ConfigReloader.BeforePublish? = nil,
                        updatingLocal update: (inout SettingsValues) -> Void) async throws -> ConfigLoadResult {
        var local = localSettings.snapshot()
        update(&local)
        guard let reloader else { throw ConfigurationCoordinatorError.notReady }
        do {
            let result = try await reloader.stageAndReload(
                local: local,
                requiringUnmanaged: actions,
                beforePublish: beforePublish
            )
            diagnostic = nil
            return result
        } catch {
            diagnostic = String(describing: error)
            throw error
        }
    }

    func report(_ message: String) {
        diagnostic = message
    }

    func reportIfEmpty(_ message: String) {
        if diagnostic == nil { diagnostic = message }
    }

    func clearDiagnostic() {
        diagnostic = nil
    }

    /// Single-flight editing uses the same validated publication transaction as shortcuts.
    func updateKeyboardSettings(_ update: (inout KeyboardCustomizationDTO) -> Void) async {
        guard !keyboardCommitIsActive else { return }
        keyboardCommitIsActive = true
        defer { keyboardCommitIsActive = false }
        let original = localSettings.snapshot().keyboardCustomization ?? .init()
        var proposed = original
        update(&proposed)
        let accepted = proposed
        do {
            _ = try await stageAndReload(beforePublish: { [weak self] result in
                guard let self else { throw ConfigurationCoordinatorError.notReady }
                try await self.persistKeyboardBeforePublish(result, original: original, accepted: accepted)
            }, updatingLocal: { $0.keyboardCustomization = accepted })
        } catch {
            diagnostic = String(describing: error)
        }
    }

    private func persistKeyboardBeforePublish(_ result: ConfigLoadResult, original: KeyboardCustomizationDTO,
                                             accepted: KeyboardCustomizationDTO) throws {
        guard result.effective.keyboardCustomization.permitsLocalChange(from: original, to: accepted) else {
            throw ConfigDiagnostic.invalidValue(path: "keyboardCustomization", reason: "This setting is now managed by configuration. Reload and try again.")
        }
        try localSettings.persistKeyboardSettings(accepted)
    }

    /// Settings callback that validates the cross-module collision boundary before the shared
    /// shortcut provider is reconfigured.
    func userChangedWindowMoverShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard localSettings.acceptWindowMoverShortcut(shortcut, effective: effective) else { return }
        reload()
    }

    func userChangedVoicePasteLatestShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard localSettings.acceptVoicePasteLatestShortcut(shortcut, effective: effective) else { return }
        reload()
    }

    private func configureAndReload() async {
        logger.notice("Resolving initial application configuration")
        let local = localSettings.snapshot()
        let loader = ConfigReloader(local: local, includesVoiceBindings: XMTBuildFeatures.voice)
        reloader = loader
        await loader.addApplyCallback { [weak self] result in
            await self?.publish(result.effective)
        }
        await reloadNow()
        if !hasPublishedConfiguration {
            // Invalid initial input must not leave modules unconfigured. No trigger starts until
            // the file has first been read and rejected atomically.
            publish(EffectiveSettings.resolve(config: nil, local: local))
        }
        await ModuleRegistry.shared.configurationDidBecomeReady()
        logger.notice("Initial application configuration resolved")
    }

    private func reloadNow() async {
        guard let reloader else { return }
        await reloader.updateLocal(localSettings.snapshot())
        do {
            _ = try await reloader.reload()
            diagnostic = nil
            logger.notice("Application configuration reloaded")
        } catch {
            diagnostic = String(describing: error)
            restoreShortcutStorageFromEffectiveSnapshot()
            logger.error("Application configuration reload failed")
        }
    }

    private func restoreShortcutStorageFromEffectiveSnapshot() {
        localSettings.restoreShortcutStorage(from: effective)
    }

    private func publish(_ value: EffectiveSettings) {
        hasPublishedConfiguration = true
        effective = value
        ModuleRegistry.shared.applyConfiguration(value)
        InputRoutingCoordinator.shared.applyConfiguration(value)
    }
}
