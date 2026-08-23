import ApplicationServices
import Carbon
import Foundation

struct FnEventMapping: Equatable {
    var input: TriggerInput?
    var consumesEvent: Bool
}

/// Pure physical-key bookkeeping shared by the tap and focused tests.
struct FnPhysicalEventMapper {
    private(set) var fnIsDown = false
    private(set) var hasConsumedSpaceDown = false

    mutating func fnChanged(isDown: Bool) -> FnEventMapping {
        guard isDown != fnIsDown else { return .init(input: nil, consumesEvent: false) }
        fnIsDown = isDown
        return .init(input: isDown ? .fnDown : .fnUp, consumesEvent: false)
    }

    mutating func keyDown(code: Int64, isRepeat: Bool) -> FnEventMapping {
        guard fnIsDown else { return .init(input: nil, consumesEvent: false) }
        guard code == 49 else {
            return .init(input: isRepeat ? nil : .otherKeyDown, consumesEvent: false)
        }
        let input: TriggerInput? = hasConsumedSpaceDown ? nil : .spaceDown
        hasConsumedSpaceDown = true
        return .init(input: input, consumesEvent: true)
    }

    mutating func keyUp(code: Int64) -> FnEventMapping {
        guard code == 49, hasConsumedSpaceDown else {
            return .init(input: nil, consumesEvent: false)
        }
        hasConsumedSpaceDown = false
        return .init(input: nil, consumesEvent: true)
    }

    mutating func interrupt() {
        fnIsDown = false
        hasConsumedSpaceDown = false
    }
}

/// The Input Monitoring boundary for the two Fn gestures. It owns no voice or
/// recording state and allocates its event tap only while it has subscribers.
@MainActor
final class FnEventObserver {
    enum Failure: Error, Equatable {
        case eventTapCreationFailed
    }

    @MainActor
    final class Observation {
        private weak var owner: FnEventObserver?
        private let id: UUID

        fileprivate init(owner: FnEventObserver, id: UUID) {
            self.owner = owner
            self.id = id
        }

        func cancel() {
            owner?.remove(id)
            owner = nil
        }

        deinit {
            let owner = owner
            let id = id
            Task { @MainActor in owner?.remove(id) }
        }
    }

    typealias Handler = (TriggerEvent) -> Void

    private struct Subscriber {
        let handler: Handler
        var hasActivePTT = false
    }

    private let threshold: TimeInterval
    private var handlers: [UUID: Subscriber] = [:]
    private var arbitrator = TriggerArbitrator()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var secureInputWatchdog: Timer?
    private var physicalEvents = FnPhysicalEventMapper()

    init(holdThreshold: TimeInterval = 0.35) {
        threshold = holdThreshold
    }

    func observe(_ handler: @escaping Handler) throws -> Observation {
        if handlers.isEmpty {
            try installTap()
        }
        let id = UUID()
        handlers[id] = Subscriber(handler: handler)
        return Observation(owner: self, id: id)
    }

    /// Allows the permission/UI boundary to make an existing observation inert
    /// as soon as secure input is detected.
    func secureInputInterrupted() {
        physicalEvents.interrupt()
        process(.secureInputInterrupted)
    }

    private func remove(_ id: UUID) {
        guard let subscriber = handlers.removeValue(forKey: id) else { return }
        if subscriber.hasActivePTT {
            deliver(.pushToTalkEnded, to: subscriber.handler)
        }
        if handlers.isEmpty { tearDown() }
    }

    private func installTap() throws {
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let observer = Unmanaged<FnEventObserver>.fromOpaque(info).takeUnretainedValue()
                return observer.handle(type: type, event: event)
                    ? nil : Unmanaged.passUnretained(event)
            }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw Failure.eventTapCreationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true only for Space events belonging to an Fn-Space gesture.
    /// Semantic callbacks are always deferred until after this synchronous
    /// consumption decision returns to Core Graphics.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            physicalEvents.interrupt()
            process(.tapDisabled)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        if IsSecureEventInputEnabled() {
            if arbitrator.state != .idle { secureInputInterrupted() }
            return false
        }

        let mapping: FnEventMapping
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged {
            mapping = physicalEvents.fnChanged(isDown: event.flags.contains(.maskSecondaryFn))
        } else if type == .keyDown {
            mapping = physicalEvents.keyDown(
                code: keyCode,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        } else if type == .keyUp {
            mapping = physicalEvents.keyUp(code: keyCode)
        } else {
            return false
        }
        if let input = mapping.input { process(input) }
        return mapping.consumesEvent
    }

    private func process(_ input: TriggerInput) {
        let events = arbitrator.receive(input)
        updateTimer()
        updateSecureInputWatchdog()
        for event in events {
            let ids = Array(handlers.keys)
            for id in ids {
                guard var subscriber = handlers[id] else { continue }
                if event == .pushToTalkBegan { subscriber.hasActivePTT = true }
                if event == .pushToTalkEnded { subscriber.hasActivePTT = false }
                handlers[id] = subscriber
                deliver(event, to: subscriber.handler)
            }
        }
    }

    private func deliver(_ event: TriggerEvent, to handler: @escaping Handler) {
        DispatchQueue.main.async { handler(event) }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard arbitrator.state == .fnPending else { return }
        let timer = Timer(timeInterval: threshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.process(.holdThresholdElapsed) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateSecureInputWatchdog() {
        let interacting = arbitrator.state != .idle
        if !interacting {
            secureInputWatchdog?.invalidate()
            secureInputWatchdog = nil
        } else if secureInputWatchdog == nil {
            let watchdog = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, IsSecureEventInputEnabled() else { return }
                    self.secureInputInterrupted()
                }
            }
            secureInputWatchdog = watchdog
            RunLoop.main.add(watchdog, forMode: .common)
        }
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        secureInputWatchdog?.invalidate()
        secureInputWatchdog = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        physicalEvents.interrupt()
        arbitrator = TriggerArbitrator()
    }

    deinit {
        timer?.invalidate()
        secureInputWatchdog?.invalidate()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }
}
