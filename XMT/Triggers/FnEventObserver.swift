import ApplicationServices
import Foundation

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
            MainActor.assumeIsolated { cancel() }
        }
    }

    typealias Handler = (TriggerEvent) -> Void

    private let threshold: TimeInterval
    private var handlers: [UUID: Handler] = [:]
    private var arbitrator = TriggerArbitrator()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var fnIsDown = false
    private var spaceIsDown = false

    init(holdThreshold: TimeInterval = 0.35) {
        threshold = holdThreshold
    }

    func observe(_ handler: @escaping Handler) throws -> Observation {
        if handlers.isEmpty {
            try installTap()
        }
        let id = UUID()
        handlers[id] = handler
        return Observation(owner: self, id: id)
    }

    /// Allows the permission/UI boundary to make an existing observation inert
    /// as soon as secure input is detected.
    func secureInputInterrupted() {
        fnIsDown = false
        spaceIsDown = false
        process(.secureInputInterrupted)
    }

    private func remove(_ id: UUID) {
        handlers[id] = nil
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

    /// Returns true only for Space presses belonging to an Fn-Space gesture.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            process(.tapDisabled)
            fnIsDown = false
            spaceIsDown = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        if type == .flagsChanged {
            let nowDown = event.flags.contains(.maskSecondaryFn)
            guard nowDown != fnIsDown else { return false }
            fnIsDown = nowDown
            process(nowDown ? .fnDown : .fnUp)
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, keyCode == 49 {
            spaceIsDown = false
            return false
        }
        guard type == .keyDown, fnIsDown else { return false }

        if keyCode == 49 {
            // Consume repeats too, but arbitrate only the physical transition.
            if !spaceIsDown {
                spaceIsDown = true
                process(.spaceDown)
            }
            return true
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            process(.otherKeyDown)
        }
        return false
    }

    private func process(_ input: TriggerInput) {
        let events = arbitrator.receive(input)
        updateTimer()
        for event in events {
            for handler in handlers.values { handler(event) }
        }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard arbitrator.state == .fnPending else { return }
        timer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.process(.holdThresholdElapsed) }
        }
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        fnIsDown = false
        spaceIsDown = false
        arbitrator = TriggerArbitrator()
    }

    deinit {
        timer?.invalidate()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }
}
