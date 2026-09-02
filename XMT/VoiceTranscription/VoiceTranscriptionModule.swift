import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Foundation
import KeyboardShortcuts

/// Main-actor lifecycle and effect coordinator for Voice Transcription.
@MainActor
final class VoiceTranscriptionModule: ObservableObject {
    static let shared = VoiceTranscriptionModule()

    enum Status: Equatable {
        case disabled, idle, arming, recording, finalizing, pending, noSpeech, pasteFailed(String), degraded(String), failed(String)
    }

    @Published private(set) var status: Status = .disabled { didSet { updateOverlay(); reconcileShortcutActivation() } }
    @Published private(set) var partialTranscript = "" { didSet { updateOverlay() } }
    @Published private(set) var lastTranscript = ""
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published private(set) var assetStatus = "Not checked"
    @Published private(set) var supportedLocaleIdentifiers: [String] = []
    @Published private(set) var configDiagnostic: String?
    @Published private(set) var managedKeys: Set<EffectiveSettings.Key> = []
    @Published private(set) var temporaryFeedback: String?
    @Published var isEnabled: Bool { didSet { persistAndReconfigure("voice.enabled", isEnabled) } }
    @Published var outputMode: VoiceOutputMode { didSet { persist("voice.outputMode", outputMode.rawValue); updateOverlay() } }
    // History settings take effect when changed, not at the next configuration reload: turning
    // history off must silence the surfaces immediately rather than after the next launch.
    @Published var historyEnabled: Bool {
        didSet { persist(VoiceHistoryPreferences.enabledKey, historyEnabled); applyLocalHistoryEnabled() }
    }
    @Published var historyRetentionDays: Int {
        didSet { persist(VoiceHistoryPreferences.retentionDaysKey, historyRetentionDays); applyLocalHistoryRetention() }
    }
    @Published var historyMaxEntries: Int {
        didSet { persist(VoiceHistoryPreferences.maxEntriesKey, historyMaxEntries); applyLocalHistoryRetention() }
    }
    @Published var fallbackToSystemDefault: Bool { didSet { persist("voice.fallback", fallbackToSystemDefault) } }
    @Published var localeIdentifier: String { didSet { persist("voice.locale", localeIdentifier) } }
    @Published var devicePriority: [InputDeviceDTO] { didSet { saveDevices() } }

    private var machine = VoiceSessionMachine()
    private var observer: FnEventObserver?
    private var observation: FnEventObserver.Observation?
    private var observerThresholdMs: Int?
    private var observerHoldBinding: ShortcutDTO?
    private var capture: AudioCaptureService?
    private var transcriber: TranscriberSession?
    private var transcriberResolvedLocaleIdentifier: String?
    private var analysisTask: Task<Error?, Never>?
    private var armTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var captureTeardownTask: Task<Void, Never>?
    private var cancellationCleanupTask: Task<Void, Never>?
    private var armGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var secureInputSessions: Set<UUID> = []
    private var maxTimer: Timer?
    private var pasteTarget: CapturedPasteTarget?
    private let store = PendingRecordingStore()
    private let assets = VoiceAssetManager()
    private var effective = EffectiveSettings.resolve(config: nil)
    private var reloader: ConfigReloader?
    private var applying = false
    private var hasAppliedConfiguration = false
    /// History remains unpublished until the first effective configuration and startup prune finish.
    private var hasResolvedInitialHistory = false
    private var isPasteLatestHandlerInstalled = false
    private var unmanagedHoldShortcut: ShortcutDTO?
    private var unmanagedToggleShortcut: ShortcutDTO?
    private var unmanagedCancelShortcut: ShortcutDTO?
    private var unmanagedPasteLatestShortcut: KeyboardShortcuts.Shortcut?
    private var unmanagedWindowMoverShortcut: KeyboardShortcuts.Shortcut?
    private var feedbackGeneration: UInt64 = 0
    private var assetStatusGeneration: UInt64 = 0
    private var assetProgressObservation: NSKeyValueObservation?
    private var isPastingLatest = false
    private var historyLatestObserver: NSObjectProtocol?
    private static let pasteLatestShortcutBackupActiveKey = "voice.pasteLatestShortcutBackupActive"
    private static let pasteLatestShortcutBackupDataKey = "voice.pasteLatestShortcutBackupData"

    var persistedPasteLatestTranscriptShortcut: ShortcutDTO? {
        unmanagedPasteLatestShortcut.flatMap(ShortcutDTO.fromKeyboardShortcut)
    }

    private init() {
        let d = UserDefaults.standard
        // Migration must precede registration: registered values participate in
        // `object(forKey:)` and would otherwise look like persisted canonical data.
        VoiceHistoryPreferences.migrate(in: d)
        d.register(defaults: ["voice.enabled": true, "voice.outputMode": VoiceOutputMode.pasteImmediately.rawValue,
                              "voice.fallback": true, "voice.locale": "system"]
            .merging(VoiceHistoryPreferences.registeredDefaults) { current, _ in current })
        isEnabled = d.bool(forKey: "voice.enabled"); outputMode = VoiceOutputMode(rawValue: d.string(forKey: "voice.outputMode") ?? "") ?? (d.object(forKey: "voice.autoPaste") == nil || d.bool(forKey: "voice.autoPaste") ? .pasteImmediately : .clipboardOnly)
        historyEnabled = d.bool(forKey: VoiceHistoryPreferences.enabledKey)
        historyRetentionDays = d.integer(forKey: VoiceHistoryPreferences.retentionDaysKey)
        historyMaxEntries = d.integer(forKey: VoiceHistoryPreferences.maxEntriesKey)
        fallbackToSystemDefault = d.bool(forKey: "voice.fallback")
        localeIdentifier = d.string(forKey: "voice.locale") ?? "system"
        devicePriority = (d.data(forKey: "voice.devices").flatMap { try? JSONDecoder().decode([InputDeviceDTO].self, from: $0) }) ?? []
        if d.bool(forKey: Self.pasteLatestShortcutBackupActiveKey) {
            unmanagedPasteLatestShortcut = Self.loadPasteLatestShortcutBackup()
        } else {
            unmanagedPasteLatestShortcut = KeyboardShortcuts.getShortcut(for: .pasteLatestTranscript)
        }
        unmanagedWindowMoverShortcut = KeyboardShortcuts.getShortcut(for: .moveToNextScreen)
        unmanagedHoldShortcut = Self.localVoiceBinding(.voiceHoldToTalk, key: "hold")
        unmanagedToggleShortcut = Self.localVoiceBinding(.voiceToggleRecording, key: "toggle")
        unmanagedCancelShortcut = Self.localVoiceBinding(.voiceCancel, key: "cancel")
    }

    func register() {
        reconcileRecovery()
        registerPasteLatestShortcut()
        if historyLatestObserver == nil {
            historyLatestObserver = NotificationCenter.default.addObserver(
                forName: .transcriptHistoryLatestChanged, object: nil, queue: .main
            ) { [weak self] note in
                Task { @MainActor in self?.lastTranscript = note.object as? String ?? "" }
            }
        }
        // One authoritative launch task. Surfaces are born disabled and remain inert until managed
        // configuration is resolved and enabled storage has been opened and pruned.
        Task { await configureAndReload() }
    }

    /// Applies legacy retention only after effective configuration has resolved. Enabled history is
    /// part of durable commit semantics; disabled history performs plaintext cleanup without ever
    /// resolving the lazy SQLite provider and never touches recovery audio.
    private func reconcileLegacyTranscriptForEffectiveHistory() async {
        let directory = store.root
        do {
            let reconciliation = try await LegacyTranscriptImport.reconcileAfterConfiguration(
                enabled: historyEnabled, directory: directory, localeIdentifier: localeIdentifier,
                retention: historyRetentionPolicy,
                openStore: { try SharedTranscriptHistoryStore.shared(retention: historyRetentionPolicy) })
            lastTranscript = reconciliation.newest?.text ?? ""
            // A migration that could not read the old cache is reported as such. History itself
            // opened and loaded, so it must not be described as unavailable.
            if let migration = reconciliation.migrationDiagnostic {
                configDiagnostic = configDiagnostic ?? migration
            }
        } catch {
            configDiagnostic = configDiagnostic ?? (historyEnabled
                ? "Transcript history is unavailable" : "Legacy transcript cleanup failed")
        }
    }

    func stop() {
        lifecycleGeneration &+= 1
        armGeneration &+= 1
        observer?.setRecordingActive(false)
        observation?.cancel(); observation = nil; observer = nil; observerThresholdMs = nil; observerHoldBinding = nil
        maxTimer?.invalidate(); maxTimer = nil
        let activeCapture = capture
        capture = nil
        armTask?.cancel(); armTask = nil
        analysisTask?.cancel(); analysisTask = nil
        finalizationTask?.cancel(); finalizationTask = nil
        retryTask?.cancel(); retryTask = nil
        let sessionTranscriber = transcriber
        transcriber = nil
        if sessionTranscriber != nil { Task { await sessionTranscriber?.cancel() } }
        secureInputSessions.removeAll()
        partialTranscript = ""
        if let activeCapture, captureTeardownTask == nil {
            captureTeardownTask = Task { [weak self] in
                guard let self else { return }
                await activeCapture.stopAndWait()
                let pending = ((try? store.loadPending()) ?? nil)
                    ?? (try? store.promoteActive(failureReason: "module stopped"))
                if let pending {
                    machine = VoiceSessionMachine()
                    _ = machine.handle(.recovered(.init(id: pending.metadata.sessionID, audioURL: pending.audioURL)))
                    status = .pending
                }
                captureTeardownTask = nil
            }
        }
        KeyboardShortcuts.disable(.pasteLatestTranscript)
        KeyboardShortcuts.disable(.voiceHoldToTalk); KeyboardShortcuts.disable(.voiceToggleRecording); KeyboardShortcuts.disable(.voiceCancel)
        if status != .pending { machine = VoiceSessionMachine(); status = .disabled }
    }

    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in if granted { self?.recoverDegradedAndObserve() } }
        }
        if CGRequestListenEventAccess() { recoverDegradedAndObserve() }
        AccessibilityService.shared.requestIfNeeded()
        BluetoothLinkOracle.requestAccessContextually()
    }

    func refreshDevices() {
        availableDevices = (try? DeviceTable().inputDevices())?.filter(\.hasInput) ?? []
    }

    var effectiveHoldUsesFn: Bool { if case .modifierHold = effective.holdToTalkShortcut.value { return true }; return false }

    func refreshLocalesAndAssets() {
        Task { supportedLocaleIdentifiers = await assets.supportedLocales().map(\.identifier).sorted(); refreshAssets() }
    }

    func refreshAssets() {
        assetStatusGeneration &+= 1
        let generation = assetStatusGeneration
        let locale = requestedLocale
        Task {
            let result = describe(await assets.status(locale: locale))
            guard generation == assetStatusGeneration, locale.identifier == requestedLocale.identifier else { return }
            assetStatus = result
        }
    }
    func downloadAssets() {
        assetStatusGeneration &+= 1
        let generation = assetStatusGeneration
        let locale = requestedLocale
        assetStatus = "Downloading"
        Task {
            let result = describe(await assets.install(locale: locale) { [weak self] progress in
                Task { @MainActor in self?.observeAssetProgress(progress, generation: generation) }
            })
            guard generation == assetStatusGeneration, locale.identifier == requestedLocale.identifier else { return }
            assetProgressObservation = nil; assetStatus = result
        }
    }

    private func observeAssetProgress(_ progress: Progress, generation: UInt64) {
        assetProgressObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            Task { @MainActor in
                guard let self, generation == self.assetStatusGeneration else { return }
                self.assetStatus = "Downloading \(Int(progress.fractionCompleted * 100))%"
            }
        }
    }

    func copyLastTranscript() { guard !lastTranscript.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastTranscript, forType: .string) }

    func pasteLatestTranscript() {
        guard isEnabled, !isPastingLatest else { return }
        isPastingLatest = true
        let transcript = lastTranscript
        let target = CapturedPasteTarget.frontmost()
        Task {
            let outcome = await capturedTargetPaster().paste(transcript, to: target)
            isPastingLatest = false
            switch outcome {
            case .pasted: showTemporaryFeedback("Paste latest attempted")
            case .noText: showTemporaryFeedback("No transcript to paste")
            case .copiedOnly: showTemporaryFeedback("No trusted target; transcript copied")
            case .clipboardFailed: showTemporaryFeedback("Could not copy transcript")
            case .pasteFailed: showTemporaryFeedback("Paste failed; transcript copied")
            }
        }
    }

    func retryPending() {
        guard case .pending = status, retryTask == nil,
              let pending = (try? store.loadPending()) ?? nil else { return }
        let session = VoiceSessionMachine.Session(id: pending.metadata.sessionID, startedAt: pending.metadata.timestamp, localeIdentifier: pending.metadata.localeIdentifier)
        guard case .accepted = machine.handle(.retryBegan(session)) else { return }
        status = .finalizing; partialTranscript = ""
        let generation = lifecycleGeneration
        retryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await TranscriberSession.retry(fileURL: pending.audioURL, locale: Locale(identifier: pending.metadata.localeIdentifier)) { [weak self] update in
                    Task { @MainActor in
                        guard let self, generation == self.lifecycleGeneration else { return }
                        self.partialTranscript = update.text
                    }
                }
                try Task.checkCancellation()
                guard generation == lifecycleGeneration else { return }
                _ = machine.handle(.finalized(session))
                try await commit(text, target: nil, recovery: .pending, sessionID: pending.metadata.sessionID,
                                 localeIdentifier: pending.metadata.localeIdentifier, generation: generation)
            } catch is CancellationError {
                // Lifecycle teardown owns the resulting state.
            } catch {
                guard generation == lifecycleGeneration else { return }
                await captureFailed(error)
            }
            if generation == lifecycleGeneration { retryTask = nil }
        }
    }

    func deletePending() {
        do {
            try store.deletePending()
            _ = machine.handle(.pendingDeleted)
            machine = VoiceSessionMachine()
            status = isEnabled ? .idle : .disabled
        } catch {
            status = .pending
            showTemporaryFeedback("Could not delete the pending recording")
        }
    }

    func cancelVoiceInteraction() {
        let active: Bool
        switch machine.state { case .arming, .recording: active = true; default: active = false }
        guard active, cancellationCleanupTask == nil else { return }
        lifecycleGeneration &+= 1; armGeneration &+= 1
        let arming = armTask; arming?.cancel()
        finalizationTask?.cancel(); finalizationTask = nil
        analysisTask?.cancel(); analysisTask = nil; maxTimer?.invalidate(); maxTimer = nil
        observer?.setRecordingActive(false); secureInputSessions.removeAll(); pasteTarget = nil; partialTranscript = ""
        machine = VoiceSessionMachine(); status = isEnabled ? .idle : .disabled
        cancellationCleanupTask = Task { [weak self] in
            guard let self else { return }
            await arming?.value
            let liveCapture = capture; capture = nil
            let liveTranscriber = transcriber; transcriber = nil
            await liveCapture?.stopAndWait(); await liveTranscriber?.cancel()
            try? store.clearActive()
            armTask = nil; cancellationCleanupTask = nil
        }
    }

    func stopRecording() {
        guard case .recording(let mode, let session) = machine.state else { return }
        if mode == .latched { interpret(machine.handle(.toggle(session))) }
        else { interpret(machine.handle(.pushToTalkEnded)) }
    }

    func reloadConfig() { Task { await loadConfig() } }

    func userChangedVoiceShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, name: KeyboardShortcuts.Name) {
        let key = Self.voiceBindingKey(name)
        UserDefaults.standard.set(true, forKey: "voice.binding.\(key).explicit")
        let dto = shortcut.flatMap(ShortcutDTO.fromKeyboardShortcut) ?? .unbound
        if name == .voiceHoldToTalk { unmanagedHoldShortcut = dto }
        else if name == .voiceToggleRecording { unmanagedToggleShortcut = dto }
        else if name == .voiceCancel { unmanagedCancelShortcut = dto }
        guard let shortcut else { reloadConfig(); return }
        let conflicts = [.moveToNextScreen, .pasteLatestTranscript, .voiceHoldToTalk, .voiceToggleRecording, .voiceCancel]
            .filter { $0 != name }.contains { KeyboardShortcuts.getShortcut(for: $0) == shortcut }
        if conflicts { KeyboardShortcuts.setShortcut(nil, for: name); configDiagnostic = "Shortcut conflicts with another action" }
        reloadConfig()
    }

    func userChangedPasteLatestShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        let activeWindowShortcut = try? effective.windowMoverShortcut.value.keyboardShortcut()
        guard shortcut != activeWindowShortcut else {
            KeyboardShortcuts.setShortcut(unmanagedPasteLatestShortcut, for: .pasteLatestTranscript)
            return
        }
        unmanagedPasteLatestShortcut = shortcut
        reloadConfig()
    }

    func userChangedWindowMoverShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        let activePasteShortcut = try? effective.pasteLatestTranscriptShortcut.value.keyboardShortcut()
        guard shortcut != activePasteShortcut else {
            KeyboardShortcuts.setShortcut(unmanagedWindowMoverShortcut, for: .moveToNextScreen)
            return
        }
        unmanagedWindowMoverShortcut = shortcut
        reloadConfig()
    }

    private func configureAndReload() async {
        let local = SettingsValues(voiceEnabled: isEnabled, outputMode: outputMode,
                                   historyEnabled: historyEnabled, historyRetentionDays: historyRetentionDays,
                                   historyMaxEntries: historyMaxEntries, locale: localeIdentifier, inputDevicePriority: devicePriority,
                                   fallbackToSystemDefault: fallbackToSystemDefault)
        let loader = ConfigReloader(local: local)
        reloader = loader
        await loader.addApplyCallback { [weak self] result in await self?.apply(result.effective) }
        await loadConfig()
        if !hasAppliedConfiguration {
            // An invalid initial file must not leave modules unconfigured, but no trigger is started
            // until the file has first been read and rejected atomically.
            apply(EffectiveSettings.resolve(config: nil, local: local))
        }
        await reconcileLegacyTranscriptForEffectiveHistory()
        hasResolvedInitialHistory = true
        TranscriptHistoryViewModel.shared.setHistoryEnabled(historyEnabled)
        if historyEnabled {
            await TranscriptHistoryViewModel.shared.reload(limit: TranscriptHistorySnapshot.menuPreviewCount)
        }
    }

    private func loadConfig() async {
        guard let reloader else { return }
        await reloader.updateLocal(currentLocalSettings())
        do { _ = try await reloader.reload(); configDiagnostic = nil }
        catch { configDiagnostic = String(describing: error) }
    }

    private func apply(_ value: EffectiveSettings) {
        hasAppliedConfiguration = true
        let changed = value.changedKeys(from: effective)
        effective = value; managedKeys = Set(EffectiveSettings.Key.allCases.filter { key in
            switch key { case .voiceEnabled: return value.voiceEnabled.isManaged
            case .holdToTalkShortcut: return value.holdToTalkShortcut.isManaged
            case .toggleRecordingShortcut: return value.toggleRecordingShortcut.isManaged
            case .cancelShortcut: return value.cancelShortcut.isManaged
            case .pasteLatestTranscriptShortcut: return value.pasteLatestTranscriptShortcut.isManaged
            case .outputMode, .autoPaste: return value.outputMode.isManaged
            case .historyEnabled: return value.historyEnabled.isManaged
            case .historyRetentionDays: return value.historyRetentionDays.isManaged
            case .historyMaxEntries: return value.historyMaxEntries.isManaged
            case .locale: return value.locale.isManaged
            case .inputDevicePriority: return value.inputDevicePriority.isManaged; case .fallbackToSystemDefault: return value.fallbackToSystemDefault.isManaged
            default: return false }
        })
        applying = true
        isEnabled = value.voiceEnabled.value; outputMode = value.outputMode.value
        historyEnabled = value.historyEnabled.value; historyRetentionDays = value.historyRetentionDays.value
        historyMaxEntries = value.historyMaxEntries.value
        localeIdentifier = value.locale.value; devicePriority = value.inputDevicePriority.value; fallbackToSystemDefault = value.fallbackToSystemDefault.value
        applying = false
        if !changed.isDisjoint(with: [.holdToTalkShortcut, .toggleRecordingShortcut, .cancelShortcut]) {
            // Rebinding is a cancellation boundary; no stale handler may complete a private session.
            cancelVoiceInteraction()
        }
        applyVoiceShortcuts(value)
        applyPasteLatestShortcut(value.pasteLatestTranscriptShortcut)
        applyHistorySettings(changedKeys: changed)
        if isEnabled { recoverDegradedAndObserve() } else { stop() }
        WindowMoverModule.shared.applyManaged(enabled: value.windowMoverEnabled, shortcut: value.windowMoverShortcut)
    }

    private func reconcileObservation() {
        guard observerThresholdMs != effective.fnHoldThresholdMs.value || observerHoldBinding != effective.holdToTalkShortcut.value else { return }
        guard case .idle = machine.state else { return }
        observation?.cancel(); observation = nil; observer = nil; observerThresholdMs = nil; observerHoldBinding = nil
        startObserving()
    }

    private func startObserving() {
        guard isEnabled, observation == nil else { if isEnabled, status == .disabled { status = .idle }; return }
        guard case .modifierHold = effective.holdToTalkShortcut.value else { if status == .disabled { status = .idle }; return }
        guard CGPreflightListenEventAccess() else { status = .degraded("Input Monitoring access is required"); return }
        guard AXIsProcessTrusted() else { status = .degraded("Accessibility access is required for Fn shortcuts"); return }
        let observer = FnEventObserver(holdThreshold: Double(effective.fnHoldThresholdMs.value) / 1000, allowsFnSpaceToggle: false)
        do {
            observation = try observer.observe { [weak self] event in self?.handle(event) }
            self.observer = observer; observerThresholdMs = effective.fnHoldThresholdMs.value; observerHoldBinding = effective.holdToTalkShortcut.value
            if status == .disabled { status = .idle }
        } catch { status = .degraded("Input Monitoring access is required") }
    }

    private func handle(_ event: TriggerEvent) {
        guard isEnabled else { return }
        if case .degraded = machine.state { _ = machine.handle(.resetDegraded) }
        if case .degraded = status { status = .idle }
        switch event {
        case .pushToTalkBegan: begin(mode: .pushToTalk)
        case .pushToTalkEnded: interpret(machine.handle(.pushToTalkEnded))
        case .toggleRequested: begin(mode: .latched)
        case .secureInputBegan:
            if case .arming(_, let session) = machine.state { secureInputSessions.insert(session.id) }
            if case .recording(_, let session) = machine.state { secureInputSessions.insert(session.id) }
            observer?.setRecordingActive(false)
            cancelVoiceInteraction()
        }
    }

    private func begin(mode: VoiceSessionMachine.Mode) {
        let session = VoiceSessionMachine.Session(id: UUID(), startedAt: Date(), localeIdentifier: localeIdentifier)
        interpret(machine.handle(mode == .pushToTalk ? .pushToTalkBegan(session) : .toggle(session)))
    }

    private func interpret(_ outcome: VoiceSessionMachine.Outcome) {
        guard case .accepted(let commands) = outcome else { return }
        for command in commands {
            switch command {
            case .arm(let mode, let session): arm(mode, session)
            case .cancelArm(let session): cancelArming(session)
            case .stop(let session): finish(session)
            case .commit: break
            case .retry: break
            case .deletePending: deletePending()
            }
        }
    }

    private func cancelArming(_ session: VoiceSessionMachine.Session) {
        armGeneration &+= 1
        armTask?.cancel()
        armTask = nil
        secureInputSessions.remove(session.id)
        if isEnabled { status = .idle }
    }

    private func arm(_ mode: VoiceSessionMachine.Mode, _ session: VoiceSessionMachine.Session) {
        switch status {
        case .idle, .noSpeech, .pasteFailed: break
        default: return
        }
        guard armTask == nil, captureTeardownTask == nil, cancellationCleanupTask == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            _ = machine.handle(.armingRefused(session, .permissionDenied)); status = .degraded("Microphone access is required"); return
        }
        status = .arming; armGeneration &+= 1; let generation = armGeneration
        let lifecycle = lifecycleGeneration
        armTask = Task { [weak self] in
            guard let self else { return }
            var armingCapture: AudioCaptureService?
            do {
                let device = try DeviceSelector(devices: DeviceTable(), bluetooth: BluetoothLinkOracle()).select(
                    priorities: devicePriority.map { AudioDevicePreference(uid: $0.uid, exactName: $0.name) }, allowSystemDefaultFallback: fallbackToSystemDefault)
                let requested = requestedLocale
                guard let locale = await assets.resolve(requested) else { throw VoiceSessionMachine.DegradedReason.unsupportedLocale }
                guard await assets.status(locale: locale) == .installed else { throw VoiceSessionMachine.DegradedReason.assetsMissing }
                try Task.checkCancellation(); guard generation == armGeneration, lifecycle == lifecycleGeneration, isEnabled else { throw CancellationError() }
                let transcriber = try await TranscriberSession(locale: locale)
                do {
                    try Task.checkCancellation()
                    guard generation == armGeneration, lifecycle == lifecycleGeneration, isEnabled else { throw CancellationError() }
                } catch { await transcriber.cancel(); throw error }
                try Task.checkCancellation()
                guard generation == armGeneration, lifecycle == lifecycleGeneration else { throw CancellationError() }
                let url = try store.prepareActive(.init(sessionID: session.id, timestamp: session.startedAt, localeIdentifier: locale.identifier, failureReason: "active"))
                let capture = AudioCaptureService()
                let stream = try capture.start(device: device, recoveryURL: url,
                                               firstBufferDeadline: device.transport == .bluetooth ? 3 : 1)
                armingCapture = capture
                try store.hardenPermissions()
                guard case .arming(let resolvedMode, let active) = machine.state, active == session else {
                    capture.stop(); await transcriber.cancel(); throw CancellationError()
                }
                guard case .accepted = machine.handle(.armed(resolvedMode, session)) else {
                    await transcriber.cancel(); throw CancellationError()
                }
                self.capture = capture; self.transcriber = transcriber; self.transcriberResolvedLocaleIdentifier = locale.identifier; pasteTarget = CapturedPasteTarget.frontmost(); partialTranscript = ""
                armingCapture = nil
                observer?.setRecordingActive(true)
                status = .recording; armTask = nil
                analysisTask = Task { [weak self, capture] in
                    do { try await transcriber.start(buffers: stream.buffers) { update in Task { @MainActor in
                        guard let self, generation == self.lifecycleGeneration, case .recording = self.status else { return }
                        self.partialTranscript = update.text
                    } }; _ = capture; return nil }
                    catch { _ = capture; return error }
                }
                maxTimer = Timer.scheduledTimer(withTimeInterval: Double(effective.maxSessionSeconds.value), repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.stopForMaximumDuration() }
                }
            } catch {
                if let armingCapture { await armingCapture.stopAndWait() }
                guard generation == armGeneration, lifecycle == lifecycleGeneration, isEnabled, !(error is CancellationError) else { return }
                armTask = nil; _ = machine.handle(.armingRefused(session, Self.degradedReason(error)))
                status = .degraded(Self.degradedMessage(error))
            }
        }
    }

    private func finish(_ session: VoiceSessionMachine.Session) {
        guard status == .recording, finalizationTask == nil else { return }
        status = .finalizing
        observer?.setRecordingActive(false)
        maxTimer?.invalidate(); maxTimer = nil
        let drainingCapture = capture
        drainingCapture?.stop()
        let generation = lifecycleGeneration
        finalizationTask = Task { [weak self, drainingCapture] in
            guard let self else { return }
            if let error = await analysisTask?.value {
                guard generation == lifecycleGeneration, !Task.isCancelled else { return }
                await captureFailed(error); return
            }
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            capture = nil; analysisTask = nil
            do {
                let text = try await transcriber?.finish() ?? ""
                try Task.checkCancellation()
                guard generation == lifecycleGeneration else { return }
                _ = machine.handle(.finalized(session))
                try await commit(text, target: pasteTarget, recovery: .active, sessionID: session.id,
                                 localeIdentifier: self.transcriberResolvedLocaleIdentifier ?? session.localeIdentifier, generation: generation)
            } catch is CancellationError {
                // Lifecycle teardown owns state and recovery.
            } catch {
                guard generation == lifecycleGeneration else { return }
                await captureFailed(error)
            }
            if generation == lifecycleGeneration { finalizationTask = nil }
            _ = drainingCapture
        }
    }

    private enum RecoverySource { case active, pending }

    /// A locally changed history switch, applied at once. A managed value is never followed from
    /// here: the control is disabled while the configuration file owns the setting, and `apply` is
    /// the only path that may change an effective value.
    private func applyLocalHistoryEnabled() {
        guard !applying, hasResolvedInitialHistory, !effective.historyEnabled.isManaged else { return }
        TranscriptHistoryViewModel.shared.setHistoryEnabled(historyEnabled)
    }

    /// A locally changed retention bound, applied at once to a store that is already open. As in
    /// `applyHistorySettings`, tightening retention never opens or creates the database.
    private func applyLocalHistoryRetention() {
        guard !applying, hasResolvedInitialHistory, historyEnabled,
              let store = SharedTranscriptHistoryStore.opened() else { return }
        let policy = historyRetentionPolicy
        Task { _ = try? await store.setRetention(policy) }
    }

    /// Propagates effective history settings to the surfaces and to an already-open store.
    ///
    /// Retention is re-applied only when it actually changed and only to a store that is already
    /// open: tightening retention must not be the thing that creates the database, and a disabled
    /// history must never reach storage at all. Pruning here is event-driven, not periodic.
    private func applyHistorySettings(changedKeys: Set<EffectiveSettings.Key>) {
        guard hasResolvedInitialHistory else { return }
        TranscriptHistoryViewModel.shared.setHistoryEnabled(historyEnabled)
        if !historyEnabled { TranscriptHistoryPanelController.shared.close() }
        guard historyEnabled,
              !changedKeys.isDisjoint(with: [.historyRetentionDays, .historyMaxEntries]),
              let store = SharedTranscriptHistoryStore.opened() else { return }
        let policy = historyRetentionPolicy
        Task { _ = try? await store.setRetention(policy) }
    }

    /// Bounded retention as resolved for this run. Days of zero means "count only".
    private var historyRetentionPolicy: TranscriptRetentionPolicy {
        TranscriptRetentionPolicy(
            maximumEntries: historyMaxEntries,
            maximumAge: historyRetentionDays > 0 ? Double(historyRetentionDays) * 86_400 : nil)
    }

    private func commit(_ text: String, target: CapturedPasteTarget?, recovery: RecoverySource,
                        sessionID: UUID, localeIdentifier: String, generation: UInt64) async throws {
        guard generation == lifecycleGeneration, !Task.isCancelled else { throw CancellationError() }
        let verifiedTarget = CapturedTargetVerifier(dependencies: .live).verify(target).pid
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            switch recovery {
            case .active: try store.clearActive()
            case .pending: try store.deletePending(); try store.clearActive()
            }
            secureInputSessions.remove(sessionID)
            partialTranscript = ""; _ = machine.handle(.committed); status = .noSpeech
            transcriber = nil
            Task { try? await Task.sleep(for: .seconds(2)); if status == .noSpeech { status = .idle } }
            reconcileObservation()
            return
        }
        let privacyCancelled = secureInputSessions.contains(sessionID)
        let shouldAutoPaste = outputMode == .pasteImmediately && !privacyCancelled
        let result = try await TranscriptCommitter().commit(
            clean,
            settings: .init(autoPaste: false,
                            recordHistory: historyEnabled, sessionID: sessionID,
                            localeIdentifier: localeIdentifier,
                            historySource: { if case .pending = recovery { return .recovery }; return .live }(),
                            secureInputActive: secureInputSessions.contains(sessionID),
                            historyRetention: historyRetentionPolicy),
            targetPID: verifiedTarget
        )
        guard generation == lifecycleGeneration, !Task.isCancelled else { throw CancellationError() }
        if privacyCancelled {
            secureInputSessions.remove(sessionID); partialTranscript = ""; pasteTarget = nil
            _ = machine.handle(.committed); status = .idle; transcriber = nil; reconcileObservation()
            return
        }
        var pasteError = result.pasteError
        if shouldAutoPaste {
            switch CapturedTargetVerifier(dependencies: .live).verify(target) {
            case .valid(let pid):
                do { try await PasteService().paste(text: clean, targetPID: pid) }
                catch { pasteError = error }
            case .rejected:
                pasteError = PasteError.noTargetApplication
            }
        }
        guard generation == lifecycleGeneration, !Task.isCancelled else { throw CancellationError() }
        secureInputSessions.remove(sessionID)
        lastTranscript = clean
        if historyEnabled { await TranscriptHistoryViewModel.shared.reload() }
        partialTranscript = ""; _ = machine.handle(.committed)
        if let error = pasteError {
            status = .pasteFailed(error.localizedDescription)
            Task { try? await Task.sleep(for: .seconds(3)); if case .pasteFailed = status { status = .idle } }
        } else { status = .idle }
        transcriber = nil; reconcileObservation()
    }

    private func captureFailed(_ error: Error) async {
        capture?.stop()
        _ = await analysisTask?.value
        capture = nil; analysisTask = nil
        await transcriber?.cancel(); transcriber = nil

        maxTimer?.invalidate(); maxTimer = nil
        let pending = ((try? store.loadPending()) ?? nil) ?? (try? store.promoteActive(failureReason: String(describing: error)))
        if let pending {
            _ = machine.handle(.failed(.init(id: pending.metadata.sessionID, audioURL: pending.audioURL))); status = .pending
        } else { status = .failed(error.localizedDescription) }
        partialTranscript = ""
    }

    private func reconcileRecovery() {
        if case .pending(let p) = try? Reconciliation.run(store: store) {
            _ = machine.handle(.recovered(.init(id: p.metadata.sessionID, audioURL: p.audioURL))); status = .pending
        }
    }

    private func stopForMaximumDuration() {
        guard case .recording(let mode, let session) = machine.state else { return }
        interpret(machine.handle(VoiceSessionMachine.maximumStopEvent(mode: mode, session: session)))
    }

    private func currentLocalSettings() -> SettingsValues {
        let defaults = UserDefaults.standard
        let persistedDevices = defaults.data(forKey: "voice.devices")
            .flatMap { try? JSONDecoder().decode([InputDeviceDTO].self, from: $0) } ?? []
        return SettingsValues(windowMoverEnabled: WindowMoverModule.shared.persistedEnabled,
                              windowMoverShortcut: unmanagedWindowMoverShortcut.flatMap(ShortcutDTO.fromKeyboardShortcut),
                              voiceEnabled: defaults.bool(forKey: "voice.enabled"), holdToTalkShortcut: unmanagedHoldShortcut,
                              toggleRecordingShortcut: unmanagedToggleShortcut, cancelShortcut: unmanagedCancelShortcut,
                              pasteLatestTranscriptShortcut: persistedPasteLatestTranscriptShortcut,
                              outputMode: VoiceOutputMode(rawValue: defaults.string(forKey: "voice.outputMode") ?? "") ?? .pasteImmediately,
                              historyEnabled: defaults.bool(forKey: VoiceHistoryPreferences.enabledKey),
                              historyRetentionDays: defaults.integer(forKey: VoiceHistoryPreferences.retentionDaysKey),
                              historyMaxEntries: defaults.integer(forKey: VoiceHistoryPreferences.maxEntriesKey),
                              locale: defaults.string(forKey: "voice.locale") ?? "system",
                              inputDevicePriority: persistedDevices,
                              fallbackToSystemDefault: defaults.bool(forKey: "voice.fallback"))
    }

    private func recoverDegradedAndObserve() {
        KeyboardShortcuts.enable(.pasteLatestTranscript)
        reconcileShortcutActivation()
        if case .degraded = machine.state { _ = machine.handle(.resetDegraded) }
        if case .degraded = status { status = .idle }
        reconcileObservation()
    }

    private func registerPasteLatestShortcut() {
        guard !isPasteLatestHandlerInstalled else { return }
        isPasteLatestHandlerInstalled = true
        KeyboardShortcuts.onKeyDown(for: .voiceHoldToTalk) { [weak self] in Task { @MainActor in self?.begin(mode: .pushToTalk) } }
        KeyboardShortcuts.onKeyUp(for: .voiceHoldToTalk) { [weak self] in Task { @MainActor in guard let self else { return }; self.interpret(self.machine.handle(.pushToTalkEnded)) } }
        KeyboardShortcuts.onKeyUp(for: .voiceToggleRecording) { [weak self] in Task { @MainActor in self?.begin(mode: .latched) } }
        KeyboardShortcuts.onKeyDown(for: .voiceCancel) { [weak self] in Task { @MainActor in self?.cancelVoiceInteraction() } }
        KeyboardShortcuts.onKeyUp(for: .pasteLatestTranscript) { [weak self] in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.pasteLatestTranscript()
            }
        }
        if isEnabled { KeyboardShortcuts.enable(.pasteLatestTranscript) }
        else { KeyboardShortcuts.disable(.pasteLatestTranscript) }
    }

    private var requestedLocale: Locale { localeIdentifier == "system" ? .current : Locale(identifier: localeIdentifier) }

    private func applyVoiceShortcuts(_ value: EffectiveSettings) {
        unmanagedHoldShortcut = applyManagedVoiceBinding(value.holdToTalkShortcut, name: .voiceHoldToTalk, key: "hold", unmanaged: unmanagedHoldShortcut)
        unmanagedToggleShortcut = applyManagedVoiceBinding(value.toggleRecordingShortcut, name: .voiceToggleRecording, key: "toggle", unmanaged: unmanagedToggleShortcut)
        unmanagedCancelShortcut = applyManagedVoiceBinding(value.cancelShortcut, name: .voiceCancel, key: "cancel", unmanaged: unmanagedCancelShortcut)
        reconcileShortcutActivation()
    }

    private func applyManagedVoiceBinding(_ binding: ResolvedSetting<ShortcutDTO>, name: KeyboardShortcuts.Name,
                                          key: String, unmanaged: ShortcutDTO?) -> ShortcutDTO? {
        let defaults = UserDefaults.standard, activeKey = "voice.binding.\(key).backupActive", dataKey = "voice.binding.\(key).backup"
        var local = unmanaged
        if binding.isManaged {
            if !defaults.bool(forKey: activeKey) {
                defaults.set(true, forKey: activeKey)
                if let local, let data = try? JSONEncoder().encode(local) { defaults.set(data, forKey: dataKey) }
                else { defaults.removeObject(forKey: dataKey) }
            }
            KeyboardShortcuts.setShortcut(try? binding.value.keyboardShortcut(), for: name)
        } else if defaults.bool(forKey: activeKey) {
            local = defaults.data(forKey: dataKey).flatMap { try? JSONDecoder().decode(ShortcutDTO.self, from: $0) }
            KeyboardShortcuts.setShortcut(local.flatMap { try? $0.keyboardShortcut() }, for: name)
            defaults.set(local != nil, forKey: "voice.binding.\(key).explicit")
            defaults.removeObject(forKey: dataKey); defaults.set(false, forKey: activeKey)
        } else {
            KeyboardShortcuts.setShortcut(try? binding.value.keyboardShortcut(), for: name)
        }
        return local
    }

    private static func voiceBindingKey(_ name: KeyboardShortcuts.Name) -> String {
        if name == .voiceHoldToTalk { return "hold" }; if name == .voiceToggleRecording { return "toggle" }; return "cancel"
    }

    private static func localVoiceBinding(_ name: KeyboardShortcuts.Name, key: String) -> ShortcutDTO? {
        let defaults = UserDefaults.standard, dataKey = "voice.binding.\(key).backup"
        if defaults.bool(forKey: "voice.binding.\(key).backupActive") {
            return defaults.data(forKey: dataKey).flatMap { try? JSONDecoder().decode(ShortcutDTO.self, from: $0) }
        }
        guard defaults.bool(forKey: "voice.binding.\(key).explicit") else { return nil }
        return KeyboardShortcuts.getShortcut(for: name).flatMap(ShortcutDTO.fromKeyboardShortcut) ?? .unbound
    }

    private func reconcileShortcutActivation() {
        let phase: VoiceInteractionPhase
        switch status { case .arming: phase = .arming; case .recording: phase = .recording; case .finalizing: phase = .finalizing; case .idle, .noSpeech, .pasteFailed, .degraded: phase = .idle; default: phase = .unavailable }
        let policy = VoiceShortcutActivationPolicy.decide(moduleEnabled: isEnabled, phase: phase)
        policy.holdEnabled ? KeyboardShortcuts.enable(.voiceHoldToTalk) : KeyboardShortcuts.disable(.voiceHoldToTalk)
        policy.toggleEnabled ? KeyboardShortcuts.enable(.voiceToggleRecording) : KeyboardShortcuts.disable(.voiceToggleRecording)
        policy.cancelEnabled ? KeyboardShortcuts.enable(.voiceCancel) : KeyboardShortcuts.disable(.voiceCancel)
    }

    private func applyPasteLatestShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>) {
        let defaults = UserDefaults.standard
        let hasBackup = defaults.bool(forKey: Self.pasteLatestShortcutBackupActiveKey)
        if shortcut.isManaged {
            if !hasBackup {
                unmanagedPasteLatestShortcut = KeyboardShortcuts.getShortcut(for: .pasteLatestTranscript)
                Self.savePasteLatestShortcutBackup(unmanagedPasteLatestShortcut)
            }
            if let converted = try? shortcut.value.keyboardShortcut() {
                KeyboardShortcuts.setShortcut(converted, for: .pasteLatestTranscript)
            }
        } else if hasBackup {
            KeyboardShortcuts.setShortcut(unmanagedPasteLatestShortcut, for: .pasteLatestTranscript)
            defaults.removeObject(forKey: Self.pasteLatestShortcutBackupDataKey)
            defaults.set(false, forKey: Self.pasteLatestShortcutBackupActiveKey)
        } else {
            unmanagedPasteLatestShortcut = KeyboardShortcuts.getShortcut(for: .pasteLatestTranscript)
        }
    }

    private static func savePasteLatestShortcutBackup(_ shortcut: KeyboardShortcuts.Shortcut?) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: pasteLatestShortcutBackupActiveKey)
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: pasteLatestShortcutBackupDataKey)
        } else {
            defaults.removeObject(forKey: pasteLatestShortcutBackupDataKey)
        }
    }

    private static func loadPasteLatestShortcutBackup() -> KeyboardShortcuts.Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: pasteLatestShortcutBackupDataKey) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
    }

    private func capturedTargetPaster() -> CapturedTargetPaster {
        let board = NSPasteboard.general
        let service = PasteService()
        let verifier = CapturedTargetVerifier(dependencies: .live)
        return CapturedTargetPaster(dependencies: .init(
            setClipboard: { text in
                board.clearContents()
                guard board.setString(text, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
            },
            verify: { verifier.verify($0) },
            paste: { try await service.paste(text: $0, targetPID: $1) }))
    }

    private func updateOverlay() {
        let phase: VoiceOverlayPresentation.Phase
        switch status {
        case .arming: phase = .arming
        case .recording: phase = .recording
        case .finalizing: phase = .finalizing
        default: phase = .hidden
        }
        VoiceRecordingOverlayController.shared.update(.init(phase: phase, partialTranscript: partialTranscript, outputMode: outputMode))
    }

    private func showTemporaryFeedback(_ message: String) {
        feedbackGeneration &+= 1
        let generation = feedbackGeneration
        temporaryFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if feedbackGeneration == generation { temporaryFeedback = nil }
        }
    }

    private static func degradedReason(_ error: Error) -> VoiceSessionMachine.DegradedReason {
        if let reason = error as? VoiceSessionMachine.DegradedReason { return reason }
        if error is DeviceSelectionError { return .noInputDevice }
        if error is TranscriberSession.SessionError { return .unsupportedLocale }
        return .noInputDevice
    }

    private static func degradedMessage(_ error: Error) -> String {
        if let reason = error as? VoiceSessionMachine.DegradedReason {
            switch reason { case .assetsMissing: return "Speech assets are not installed"; case .noInputDevice: return "No eligible input device";
            case .permissionDenied: return "Required permission is missing"; case .unsupportedLocale: return "Locale is unsupported" }
        }
        if error is DeviceSelectionError { return "No eligible input device" }
        return error.localizedDescription
    }

    private func persist(_ key: String, _ value: Any) { if !applying { UserDefaults.standard.set(value, forKey: key) } }
    private func persistAndReconfigure(_ key: String, _ value: Bool) { persist(key, value); if !applying { value ? recoverDegradedAndObserve() : stop() } }
    private func saveDevices() { if !applying, let data = try? JSONEncoder().encode(devicePriority) { UserDefaults.standard.set(data, forKey: "voice.devices") } }
    private func describe(_ value: VoiceAssetManager.Status) -> String { String(describing: value) }
}
