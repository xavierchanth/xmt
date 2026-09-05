import OSLog

/// Effectful registry for the fixed set of modules compiled into XMT. It is the only shell type
/// that knows which concrete module implements a semantic action.
@MainActor
final class ModuleRegistry {
    static let shared = ModuleRegistry()

    let catalog = XMTModuleCatalog.builtIn
    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "Modules")
    private var hasRegistered = false

    private init() {}

    func register() {
        guard !hasRegistered else { return }
        hasRegistered = true
        WindowMoverModule.shared.register()
        if XMTBuildFeatures.voice { VoiceTranscriptionModule.shared.register() }
        logger.notice("Registered \(self.catalog.descriptors.count, privacy: .public) compiled-in modules")
    }

    func applyConfiguration(_ value: EffectiveSettings) {
        if XMTBuildFeatures.voice { VoiceTranscriptionModule.shared.applyConfiguration(value) }
        WindowMoverModule.shared.applyManaged(
            enabled: value.windowMoverEnabled,
            shortcut: value.windowMoverShortcut
        )
    }

    func applicationDidBecomeActive() {
        if XMTBuildFeatures.voice { VoiceTranscriptionModule.shared.refreshDevices() }
    }

    func configurationDidBecomeReady() async {
        if XMTBuildFeatures.voice { await VoiceTranscriptionModule.shared.completeInitialConfiguration() }
    }

    func dispatch(_ event: SemanticActionEvent) {
        guard hasRegistered else { return }
        guard catalog.descriptor(for: event.action.module)?.actions.contains(event.action) == true else {
            logger.error("Rejected an action absent from the compiled-in module catalog")
            return
        }
        switch event {
        case .invoked(.moveWindowToNextScreen):
            WindowMoverModule.shared.performRoutedAction()
        case .invoked(.voicePasteLatest):
            VoiceTranscriptionModule.shared.pasteLatestTranscript()
        case .invoked(.voiceToggleRecording):
            VoiceTranscriptionModule.shared.handleStandardBindingEvent(.toggleRequested)
        case .invoked(.voiceCancel):
            VoiceTranscriptionModule.shared.handleStandardBindingEvent(.cancelRequested)
        case .began(.voiceHoldToTalk):
            VoiceTranscriptionModule.shared.handleStandardBindingEvent(.holdBegan)
        case .ended(.voiceHoldToTalk, _):
            VoiceTranscriptionModule.shared.handleStandardBindingEvent(.holdEnded)
        default:
            break
        }
    }

    func stopAll() {
        WindowMoverModule.shared.stop()
        if XMTBuildFeatures.voice { VoiceTranscriptionModule.shared.stop() }
        hasRegistered = false
    }
}
