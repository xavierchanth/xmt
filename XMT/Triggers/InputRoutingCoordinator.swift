import KeyboardShortcuts
import OSLog

/// Main-actor interpreter that maps shared provider output to compiled-in module actions.
@MainActor
final class InputRoutingCoordinator {
    static let shared = InputRoutingCoordinator()

    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "InputRouting")
    private lazy var standardProvider = StandardShortcutProvider { [weak self] event in
        self?.dispatch(event)
    }
    private var voicePolicy = VoiceShortcutActivationPolicy.decide(moduleEnabled: false, phase: .unavailable)
    private var voiceEnabled = false
    private var captureIsActive = false
    private var windowEnabled = false
    private var voiceSources: [VoiceBindingAction: Set<InputSourceID>] = [:]
    private var pasteLatestSources: Set<InputSourceID> = []
    private var windowSources: Set<InputSourceID> = []

    private init() {}

    func applyConfiguration(_ value: EffectiveSettings) {
        voiceEnabled = XMTBuildFeatures.voice && value.voiceEnabled.value
        windowEnabled = value.windowMoverEnabled.value
        var registrations: [StandardShortcutRegistration] = []
        voiceSources.removeAll()
        pasteLatestSources.removeAll()
        windowSources.removeAll()

        if case .key = value.windowMoverShortcut.value,
           let source = InputSourceID("standard.window-mover.move") {
            windowSources.insert(source)
            registrations.append(.init(
                name: .moveToNextScreen,
                route: .init(source: source, action: .moveWindowToNextScreen, activation: .release,
                             chord: value.windowMoverShortcut.value),
                isEnabled: windowEnabled
            ))
        }

        if XMTBuildFeatures.voice, case .key = value.pasteLatestTranscriptShortcut.value,
           let source = InputSourceID("standard.voice.paste-latest") {
            pasteLatestSources.insert(source)
            registrations.append(.init(
                name: .pasteLatestTranscript,
                route: .init(source: source, action: .voicePasteLatest, activation: .release,
                             chord: value.pasteLatestTranscriptShortcut.value),
                isEnabled: voiceEnabled
            ))
        }

        if XMTBuildFeatures.voice {
            appendVoiceRegistrations(value.holdToTalkBindings.value, action: .holdToTalk,
                                     target: .voiceHoldToTalk, activation: .hold, into: &registrations)
            appendVoiceRegistrations(value.toggleRecordingBindings.value, action: .toggleRecording,
                                     target: .voiceToggleRecording, activation: .press, into: &registrations)
            appendVoiceRegistrations(value.cancelBindings.value, action: .cancel,
                                     target: .voiceCancel, activation: .press, into: &registrations)
        }

        do {
            try standardProvider.reconcile(registrations)
            reconcileActivation()
        } catch {
            logger.error("Rejected internally inconsistent standard shortcut routes")
            standardProvider.stop()
        }
    }

    func setWindowEnabled(_ enabled: Bool) {
        windowEnabled = enabled
        standardProvider.setEnabled(enabled, sources: windowSources,
                                    interruption: enabled ? nil : .moduleStopped(.windowMover))
    }

    func setVoiceActivation(moduleEnabled: Bool, policy: VoiceShortcutActivationPolicy,
                            captureIsActive: Bool) {
        voiceEnabled = moduleEnabled
        voicePolicy = policy
        self.captureIsActive = captureIsActive
        reconcileActivation()
    }

    func stop() {
        standardProvider.stop()
    }

    private func appendVoiceRegistrations(_ bindings: [ShortcutDTO], action: VoiceBindingAction,
                                          target: ModuleActionID, activation: ActionActivation,
                                          into registrations: inout [StandardShortcutRegistration]) {
        for (index, binding) in bindings.enumerated() where index < KeyboardShortcuts.Name.voiceBindingSlotCount {
            guard case .key = binding,
                  let source = InputSourceID("standard.voice.\(action.rawValue).\(index)") else { continue }
            voiceSources[action, default: []].insert(source)
            registrations.append(.init(
                name: .voiceBindingSlot(action: action, index: index),
                route: .init(source: source, action: target, activation: activation, chord: binding),
                isEnabled: voiceActionIsEnabled(action)
            ))
        }
    }

    private func reconcileActivation() {
        let interrupted = !voiceEnabled || captureIsActive
        let interruption: InputInterruption = captureIsActive
            ? .captureBegan
            : (!voiceEnabled ? .moduleStopped(.voiceTranscription) : .activationChanged)
        for action in VoiceBindingAction.allCases {
            standardProvider.setEnabled(
                !interrupted && voiceActionIsEnabled(action),
                sources: voiceSources[action] ?? [],
                interruption: interruption
            )
        }
        standardProvider.setEnabled(voiceEnabled && !captureIsActive,
                                    sources: pasteLatestSources,
                                    interruption: interruption)
        standardProvider.setEnabled(windowEnabled, sources: windowSources)
    }

    private func voiceActionIsEnabled(_ action: VoiceBindingAction) -> Bool {
        switch action {
        case .holdToTalk: voicePolicy.holdEnabled
        case .toggleRecording: voicePolicy.toggleEnabled
        case .cancel: voicePolicy.cancelEnabled
        }
    }

    private func dispatch(_ event: SemanticActionEvent) {
        ModuleRegistry.shared.dispatch(event)
    }
}
