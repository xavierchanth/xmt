import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Foundation

/// Main-actor lifecycle and effect coordinator for Voice Transcription.
@MainActor
final class VoiceTranscriptionModule: ObservableObject {
    static let shared = VoiceTranscriptionModule()

    enum Status: Equatable {
        case disabled, idle, recording, finalizing, pending, degraded(String), failed(String)
    }

    @Published private(set) var status: Status = .disabled
    @Published private(set) var partialTranscript = ""
    @Published private(set) var lastTranscript = ""
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published private(set) var assetStatus = "Not checked"
    @Published private(set) var configDiagnostic: String?
    @Published private(set) var managedKeys: Set<EffectiveSettings.Key> = []
    @Published var isEnabled: Bool { didSet { persistAndReconfigure("voice.enabled", isEnabled) } }
    @Published var autoPaste: Bool { didSet { persist("voice.autoPaste", autoPaste) } }
    @Published var keepLastTranscript: Bool { didSet { persist("voice.keepLastTranscript", keepLastTranscript) } }
    @Published var fallbackToSystemDefault: Bool { didSet { persist("voice.fallback", fallbackToSystemDefault) } }
    @Published var localeIdentifier: String { didSet { persist("voice.locale", localeIdentifier) } }
    @Published var devicePriority: [InputDeviceDTO] { didSet { saveDevices() } }

    private var machine = VoiceSessionMachine()
    private var observer: FnEventObserver?
    private var observation: FnEventObserver.Observation?
    private var capture: AudioCaptureService?
    private var transcriber: TranscriberSession?
    private var analysisTask: Task<Void, Never>?
    private var maxTimer: Timer?
    private var targetPID: pid_t?
    private let store = PendingRecordingStore()
    private let assets = VoiceAssetManager()
    private var effective = EffectiveSettings.resolve(config: nil)
    private var reloader: ConfigReloader?
    private var applying = false

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: ["voice.enabled": true, "voice.autoPaste": true, "voice.keepLastTranscript": true,
                              "voice.fallback": true, "voice.locale": "en-US"])
        isEnabled = d.bool(forKey: "voice.enabled"); autoPaste = d.bool(forKey: "voice.autoPaste")
        keepLastTranscript = d.bool(forKey: "voice.keepLastTranscript"); fallbackToSystemDefault = d.bool(forKey: "voice.fallback")
        localeIdentifier = d.string(forKey: "voice.locale") ?? "en-US"
        devicePriority = (d.data(forKey: "voice.devices").flatMap { try? JSONDecoder().decode([InputDeviceDTO].self, from: $0) }) ?? []
    }

    func register() {
        reconcileRecovery()
        Task { await configureAndReload() }
    }

    func stop() {
        observation?.cancel(); observation = nil; observer = nil
        maxTimer?.invalidate(); maxTimer = nil
        capture?.stop(); capture = nil
        analysisTask?.cancel(); analysisTask = nil
        if let transcriber { Task { await transcriber.cancel(); await assets.releaseReservation() } }
        transcriber = nil; partialTranscript = ""
        if status != .pending { status = .disabled }
    }

    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = CGRequestListenEventAccess()
        if autoPaste { AccessibilityService.shared.requestIfNeeded() }
    }

    func refreshDevices() {
        availableDevices = (try? DeviceTable().inputDevices())?.filter(\.hasInput) ?? []
    }

    func refreshAssets() { Task { assetStatus = describe(await assets.status(locale: Locale(identifier: localeIdentifier))) } }
    func downloadAssets() {
        assetStatus = "Downloading"
        Task { assetStatus = describe(await assets.install(locale: Locale(identifier: localeIdentifier)) { _ in }) }
    }

    func copyLastTranscript() { guard !lastTranscript.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lastTranscript, forType: .string) }

    func retryPending() {
        guard case .pending = status, let pending = (try? store.loadPending()) ?? nil else { return }
        status = .finalizing; partialTranscript = ""
        Task {
            do {
                let text = try await TranscriberSession.retry(fileURL: pending.audioURL, locale: Locale(identifier: pending.metadata.localeIdentifier)) { [weak self] update in
                    Task { @MainActor in self?.partialTranscript = update.text }
                }
                try await commit(text, target: nil)
            } catch { status = .failed(error.localizedDescription) }
        }
    }

    func deletePending() { try? store.deletePending(); machine = VoiceSessionMachine(); status = isEnabled ? .idle : .disabled }

    func stopRecording() {
        guard case .recording(let mode, let session) = machine.state else { return }
        if mode == .latched { interpret(machine.handle(.toggle(session))) }
        else { interpret(machine.handle(.pushToTalkEnded)) }
    }

    func reloadConfig() { Task { await loadConfig() } }

    private func configureAndReload() async {
        let local = SettingsValues(voiceEnabled: isEnabled, autoPaste: autoPaste, keepLastTranscript: keepLastTranscript,
                                   locale: localeIdentifier, inputDevicePriority: devicePriority,
                                   fallbackToSystemDefault: fallbackToSystemDefault)
        let loader = ConfigReloader(local: local)
        reloader = loader
        await loader.addApplyCallback { [weak self] result in await self?.apply(result.effective) }
        await loadConfig()
    }

    private func loadConfig() async {
        guard let reloader else { return }
        do { _ = try await reloader.reload(); configDiagnostic = nil }
        catch { configDiagnostic = String(describing: error) }
    }

    private func apply(_ value: EffectiveSettings) {
        effective = value; managedKeys = Set(EffectiveSettings.Key.allCases.filter { key in
            switch key { case .voiceEnabled: return value.voiceEnabled.isManaged; case .autoPaste: return value.autoPaste.isManaged
            case .keepLastTranscript: return value.keepLastTranscript.isManaged; case .locale: return value.locale.isManaged
            case .inputDevicePriority: return value.inputDevicePriority.isManaged; case .fallbackToSystemDefault: return value.fallbackToSystemDefault.isManaged
            default: return false }
        })
        applying = true
        isEnabled = value.voiceEnabled.value; autoPaste = value.autoPaste.value; keepLastTranscript = value.keepLastTranscript.value
        localeIdentifier = value.locale.value; devicePriority = value.inputDevicePriority.value; fallbackToSystemDefault = value.fallbackToSystemDefault.value
        applying = false
        if isEnabled { startObserving() } else { stop() }
        WindowMoverModule.shared.applyManaged(enabled: value.windowMoverEnabled, shortcut: value.windowMoverShortcut)
    }

    private func startObserving() {
        guard isEnabled, observation == nil else { if isEnabled, status == .disabled { status = .idle }; return }
        let observer = FnEventObserver(holdThreshold: Double(effective.fnHoldThresholdMs.value) / 1000)
        do {
            observation = try observer.observe { [weak self] event in self?.handle(event) }
            self.observer = observer
            if status == .disabled { status = .idle }
        } catch { status = .degraded("Input Monitoring access is required") }
    }

    private func handle(_ event: TriggerEvent) {
        guard isEnabled else { return }
        switch event {
        case .pushToTalkBegan: begin(mode: .pushToTalk)
        case .pushToTalkEnded: interpret(machine.handle(.pushToTalkEnded))
        case .toggleRequested: begin(mode: .latched)
        }
    }

    private func begin(mode: VoiceSessionMachine.Mode) {
        let session = VoiceSessionMachine.Session(id: UUID(), startedAt: Date(), localeIdentifier: localeIdentifier)
        interpret(machine.handle(mode == .pushToTalk ? .pushToTalkBegan(session) : .toggle(session)))
    }

    private func interpret(_ outcome: VoiceSessionMachine.Outcome) {
        guard case .accepted(let commands) = outcome else { return }
        for command in commands {
            switch command { case .arm(let mode, let session): arm(mode, session); case .stop(let session): finish(session)
            case .commit: break; case .retry: break; case .deletePending: deletePending() }
        }
    }

    private func arm(_ mode: VoiceSessionMachine.Mode, _ session: VoiceSessionMachine.Session) {
        guard status == .idle, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { status = .degraded("Microphone access is required"); return }
        do {
            let device = try DeviceSelector(devices: DeviceTable(), bluetooth: BluetoothLinkOracle()).select(
                priorities: devicePriority.map { AudioDevicePreference(uid: $0.uid, exactName: $0.name) }, allowSystemDefaultFallback: fallbackToSystemDefault)
            let url = try store.prepareActive(.init(sessionID: session.id, timestamp: session.startedAt, localeIdentifier: session.localeIdentifier, failureReason: "active"))
            let locale = Locale(identifier: session.localeIdentifier)
            guard try trySyncAwait({ try await self.assets.reserve(locale: locale) }) else {
                status = .degraded("Speech assets are not installed"); return
            }
            let transcriber = try trySyncAwait { try await TranscriberSession(locale: locale) }
            let capture = AudioCaptureService(); let stream = try capture.start(device: device, recoveryURL: url)
            self.capture = capture; self.transcriber = transcriber; targetPID = PasteService.frontmostPID(); partialTranscript = ""
            _ = machine.handle(.armed(mode, session)); status = .recording
            analysisTask = Task { [weak self] in
                do { try await transcriber.start(buffers: stream.buffers) { update in Task { @MainActor in self?.partialTranscript = update.text } } }
                catch { await MainActor.run { self?.captureFailed(error) } }
            }
            maxTimer = Timer.scheduledTimer(withTimeInterval: Double(effective.maxSessionSeconds.value), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finish(session) }
            }
        } catch {
            status = .degraded(error.localizedDescription)
            Task { await assets.releaseReservation() }
        }
    }

    private func finish(_ session: VoiceSessionMachine.Session) {
        guard status == .recording else { return }; status = .finalizing
        maxTimer?.invalidate(); maxTimer = nil; capture?.stop(); capture = nil
        Task {
            do { let text = try await transcriber?.finish() ?? ""; _ = machine.handle(.finalized(session)); try await commit(text, target: targetPID) }
            catch { captureFailed(error) }
        }
    }

    private func commit(_ text: String, target: pid_t?) async throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        _ = try await TranscriptCommitter().commit(clean, settings: .init(keepLastTranscript: keepLastTranscript, autoPaste: autoPaste), targetPID: target)
        lastTranscript = clean; partialTranscript = ""; _ = machine.handle(.committed); status = .idle
        transcriber = nil; await assets.releaseReservation()
    }

    private func captureFailed(_ error: Error) {
        capture?.stop(); capture = nil; transcriber = nil; maxTimer?.invalidate(); maxTimer = nil
        if let pending = try? store.promoteActive(failureReason: String(describing: error)) {
            _ = machine.handle(.failed(.init(id: pending.metadata.sessionID, audioURL: pending.audioURL))); status = .pending
        } else { status = .failed(error.localizedDescription) }
        partialTranscript = ""
    }

    private func reconcileRecovery() {
        if case .pending(let p) = try? Reconciliation.run(store: store) {
            _ = machine.handle(.recovered(.init(id: p.metadata.sessionID, audioURL: p.audioURL))); status = .pending
        }
    }

    private func persist(_ key: String, _ value: Any) { if !applying { UserDefaults.standard.set(value, forKey: key) } }
    private func persistAndReconfigure(_ key: String, _ value: Bool) { persist(key, value); if !applying { value ? startObserving() : stop() } }
    private func saveDevices() { if !applying, let data = try? JSONEncoder().encode(devicePriority) { UserDefaults.standard.set(data, forKey: "voice.devices") } }
    private func describe(_ value: VoiceAssetManager.Status) -> String { String(describing: value) }
}

/// Bridges an async initializer before capture starts. The run loop remains responsive and no OS action is performed.
@MainActor private func trySyncAwait<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0); var result: Result<T, Error>!
    Task.detached { do { result = .success(try await operation()) } catch { result = .failure(error) }; semaphore.signal() }
    while semaphore.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001)) }
    return try result.get()
}
