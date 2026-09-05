import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Foundation
import KeyboardShortcuts
import OSLog

/// Main-actor lifecycle and effect coordinator for Voice Transcription.
@MainActor
final class VoiceTranscriptionModule: ObservableObject {
    static let shared = VoiceTranscriptionModule()

    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "Voice")

    enum Status: Equatable {
        case disabled, idle, arming, recording, finalizing, pending, noSpeech, pasteFailed(String), degraded(String), failed(String)
    }

    @Published private(set) var status: Status = .disabled { didSet { updateOverlay(); reconcileShortcutActivation() } }
    @Published private(set) var partialTranscript = "" { didSet { updateOverlay() } }
    @Published private(set) var lastTranscript = ""
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published private(set) var assetStatus = "Not checked"
    @Published private(set) var supportedLocaleIdentifiers: [String] = []
    @Published private(set) var managedKeys: Set<EffectiveSettings.Key> = []
    @Published private(set) var settingsRevision: UInt64 = 0
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
    private var observerHoldBindings: [ShortcutDTO]?
    private var observerToggleBindings: [ShortcutDTO]?
    private var observerCancelBindings: [ShortcutDTO]?
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
    private var maxTimer: Timer?
    private var pasteTarget: CapturedPasteTarget?
    private let store = PendingRecordingStore()
    private let assets = VoiceAssetManager()
    private var effective = EffectiveSettings.resolve(config: nil)
    private var applying = false
    /// History remains unpublished until the first effective configuration and startup prune finish.
    private var hasResolvedInitialHistory = false
    private var unmanagedHoldBindings: [ShortcutDTO]?
    private var unmanagedToggleBindings: [ShortcutDTO]?
    private var unmanagedCancelBindings: [ShortcutDTO]?
    private var unmanagedPasteLatestShortcut: KeyboardShortcuts.Shortcut?
    private var feedbackGeneration: UInt64 = 0
    private var assetStatusGeneration: UInt64 = 0
    private var assetProgressObservation: NSKeyValueObservation?
    private var isPastingLatest = false
    private var bindingCommitTail: Task<String?, Never>?
    private var bindingCaptureLease = VoiceBindingCaptureLease()
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
        unmanagedHoldBindings = Self.localVoiceBindings(.voiceHoldToTalk, key: "hold")
        unmanagedToggleBindings = Self.localVoiceBindings(.voiceToggleRecording, key: "toggle")
        unmanagedCancelBindings = Self.localVoiceBindings(.voiceCancel, key: "cancel")
    }

    func register() {
        logger.notice("Registering Voice Transcription")
        reconcileRecovery()
        if historyLatestObserver == nil {
            historyLatestObserver = NotificationCenter.default.addObserver(
                forName: .transcriptHistoryLatestChanged, object: nil, queue: .main
            ) { [weak self] note in
                Task { @MainActor in self?.lastTranscript = note.object as? String ?? "" }
            }
        }
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
                ConfigurationCoordinator.shared.reportIfEmpty(migration)
            }
        } catch {
            ConfigurationCoordinator.shared.reportIfEmpty(historyEnabled
                ? "Transcript history is unavailable" : "Legacy transcript cleanup failed")
        }
    }

    func stop() {
        logger.notice("Stopping Voice Transcription")
        lifecycleGeneration &+= 1
        armGeneration &+= 1
        observer?.setRecordingActive(false)
        observation?.cancel(); observation = nil; observer = nil; observerThresholdMs = nil; observerHoldBindings = nil
        maxTimer?.invalidate(); maxTimer = nil
        assetProgressObservation?.invalidate(); assetProgressObservation = nil
        let cancellationWasInFlight = cancellationCleanupTask != nil
        let activeCapture = capture
        capture = nil
        armTask?.cancel(); armTask = nil
        analysisTask?.cancel(); analysisTask = nil
        finalizationTask?.cancel(); finalizationTask = nil
        retryTask?.cancel(); retryTask = nil
        let sessionTranscriber = transcriber
        transcriber = nil
        if sessionTranscriber != nil { Task { await sessionTranscriber?.cancel() } }
        partialTranscript = ""
        if let activeCapture, captureTeardownTask == nil {
            captureTeardownTask = Task { [weak self] in
                guard let self else { return }
                await activeCapture.stopAndWait()
                let pending: PendingRecordingStore.Pending?
                if VoiceTeardownPolicy.shouldPromoteRecovery(for: cancellationWasInFlight ? .privacyCancellation : .lifecycleStop) {
                    pending = ((try? store.loadPending()) ?? nil) ?? (try? store.promoteActive(failureReason: "module stopped"))
                } else {
                    try? store.clearActive(); pending = nil
                }
                if let pending {
                    logger.error("Lifecycle stop promoted an interrupted recording to recovery")
                    machine = VoiceSessionMachine()
                    _ = machine.handle(.recovered(.init(id: pending.metadata.sessionID, audioURL: pending.audioURL)))
                    status = .pending
                }
                captureTeardownTask = nil
                logger.notice("Voice capture teardown completed")
            }
        }
        InputRoutingCoordinator.shared.setVoiceActivation(
            moduleEnabled: false,
            policy: .decide(moduleEnabled: false, phase: .unavailable),
            captureIsActive: bindingCaptureLease.isActive
        )
        if status != .pending { machine = VoiceSessionMachine(); status = .disabled }
    }

    func requestPermissions() {
        logger.notice("Requesting Voice permissions contextually")
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.logger.notice("Microphone permission request completed: granted=\(granted, privacy: .public)")
                if granted { self?.recoverDegradedAndObserve() }
            }
        }
        if CGRequestListenEventAccess() { recoverDegradedAndObserve() }
        AccessibilityService.shared.requestIfNeeded()
        BluetoothLinkOracle.requestAccessContextually()
    }

    func refreshDevices() {
        availableDevices = (try? DeviceTable().inputDevices())?.filter(\.hasInput) ?? []
    }

    func refreshLocalesAndAssets() {
        Task { supportedLocaleIdentifiers = await assets.supportedLocales().map(\.identifier).sorted(); refreshAssets() }
    }

    func refreshAssets() {
        assetProgressObservation?.invalidate(); assetProgressObservation = nil
        assetStatusGeneration &+= 1
        let generation = assetStatusGeneration
        let locale = requestedLocale
        logger.notice("Refreshing speech asset status")
        Task {
            let snapshot = await assets.status(locale: locale)
            let result = describe(snapshot)
            guard generation == assetStatusGeneration, locale.identifier == requestedLocale.identifier else { return }
            assetStatus = result
            logger.notice("Speech asset status refreshed: \(Self.assetStatusName(snapshot), privacy: .public)")
        }
    }
    func downloadAssets() {
        assetProgressObservation?.invalidate(); assetProgressObservation = nil
        assetStatusGeneration &+= 1
        let generation = assetStatusGeneration
        let locale = requestedLocale
        assetStatus = "Downloading"
        logger.notice("Starting user-requested speech asset download")
        Task {
            let snapshot = await assets.install(locale: locale) { [weak self] progress in
                Task { @MainActor in self?.observeAssetProgress(progress, generation: generation) }
            }
            let result = describe(snapshot)
            guard generation == assetStatusGeneration, locale.identifier == requestedLocale.identifier else { return }
            assetProgressObservation = nil; assetStatus = result
            logger.notice("Speech asset download completed: \(Self.assetStatusName(snapshot), privacy: .public)")
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
        guard cancellationCleanupTask == nil else { return }
        interpret(machine.handle(.interrupted))
    }

    private func discardVoiceInteraction(showFeedback: Bool) {
        guard cancellationCleanupTask == nil else { return }
        lifecycleGeneration &+= 1; armGeneration &+= 1
        let arming = armTask; arming?.cancel()
        finalizationTask?.cancel(); finalizationTask = nil
        analysisTask?.cancel(); analysisTask = nil; maxTimer?.invalidate(); maxTimer = nil
        observer?.setRecordingActive(false); pasteTarget = nil; partialTranscript = ""
        status = isEnabled ? .idle : .disabled
        if showFeedback { showTemporaryFeedback("Recording cancelled") }
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

    func reloadConfig() { ConfigurationCoordinator.shared.reload() }

    var hasManagedVoiceBindings: Bool {
        !VoiceBindingRestorePolicy.allows(managedKeys: managedKeys)
    }

    /// Restores all three Voice binding lists through one serialized, validated publication.
    /// Validation failure publishes none of the candidate settings. The preceding UserDefaults
    /// writes are individual persistence operations, not a crash-transactional commit.
    func restoreDefaultBindings() async -> String? {
        let previous = bindingCommitTail
        let operation = Task { @MainActor [weak self] () -> String? in
            _ = await previous?.value
            guard let self else { return "Voice settings are unavailable." }
            return await self.performDefaultBindingRestore()
        }
        bindingCommitTail = operation
        return await operation.value
    }

    private func performDefaultBindingRestore() async -> String? {
        guard !hasManagedVoiceBindings else {
            return "Default bindings cannot be restored while a Voice binding list is managed by configuration."
        }
        let builtIn = BuiltInSettings.standard
        logger.notice("Restoring default Voice bindings")
        do {
            _ = try await ConfigurationCoordinator.shared.stageAndReload(
                requiringUnmanaged: VoiceBindingAction.allCases,
                beforePublish: { @MainActor [weak self] _ in
                    guard let self else { throw CancellationError() }
                    try self.persistDefaultVoiceBindings(builtIn)
                },
                updatingLocal: { staged in
                    staged = staged.restoringDefaultVoiceBindings(builtIn)
                }
            )
            ConfigurationCoordinator.shared.clearDiagnostic()
            logger.notice("Default Voice bindings restored")
            return nil
        } catch {
            logger.error("Default Voice binding restore failed: \(Self.errorKind(error), privacy: .public)")
            let message = "Could not restore default bindings: \(String(describing: error))"
            ConfigurationCoordinator.shared.report(message)
            return message
        }
    }

    func acquireVoiceBindingCapture() -> VoiceBindingCaptureLease.Token {
        // Capturing a replacement binding is a privacy boundary. Finish any current session before
        // the lease starts; otherwise the lease's own stale-callback guard would also suppress the
        // balanced hold end emitted while live routes are suspended.
        cancelVoiceInteraction()
        let token = bindingCaptureLease.acquire()
        observation?.cancel(); observation = nil; observer = nil
        reconcileShortcutActivation()
        return token
    }

    func releaseVoiceBindingCapture(_ token: VoiceBindingCaptureLease.Token) {
        guard bindingCaptureLease.release(token) else { return }
        restoreRoutingAfterBindingCapture()
    }

    func cancelVoiceBindingCapture() {
        guard bindingCaptureLease.cancelAll() else { return }
        restoreRoutingAfterBindingCapture()
    }

    private func restoreRoutingAfterBindingCapture() {
        observerThresholdMs = nil; observerHoldBindings = nil; observerToggleBindings = nil; observerCancelBindings = nil
        recoverDegradedAndObserve()
    }

    func effectiveVoiceBindings(for action: VoiceBindingAction) -> [ShortcutDTO] {
        switch action { case .holdToTalk: return effective.holdToTalkBindings.value; case .toggleRecording: return effective.toggleRecordingBindings.value; case .cancel: return effective.cancelBindings.value }
    }

    func effectiveVoiceBinding(for action: VoiceBindingAction) -> ShortcutDTO { effectiveVoiceBindings(for: action).first ?? .unbound }

    /// Stages and validates through ConfigReloader before any persisted or live registration changes.
    /// The tail makes rapid captures linearizable; each candidate observes the prior successful commit.
    func commitVoiceBinding(_ dto: ShortcutDTO, action: VoiceBindingAction) async -> String? {
        await commitVoiceBindings(dto == .unbound ? [] : [dto], action: action)
    }

    func commitVoiceBindings(_ bindings: [ShortcutDTO], action: VoiceBindingAction) async -> String? {
        let previous = bindingCommitTail
        let operation = Task { @MainActor [weak self] () -> String? in
            _ = await previous?.value
            guard let self else { return "Voice settings are unavailable." }
            return await self.performVoiceBindingCommit(bindings, action: action)
        }
        bindingCommitTail = operation
        return await operation.value
    }

    private func performVoiceBindingCommit(_ bindings: [ShortcutDTO], action: VoiceBindingAction) async -> String? {
        let managed: Bool
        switch action { case .holdToTalk: managed = effective.holdToTalkShortcut.isManaged; case .toggleRecording: managed = effective.toggleRecordingShortcut.isManaged; case .cancel: managed = effective.cancelShortcut.isManaged }
        guard !managed else { return "This binding is managed by configuration." }
        if let issue = bindings.compactMap({ VoiceBindingPolicy.validate($0, for: action) }).first {
            return issue == .unsafeUnmodifiedKey
                ? "Hold and Toggle require Control, Option, or Command; Shift alone is unsafe."
                : "Fn modifier-only is available only for Hold to Talk."
        }
        let result: ConfigLoadResult
        do {
            result = try await ConfigurationCoordinator.shared.stageAndReload(
                requiringUnmanaged: [action],
                beforePublish: { @MainActor [weak self] candidate in
                    guard let self else { throw CancellationError() }
                    let accepted: ResolvedSetting<[ShortcutDTO]>
                    switch action {
                    case .holdToTalk: accepted = candidate.effective.holdToTalkBindings
                    case .toggleRecording: accepted = candidate.effective.toggleRecordingBindings
                    case .cancel: accepted = candidate.effective.cancelBindings
                    }
                    guard !accepted.isManaged, accepted.value == bindings else {
                        throw ConfigDiagnostic.invalidValue(
                            path: "voice.\(action.rawValue)Bindings",
                            reason: "became managed before the change completed"
                        )
                    }
                    try self.persistVoiceBindings(bindings, action: action)
                },
                updatingLocal: { staged in
                    switch action {
                    case .holdToTalk: staged.holdToTalkBindings = bindings
                    case .toggleRecording: staged.toggleRecordingBindings = bindings
                    case .cancel: staged.cancelBindings = bindings
                    }
                }
            )
        } catch let diagnostic as ConfigDiagnostic {
            let message = String(describing: diagnostic)
            ConfigurationCoordinator.shared.report(message)
            return message
        } catch {
            let message = "Could not validate the binding."
            ConfigurationCoordinator.shared.report(message)
            return message
        }
        let accepted: ResolvedSetting<[ShortcutDTO]>
        switch action { case .holdToTalk: accepted = result.effective.holdToTalkBindings; case .toggleRecording: accepted = result.effective.toggleRecordingBindings; case .cancel: accepted = result.effective.cancelBindings }
        guard !accepted.isManaged, accepted.value == bindings else { return "This binding became managed before the change completed." }
        ConfigurationCoordinator.shared.clearDiagnostic()
        return nil
    }

    private func persistVoiceBindings(_ bindings: [ShortcutDTO], action: VoiceBindingAction) throws {
        let data = try JSONEncoder().encode(bindings)
        let key: String
        switch action {
        case .holdToTalk: key = "hold"; unmanagedHoldBindings = bindings
        case .toggleRecording: key = "toggle"; unmanagedToggleBindings = bindings
        case .cancel: key = "cancel"; unmanagedCancelBindings = bindings
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "voice.binding.\(key).explicit")
        defaults.set(data, forKey: "voice.binding.\(key).value")
    }

    func restoreEffectivePasteLatestShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>) {
        let restored = try? shortcut.value.keyboardShortcut()
        KeyboardShortcuts.setShortcut(restored, for: .pasteLatestTranscript)
        if !shortcut.isManaged { unmanagedPasteLatestShortcut = restored }
    }

    func completeInitialConfiguration() async {
        await reconcileLegacyTranscriptForEffectiveHistory()
        hasResolvedInitialHistory = true
        TranscriptHistoryViewModel.shared.setHistoryEnabled(historyEnabled)
        if historyEnabled {
            await TranscriptHistoryViewModel.shared.reload(limit: TranscriptHistorySnapshot.menuPreviewCount)
        }
        logger.notice("Voice Transcription registration completed")
    }

    func applyConfiguration(_ value: EffectiveSettings) {
        let changed = value.changedKeys(from: effective)
        effective = value; managedKeys = Set(EffectiveSettings.Key.allCases.filter { key in
            switch key { case .keyboardCustomization: return false
            case .voiceEnabled: return value.voiceEnabled.isManaged
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
        settingsRevision &+= 1
    }

    private func reconcileObservation() {
        guard observerThresholdMs != effective.fnHoldThresholdMs.value || observerHoldBindings != effective.holdToTalkBindings.value || observerToggleBindings != effective.toggleRecordingBindings.value || observerCancelBindings != effective.cancelBindings.value else { return }
        guard case .idle = machine.state else { return }
        observation?.cancel(); observation = nil; observer = nil; observerThresholdMs = nil; observerHoldBindings = nil; observerToggleBindings = nil; observerCancelBindings = nil
        startObserving()
    }

    private func startObserving() {
        guard !bindingCaptureLease.isActive else { return }
        guard isEnabled, observation == nil else { if isEnabled, status == .disabled { status = .idle }; return }
        let bareHold: Bool = { if effective.holdToTalkBindings.value.contains(where: { if case .modifierHold = $0 { return true }; return false }) { return true }; return false }()
        var chords: [Int64: FnChordAction] = [:]
        func add(_ binding: ShortcutDTO, _ action: FnChordAction) { if case .fnChord(let key) = binding, let code = ShortcutDTO.keyCodes[key.lowercased()] { chords[code] = action } }
        effective.holdToTalkBindings.value.forEach { add($0, .hold) }; effective.toggleRecordingBindings.value.forEach { add($0, .toggle) }; effective.cancelBindings.value.forEach { add($0, .cancel) }
        guard bareHold || !chords.isEmpty else {
            logger.notice("Fn observation is unnecessary because no Fn bindings are active")
            if status == .disabled { status = .idle }
            return
        }
        guard CGPreflightListenEventAccess() else {
            logger.error("Fn observation blocked by missing Input Monitoring access")
            status = .degraded("Input Monitoring access is required")
            return
        }
        guard AXIsProcessTrusted() else {
            logger.error("Fn observation blocked by missing Accessibility access")
            status = .degraded("Accessibility access is required for Fn shortcuts")
            return
        }
        let observer = FnEventObserver(holdThreshold: Double(effective.fnHoldThresholdMs.value) / 1000, bareHoldEnabled: bareHold, chords: chords)
        do {
            observation = try observer.observe { [weak self] event in self?.handle(event) }
            self.observer = observer; observerThresholdMs = effective.fnHoldThresholdMs.value; observerHoldBindings = effective.holdToTalkBindings.value; observerToggleBindings = effective.toggleRecordingBindings.value; observerCancelBindings = effective.cancelBindings.value
            if status == .disabled { status = .idle }
            logger.notice("Fn observation started")
        } catch {
            logger.error("Fn observation could not create its event tap: \(Self.errorKind(error), privacy: .public)")
            status = .degraded("Input Monitoring access is required")
        }
    }

    private func handle(_ event: TriggerEvent) {
        // Observation teardown can already have queued delivery on the main queue.
        // Never let such a live shortcut affect recording while its key is being captured.
        guard isEnabled, !bindingCaptureLease.isActive else { return }
        logger.notice("Voice trigger received: \(Self.triggerName(event), privacy: .public)")
        if case .degraded = machine.state { _ = machine.handle(.resetDegraded) }
        if case .degraded = status { status = .idle }
        switch event {
        case .pushToTalkBegan: begin(mode: .pushToTalk)
        case .pushToTalkEnded: interpret(machine.handle(.pushToTalkEnded))
        case .toggleRequested: begin(mode: .latched)
        case .cancelRequested: cancelVoiceInteraction()
        case .secureInputBegan:
            logger.error("Secure input interrupted the active Voice interaction")
            observer?.setRecordingActive(false)
            interpret(machine.handle(.interrupted))
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
            case .discard: discardVoiceInteraction(showFeedback: true)
            case .stop(let session): finish(session)
            case .commit: break
            case .retry: break
            case .deletePending: deletePending()
            }
        }
    }

    private func cancelArming(_ session: VoiceSessionMachine.Session) {
        logger.notice("Voice arming cancelled")
        armGeneration &+= 1
        armTask?.cancel()
        armTask = nil
        if isEnabled { status = .idle }
    }

    private func arm(_ mode: VoiceSessionMachine.Mode, _ session: VoiceSessionMachine.Session) {
        switch status {
        case .idle, .noSpeech, .pasteFailed: break
        default: return
        }
        guard armTask == nil, captureTeardownTask == nil, cancellationCleanupTask == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            logger.error("Voice arming refused because Microphone access is unavailable")
            _ = machine.handle(.armingRefused(session, .permissionDenied)); status = .degraded("Microphone access is required"); return
        }
        logger.notice("Voice arming started: mode=\(Self.modeName(mode), privacy: .public)")
        status = .arming; armGeneration &+= 1; let generation = armGeneration
        let lifecycle = lifecycleGeneration
        armTask = Task { [weak self] in
            guard let self else { return }
            var armingCapture: AudioCaptureService?
            do {
                let device = try DeviceSelector(devices: DeviceTable(), bluetooth: BluetoothLinkOracle()).select(
                    priorities: devicePriority.map { AudioDevicePreference(uid: $0.uid, exactName: $0.name) }, allowSystemDefaultFallback: fallbackToSystemDefault)
                logger.notice("Voice input selected: transport=\(Self.transportName(device.transport), privacy: .public)")
                let requested = requestedLocale
                guard let locale = await assets.resolve(requested) else { throw VoiceSessionMachine.DegradedReason.unsupportedLocale }
                logger.notice("Speech locale resolved")
                guard await assets.status(locale: locale) == .installed else { throw VoiceSessionMachine.DegradedReason.assetsMissing }
                logger.notice("Required speech asset is installed")
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
                logger.notice("Voice recording started")
                analysisTask = Task { [weak self, capture] in
                    do { try await transcriber.start(buffers: stream.buffers) { update in Task { @MainActor in
                        guard let self else { return }
                        let currentSession: UUID? = { if case .recording(_, let active) = self.machine.state { return active.id }; return nil }()
                        guard VoicePartialUpdatePolicy.allows(capturedLifecycle: lifecycle, currentLifecycle: self.lifecycleGeneration,
                                                              expectedSession: session.id, currentRecordingSession: currentSession) else { return }
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
                logger.error("Voice arming failed: \(Self.errorKind(error), privacy: .public)")
                armTask = nil; _ = machine.handle(.armingRefused(session, Self.degradedReason(error)))
                status = .degraded(Self.degradedMessage(error))
            }
        }
    }

    private func finish(_ session: VoiceSessionMachine.Session) {
        guard status == .recording, finalizationTask == nil else { return }
        logger.notice("Voice recording stopping for finalization")
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
                logger.notice("Speech finalization completed")
                try await commit(text, target: pasteTarget, recovery: .active, sessionID: session.id,
                                 localeIdentifier: self.transcriberResolvedLocaleIdentifier ?? session.localeIdentifier, generation: generation)
            } catch is CancellationError {
                // Lifecycle teardown owns state and recovery.
            } catch {
                guard generation == lifecycleGeneration else { return }
                logger.error("Voice finalization failed: \(Self.errorKind(error), privacy: .public)")
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
            logger.notice("Voice commit completed with no recognized speech")
            switch recovery {
            case .active: try store.clearActive()
            case .pending: try store.deletePending(); try store.clearActive()
            }
            partialTranscript = ""; _ = machine.handle(.committed); status = .noSpeech
            transcriber = nil
            Task { try? await Task.sleep(for: .seconds(2)); if status == .noSpeech { status = .idle } }
            reconcileObservation()
            return
        }
        let shouldAutoPaste = outputMode == .pasteImmediately
        logger.notice("Voice commit started: history=\(self.historyEnabled, privacy: .public), autoPaste=\(shouldAutoPaste, privacy: .public)")
        let result = try await TranscriptCommitter().commit(
            clean,
            settings: .init(autoPaste: false,
                            recordHistory: historyEnabled, sessionID: sessionID,
                            localeIdentifier: localeIdentifier,
                            historySource: { if case .pending = recovery { return .recovery }; return .live }(),
                            historyRetention: historyRetentionPolicy),
            targetPID: verifiedTarget
        )
        guard generation == lifecycleGeneration, !Task.isCancelled else { throw CancellationError() }
        var pasteError = result.pasteError
        if shouldAutoPaste {
            switch CapturedTargetVerifier(dependencies: .live).verify(target) {
            case .valid(let pid):
                do {
                    try await PasteService().paste(text: clean, targetPID: pid)
                    logger.notice("Automatic paste event posted to the verified target")
                } catch {
                    logger.error("Automatic paste failed: \(Self.errorKind(error), privacy: .public)")
                    pasteError = error
                }
            case .rejected:
                logger.error("Automatic paste refused because the captured target is no longer trusted")
                pasteError = PasteError.noTargetApplication
            }
        }
        guard generation == lifecycleGeneration, !Task.isCancelled else { throw CancellationError() }
        lastTranscript = clean
        if historyEnabled { await TranscriptHistoryViewModel.shared.reload() }
        partialTranscript = ""; _ = machine.handle(.committed)
        if let error = pasteError {
            logger.error("Voice commit completed with a paste failure: \(Self.errorKind(error), privacy: .public)")
            status = .pasteFailed(error.localizedDescription)
            Task { try? await Task.sleep(for: .seconds(3)); if case .pasteFailed = status { status = .idle } }
        } else {
            logger.notice("Voice commit completed")
            status = .idle
        }
        transcriber = nil; reconcileObservation()
    }

    private func captureFailed(_ error: Error) async {
        logger.error("Voice capture or analysis failed: \(Self.errorKind(error), privacy: .public)")
        capture?.stop()
        _ = await analysisTask?.value
        capture = nil; analysisTask = nil
        await transcriber?.cancel(); transcriber = nil

        maxTimer?.invalidate(); maxTimer = nil
        let pending = ((try? store.loadPending()) ?? nil) ?? (try? store.promoteActive(failureReason: String(describing: error)))
        if let pending {
            logger.error("Voice failure preserved one pending recovery recording")
            _ = machine.handle(.failed(.init(id: pending.metadata.sessionID, audioURL: pending.audioURL))); status = .pending
        } else {
            logger.error("Voice failure could not preserve a pending recovery recording")
            status = .failed(error.localizedDescription)
        }
        partialTranscript = ""
    }

    private func reconcileRecovery() {
        if case .pending(let p) = try? Reconciliation.run(store: store) {
            logger.notice("Recovered one pending Voice recording at launch")
            _ = machine.handle(.recovered(.init(id: p.metadata.sessionID, audioURL: p.audioURL))); status = .pending
        }
    }

    private func stopForMaximumDuration() {
        guard case .recording(let mode, let session) = machine.state else { return }
        logger.notice("Voice recording reached its configured maximum duration")
        interpret(machine.handle(VoiceSessionMachine.maximumStopEvent(mode: mode, session: session)))
    }

    private func persistDefaultVoiceBindings(_ builtIn: BuiltInSettings) throws {
        let encoder = JSONEncoder()
        // Encode every value before mutating persistence, so encoding failure leaves
        // all three customized lists intact.
        let encoded: [(key: String, data: Data)] = [
            ("hold", try encoder.encode(builtIn.holdToTalkBindings)),
            ("toggle", try encoder.encode(builtIn.toggleRecordingBindings)),
            ("cancel", try encoder.encode(builtIn.cancelBindings))
        ]
        let defaults = UserDefaults.standard
        for entry in encoded {
            defaults.set(true, forKey: "voice.binding.\(entry.key).explicit")
            defaults.set(entry.data, forKey: "voice.binding.\(entry.key).value")
        }
        unmanagedHoldBindings = builtIn.holdToTalkBindings
        unmanagedToggleBindings = builtIn.toggleRecordingBindings
        unmanagedCancelBindings = builtIn.cancelBindings
    }

    func readVoiceLocalSettings() -> VoiceLocalSettings {
        let defaults = UserDefaults.standard
        let persistedDevices = defaults.data(forKey: "voice.devices")
            .flatMap { try? JSONDecoder().decode([InputDeviceDTO].self, from: $0) } ?? []
        return VoiceLocalSettings(
            enabled: defaults.bool(forKey: "voice.enabled"),
            holdToTalkBindings: unmanagedHoldBindings,
            toggleRecordingBindings: unmanagedToggleBindings,
            cancelBindings: unmanagedCancelBindings,
            pasteLatestTranscriptShortcut: persistedPasteLatestTranscriptShortcut,
            outputMode: VoiceOutputMode(rawValue: defaults.string(forKey: "voice.outputMode") ?? "") ?? .pasteImmediately,
            historyEnabled: defaults.bool(forKey: VoiceHistoryPreferences.enabledKey),
            historyRetentionDays: defaults.integer(forKey: VoiceHistoryPreferences.retentionDaysKey),
            historyMaxEntries: defaults.integer(forKey: VoiceHistoryPreferences.maxEntriesKey),
            locale: defaults.string(forKey: "voice.locale") ?? "system",
            inputDevicePriority: persistedDevices,
            fallbackToSystemDefault: defaults.bool(forKey: "voice.fallback")
        )
    }

    private func recoverDegradedAndObserve() {
        reconcileShortcutActivation()
        if case .degraded = machine.state { _ = machine.handle(.resetDegraded) }
        if case .degraded = status { status = .idle }
        reconcileObservation()
    }

    func handleStandardBindingEvent(_ event: VoiceBindingRouter.Event) {
        guard isEnabled, !bindingCaptureLease.isActive else { return }
        logger.notice("Standard Voice binding event: \(Self.bindingEventName(event), privacy: .public)")
        switch event {
        case .holdBegan: begin(mode: .pushToTalk)
        case .holdEnded: interpret(machine.handle(.pushToTalkEnded))
        case .toggleRequested: begin(mode: .latched)
        case .cancelRequested: cancelVoiceInteraction()
        }
    }

    private var requestedLocale: Locale { localeIdentifier == "system" ? .current : Locale(identifier: localeIdentifier) }

    private func applyVoiceShortcuts(_ value: EffectiveSettings) {
        unmanagedHoldBindings = applyManagedVoiceBindings(value.holdToTalkBindings, action: .holdToTalk, key: "hold", unmanaged: unmanagedHoldBindings)
        unmanagedToggleBindings = applyManagedVoiceBindings(value.toggleRecordingBindings, action: .toggleRecording, key: "toggle", unmanaged: unmanagedToggleBindings)
        unmanagedCancelBindings = applyManagedVoiceBindings(value.cancelBindings, action: .cancel, key: "cancel", unmanaged: unmanagedCancelBindings)
        reconcileShortcutActivation()
    }

    private func applyManagedVoiceBindings(_ binding: ResolvedSetting<[ShortcutDTO]>, action: VoiceBindingAction,
                                           key: String, unmanaged: [ShortcutDTO]?) -> [ShortcutDTO]? {
        let defaults = UserDefaults.standard
        let persistenceKey = "voice.binding.\(key)"
        var local = unmanaged
        if binding.isManaged && !defaults.bool(forKey: "\(persistenceKey).backupActive") {
            VoiceBindingPersistence.saveManagedBackup(local, in: defaults, key: persistenceKey)
        } else if !binding.isManaged && defaults.bool(forKey: "\(persistenceKey).backupActive") {
            local = VoiceBindingPersistence.restoreManagedBackup(in: defaults, key: persistenceKey)
            defaults.set(local != nil, forKey: "\(persistenceKey).explicit")
            if let local, let data = try? JSONEncoder().encode(local) {
                defaults.set(data, forKey: "\(persistenceKey).value")
            } else {
                defaults.removeObject(forKey: "\(persistenceKey).value")
            }
        }
        let active = binding.isManaged ? binding.value : (local ?? binding.value)
        for index in 0..<KeyboardShortcuts.Name.voiceBindingSlotCount {
            let dto = index < active.count ? active[index] : .unbound
            KeyboardShortcuts.setShortcut(try? dto.keyboardShortcut(), for: .voiceBindingSlot(action: action, index: index))
        }
        return local
    }

    private static func localVoiceBindings(_ name: KeyboardShortcuts.Name, key: String) -> [ShortcutDTO]? {
        let defaults = UserDefaults.standard, dataKey = "voice.binding.\(key).backup"
        if defaults.bool(forKey: "voice.binding.\(key).backupActive") {
            return VoiceBindingPersistence.localBindings(explicit: true, canonicalData: defaults.data(forKey: dataKey), legacyValue: nil)
        }
        let explicit = defaults.bool(forKey: "voice.binding.\(key).explicit")
        let legacy = KeyboardShortcuts.getShortcut(for: name).flatMap(ShortcutDTO.fromKeyboardShortcut)
        guard let migrated = VoiceBindingPersistence.localBindings(explicit: explicit, canonicalData: defaults.data(forKey: "voice.binding.\(key).value"), legacyValue: legacy) else { return nil }
        if defaults.data(forKey: "voice.binding.\(key).value") == nil, let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: "voice.binding.\(key).value") }
        return migrated
    }

    private func reconcileShortcutActivation() {
        let phase: VoiceInteractionPhase
        switch status { case .arming: phase = .arming; case .recording: phase = .recording; case .finalizing: phase = .finalizing; case .idle, .noSpeech, .pasteFailed, .degraded: phase = .idle; default: phase = .unavailable }
        let policy = VoiceShortcutActivationPolicy.decide(moduleEnabled: isEnabled, phase: phase)
        InputRoutingCoordinator.shared.setVoiceActivation(
            moduleEnabled: isEnabled,
            policy: policy,
            captureIsActive: bindingCaptureLease.isActive
        )
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
        let interaction: VoiceInteractionPhase
        switch status { case .arming: interaction = .arming; case .recording: interaction = .recording; case .finalizing: interaction = .finalizing; default: interaction = .idle }
        let phase: VoiceOverlayPresentation.Phase
        switch VoiceOverlayPolicy.presentation(for: interaction) {
        case .hidden: phase = .hidden
        case .arming: phase = .arming
        case .recording: phase = .recording
        case .finalizing: phase = .finalizing
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

    private static func triggerName(_ event: TriggerEvent) -> String {
        switch event {
        case .pushToTalkBegan: "push-to-talk-began"
        case .pushToTalkEnded: "push-to-talk-ended"
        case .toggleRequested: "toggle-requested"
        case .cancelRequested: "cancel-requested"
        case .secureInputBegan: "secure-input-began"
        }
    }

    private static func modeName(_ mode: VoiceSessionMachine.Mode) -> String {
        switch mode { case .pushToTalk: "push-to-talk"; case .latched: "latched" }
    }

    private static func bindingEventName(_ event: VoiceBindingRouter.Event) -> String {
        switch event {
        case .holdBegan: "hold-began"
        case .holdEnded: "hold-ended"
        case .toggleRequested: "toggle-requested"
        case .cancelRequested: "cancel-requested"
        }
    }

    private static func transportName(_ transport: AudioInputDevice.Transport) -> String {
        switch transport { case .builtIn: "built-in"; case .usb: "usb"; case .bluetooth: "bluetooth"; case .other: "other" }
    }

    private static func assetStatusName(_ status: VoiceAssetManager.Status) -> String {
        switch status {
        case .unsupported: "unsupported"
        case .missing: "missing"
        case .downloading: "downloading"
        case .installed: "installed"
        case .failure: "failure"
        }
    }

    /// Error values can contain device names, paths, or framework diagnostics. Logs retain only
    /// the concrete error type so a hardware run is diagnosable without recording user data.
    private static func errorKind(_ error: Error) -> String {
        String(reflecting: type(of: error))
    }

    private func persist(_ key: String, _ value: Any) { if !applying { UserDefaults.standard.set(value, forKey: key) } }
    private func persistAndReconfigure(_ key: String, _ value: Bool) { persist(key, value); if !applying { value ? recoverDegradedAndObserve() : stop() } }
    private func saveDevices() { if !applying, let data = try? JSONEncoder().encode(devicePriority) { UserDefaults.standard.set(data, forKey: "voice.devices") } }
    private func describe(_ value: VoiceAssetManager.Status) -> String {
        switch value { case .unsupported: return "Unsupported language"; case .missing: return "Download required"; case .downloading: return "Downloading"; case .installed: return "Installed"; case .failure(let message): return "Download failed: \(message)" }
    }
}

extension VoiceTranscriptionModule: VoiceLocalSettingsAdapter {
    func acceptUnmanagedVoicePasteLatestShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        unmanagedPasteLatestShortcut = shortcut
    }

    func restoreUnmanagedVoicePasteLatestShortcut() {
        KeyboardShortcuts.setShortcut(unmanagedPasteLatestShortcut, for: .pasteLatestTranscript)
    }

    func restoreVoicePasteLatestShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>) {
        restoreEffectivePasteLatestShortcut(shortcut)
    }
}
