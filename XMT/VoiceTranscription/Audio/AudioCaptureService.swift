import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

public enum AudioCaptureError: Error {
    case unknownDeviceUID(String)
    case busy
    case invalidAudioUnit
    case invalidFormat
    case deviceBindingFailed(OSStatus)
    case engineStartFailed(Error)
    case recoveryFileFailed(Error)
    case realtimeCopyFailed(recoveryURL: URL)
    case firstBufferDeadline(recoveryURL: URL)
    case deviceLost(recoveryURL: URL)
    case configurationChanged(recoveryURL: URL)
    case handoffOverflow(recoveryURL: URL)
    case outputOverflow(recoveryURL: URL)
}

/// One-device capture. Lifecycle is serialized on `control`; the tap only copies and offers into
/// a bounded channel. CAF I/O precedes publication of each corresponding analyzer buffer.
public final class AudioCaptureService: @unchecked Sendable {
    public struct Session {
        public let device: AudioInputDevice
        public let recoveryURL: URL
        public let buffers: BoundedAudioQueue<AVAudioPCMBuffer>
    }

    private let control = DispatchQueue(label: "XMT.AudioCapture.control")
    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "VoiceCapture")
    private let controlKey = DispatchSpecificKey<UInt8>()
    private var engine: AVAudioEngine?
    private var handoff: BoundedAudioQueue<AVAudioPCMBuffer>?
    private var output: BoundedAudioQueue<AVAudioPCMBuffer>?
    private var worker: Task<Void, Never>?
    private var deadline: DispatchWorkItem?
    private var observer: NSObjectProtocol?
    private var url: URL?
    private var boundDeviceID = kAudioObjectUnknown
    private var generation: UInt64 = 0
    private var firstBufferSeen = false
    private var terminalError: AudioCaptureError?
    private var draining = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init() { control.setSpecific(key: controlKey, value: 1) }
    deinit {
        if DispatchQueue.getSpecific(key: controlKey) != nil { beginStop(nil) }
        else { control.sync { beginStop(nil) } }
    }

    public func start(device: AudioInputDevice, recoveryURL: URL,
                      queueCapacity: Int = 32, firstBufferDeadline: TimeInterval = 1) throws -> Session {
        try control.sync {
            logger.notice("Audio capture start requested")
            guard engine == nil, !draining else { throw AudioCaptureError.busy }
            let id = try deviceID(forUID: device.uid)
            let engine = AVAudioEngine(); let input = engine.inputNode
            guard let unit = input.audioUnit else { throw AudioCaptureError.invalidAudioUnit }
            var mutableID = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &mutableID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioCaptureError.deviceBindingFailed(status) }
            // A tap format differing from the bound input graph can raise an Objective-C
            // exception. V1 therefore exposes no requested format and uses the hardware format.
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
                throw AudioCaptureError.invalidFormat
            }
            var recoveryFile: AVAudioFile?
            do { recoveryFile = try AVAudioFile(forWriting: recoveryURL, settings: format.settings,
                                                 commonFormat: format.commonFormat, interleaved: format.isInterleaved) }
            catch { throw AudioCaptureError.recoveryFileFailed(error) }

            generation &+= 1; let token = generation
            let handoff = BoundedAudioQueue<AVAudioPCMBuffer>(capacity: queueCapacity) {
                AudioCaptureError.handoffOverflow(recoveryURL: recoveryURL)
            }
            let output = BoundedAudioQueue<AVAudioPCMBuffer>(capacity: queueCapacity) {
                AudioCaptureError.outputOverflow(recoveryURL: recoveryURL)
            }
            self.engine = engine; self.handoff = handoff; self.output = output; url = recoveryURL
            boundDeviceID = id; firstBufferSeen = false; terminalError = nil; draining = false

            // AVAudioEngine invokes a tap serially. This callback-local latch avoids dispatching
            // one control operation per buffer while serialized state remains authoritative.
            var firstTapDelivered = false
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                guard let copy = Self.copy(buffer) else {
                    self.requestFailure(.realtimeCopyFailed(recoveryURL: recoveryURL), token: token); return
                }
                switch handoff.send(copy) {
                case .success where !firstTapDelivered:
                    firstTapDelivered = true
                    self.control.async { [weak self] in
                        guard let self, generation == token, !firstBufferSeen else { return }
                        firstBufferSeen = true; deadline?.cancel(); deadline = nil
                        logger.notice("Audio capture received its first buffer")
                    }
                case .success: break
                case .failure(let error):
                    self.requestFailure((error as? AudioCaptureError) ?? .handoffOverflow(recoveryURL: recoveryURL), token: token)
                }
            }
            // The drain task is the explicit lifetime token: it retains the service until every
            // accepted buffer is written and output termination is published. `workerFinished`
            // then clears `worker`, breaking the temporary cycle. Callers must still call stop;
            // coordinator ownership is the primary lifetime guarantee.
            worker = Task { [self, handoff, output] in
                var failure: AudioCaptureError?
                do {
                    for try await buffer in handoff {
                        guard let file = recoveryFile else { break }
                        try file.write(from: buffer)
                        if failure == nil, case .failure(let error) = output.send(buffer) {
                            failure = (error as? AudioCaptureError) ?? .outputOverflow(recoveryURL: recoveryURL)
                        }
                    }
                } catch let error as AudioCaptureError { failure = error }
                catch { failure = .recoveryFileFailed(error) }
                // Closing the last strong reference finalizes the CAF before terminal publication.
                recoveryFile = nil
                self.control.async { [weak self] in self?.workerFinished(failure, token: token) }
            }
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: engine, queue: nil) { [weak self] _ in
                self?.control.async { [weak self] in self?.configurationChanged(token: token) }
            }
            let item = DispatchWorkItem { [weak self] in self?.control.async { [weak self] in
                guard let self, generation == token, !firstBufferSeen, self.engine != nil else { return }
                requestFailureOnControl(.firstBufferDeadline(recoveryURL: recoveryURL))
            } }
            deadline = item; DispatchQueue.global().asyncAfter(deadline: .now() + firstBufferDeadline, execute: item)
            do {
                try engine.start()
                logger.notice("Audio capture engine started")
            } catch {
                logger.error("Audio capture engine failed to start")
                beginStop(.engineStartFailed(error))
                throw AudioCaptureError.engineStartFailed(error)
            }
            return Session(device: device, recoveryURL: recoveryURL, buffers: output)
        }
    }

    public func stop() { control.async { [weak self] in self?.beginStop(nil) } }

    public func stopAndWait() async {
        await withCheckedContinuation { continuation in
            control.async { [weak self] in
                guard let self else { continuation.resume(); return }
                beginStop(nil)
                if !draining { continuation.resume() }
                else { stopWaiters.append(continuation) }
            }
        }
    }

    private func requestFailure(_ error: AudioCaptureError, token: UInt64) {
        control.async { [weak self] in guard let self, generation == token else { return }; requestFailureOnControl(error) }
    }
    private func requestFailureOnControl(_ error: AudioCaptureError) {
        logger.error("Audio capture failed: \(Self.failureName(error), privacy: .public)")
        beginStop(error)
    }

    /// Stops producers immediately, then lets the sole worker drain every accepted buffer.
    private func beginStop(_ error: AudioCaptureError?) {
        if terminalError == nil { terminalError = error }
        guard let engine else { return }
        logger.notice("Audio capture stopping")
        self.engine = nil; draining = true
        deadline?.cancel(); deadline = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        handoff?.finish(); handoff = nil
    }

    private func workerFinished(_ workerError: AudioCaptureError?, token: UInt64) {
        guard generation == token else { return }
        let error = terminalError ?? workerError
        if let error {
            logger.error("Audio capture drain completed with failure: \(Self.failureName(error), privacy: .public)")
        } else {
            logger.notice("Audio capture drain completed")
        }
        if let error { output?.finish(throwing: error) } else { output?.finish() }
        output = nil; worker = nil; url = nil; boundDeviceID = kAudioObjectUnknown
        terminalError = nil; draining = false
        let waiters = stopWaiters; stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func configurationChanged(token: UInt64) {
        guard generation == token, let engine, let url else { return }
        // Benign graph notifications while capture remains running need no action. A stopped graph
        // must never leave its streams parked: v1 terminates rather than attempting graph restart.
        guard !engine.isRunning else { return }
        if deviceIsAlive(boundDeviceID) {
            requestFailureOnControl(.configurationChanged(recoveryURL: url))
        } else {
            requestFailureOnControl(.deviceLost(recoveryURL: url))
        }
    }

    private func deviceIsAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var alive: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(sourceList.count, destination.count) {
            guard let from = sourceList[index].mData, let to = destination[index].mData else { return nil }
            memcpy(to, from, Int(sourceList[index].mDataByteSize)); destination[index].mDataByteSize = sourceList[index].mDataByteSize
        }
        return copy
    }

    private func deviceID(forUID uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var qualifier: CFString = uid as CFString
        var id = kAudioObjectUnknown, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        guard status == noErr else { throw AudioCaptureError.deviceBindingFailed(status) }
        guard id != kAudioObjectUnknown else { throw AudioCaptureError.unknownDeviceUID(uid) }
        return id
    }

    private static func failureName(_ error: AudioCaptureError) -> String {
        switch error {
        case .unknownDeviceUID: "unknown-device-uid"
        case .busy: "busy"
        case .invalidAudioUnit: "invalid-audio-unit"
        case .invalidFormat: "invalid-format"
        case .deviceBindingFailed: "device-binding-failed"
        case .engineStartFailed: "engine-start-failed"
        case .recoveryFileFailed: "recovery-file-failed"
        case .realtimeCopyFailed: "realtime-copy-failed"
        case .firstBufferDeadline: "first-buffer-deadline"
        case .deviceLost: "device-lost"
        case .configurationChanged: "configuration-changed"
        case .handoffOverflow: "handoff-overflow"
        case .outputOverflow: "output-overflow"
        }
    }
}
