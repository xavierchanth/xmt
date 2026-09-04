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
        VoiceTranscriptionModule.shared.register()
        logger.notice("Registered \(self.catalog.descriptors.count, privacy: .public) compiled-in modules")
    }

    func applyConfiguration(_ value: EffectiveSettings) {
        VoiceTranscriptionModule.shared.applyConfiguration(value)
        WindowMoverModule.shared.applyManaged(
            enabled: value.windowMoverEnabled,
            shortcut: value.windowMoverShortcut
        )
    }

    func applicationDidBecomeActive() {
        VoiceTranscriptionModule.shared.refreshDevices()
    }

    func configurationDidBecomeReady() async {
        await VoiceTranscriptionModule.shared.completeInitialConfiguration()
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
        VoiceTranscriptionModule.shared.stop()
        hasRegistered = false
    }
}
