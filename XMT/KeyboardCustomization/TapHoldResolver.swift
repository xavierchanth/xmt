import Foundation

/// Pure, timing-only tap/hold resolver for Keyboard Customization.
///
/// The resolver owns all key-state interpretation and emits resolved output;
/// the module that owns the seizure and the virtual keyboard is the only thing
/// that performs effects. It reads no clock, opens no device, and holds no
/// reference to anything effectful — every decision is a function of the inputs
/// it has been handed.
///
/// Guarantees the tests hold it to:
///
/// - Scope is checked before interpretation. An event from an unlisted device
///   is reported out of scope and leaves no state behind.
/// - Output is balanced: every emitted key down and modifier down is matched by
///   exactly one up, including across cancellation, device removal,
///   configuration replacement, and teardown.
/// - Cancellation never invents a tap.
/// - Time is monotonic. An out-of-order timestamp is clamped, never trapped on.
/// - No idle work is requested: `deadline` is nil whenever nothing is pending.
struct TapHoldResolver {
    private(set) var configuration: KeyboardConfiguration

    init(configuration: KeyboardConfiguration = .excludingEverything) {
        self.configuration = configuration
    }

    // MARK: - State

    private enum BufferedInput: Equatable {
        case keyDown(KeyCode, isRepeat: Bool)
        case keyUp(KeyCode)
    }

    private struct Buffered: Equatable {
        let input: BufferedInput
        let at: KeyboardInstant
    }

    private struct Pending: Equatable {
        let key: KeyCode
        let behavior: KeyBehavior
        let timing: KeyTiming
        let downAt: KeyboardInstant
        var deadline: KeyboardInstant { downAt.advanced(by: timing.holdMilliseconds) }
    }

    /// Per-device interpretation state. Devices never share key state; only the
    /// virtual keyboard's modifier accounting is shared.
    private struct DeviceState: Equatable {
        var pending: Pending?
        /// Events held back while a mod-tap is undecided, in arrival order.
        var inbox: [Buffered] = []
        /// Physical key -> key currently emitted down for it.
        var down: [KeyCode: KeyCode] = [:]
        /// Physical key -> modifiers it is currently holding.
        var holds: [KeyCode: ModifierSet] = [:]
        /// Physical key -> instant its last tap released, for quick tap.
        var lastTapEnd: [KeyCode: KeyboardInstant] = [:]

        var isEmpty: Bool {
            pending == nil && inbox.isEmpty && down.isEmpty && holds.isEmpty && lastTapEnd.isEmpty
        }
    }

    private var devices: [KeyboardDeviceID: DeviceState] = [:]
    /// Reference counts, so two keys holding Control emit one Control down.
    private var modifierCounts: [KeyModifier: Int] = [:]
    /// The same counting for ordinary keys: two devices — or two physical keys
    /// mapped to one output — can hold one virtual key, and it must be
    /// released once, by the last owner.
    private var keyCounts: [KeyCode: Int] = [:]
    private var lastInstant: KeyboardInstant?

    // MARK: - Entry point

    mutating func receive(_ input: KeyboardInput, at instant: KeyboardInstant) -> KeyboardResolution {
        let now = max(instant, lastInstant ?? instant)
        lastInstant = now
        var outputs: [KeyboardOutput] = []

        switch input {
        case .keyDown(let device, let key, let isRepeat):
            guard configuration.devices[device] != nil else {
                return KeyboardResolution(outputs: [], deadline: nextDeadline(), isInScope: false)
            }
            enqueue(.keyDown(key, isRepeat: isRepeat), device: device, at: now, into: &outputs)

        case .keyUp(let device, let key):
            guard configuration.devices[device] != nil else {
                return KeyboardResolution(outputs: [], deadline: nextDeadline(), isInScope: false)
            }
            enqueue(.keyUp(key), device: device, at: now, into: &outputs)

        case .deadline:
            for device in devices.keys.sorted() { drain(device, at: now, into: &outputs) }

        case .deviceRemoved(let device):
            cancel(device, into: &outputs)

        case .configurationReplaced(let replacement):
            cancelEverything(into: &outputs)
            configuration = replacement

        case .teardown:
            cancelEverything(into: &outputs)
        }

        return KeyboardResolution(outputs: outputs, deadline: nextDeadline(), isInScope: true)
    }

    /// The instant the caller must deliver `.deadline`, or nil for no timer.
    private func nextDeadline() -> KeyboardInstant? {
        devices.values.compactMap { $0.pending?.deadline }.min()
    }

    private mutating func enqueue(_ input: BufferedInput,
                                  device: KeyboardDeviceID,
                                  at now: KeyboardInstant,
                                  into outputs: inout [KeyboardOutput]) {
        var state = devices[device] ?? DeviceState()
        state.inbox.append(Buffered(input: input, at: now))
        devices[device] = state
        drain(device, at: now, into: &outputs)
    }

    // MARK: - Resolution loop

    private mutating func drain(_ device: KeyboardDeviceID,
                                at now: KeyboardInstant,
                                into outputs: inout [KeyboardOutput]) {
        guard var state = devices[device] else { return }
        guard let policy = configuration.devices[device] else {
            // Scope was withdrawn while events were buffered: nothing is
            // interpreted, and no output is invented for the dropped events.
            state.inbox.removeAll()
            devices[device] = state.isEmpty ? nil : state
            return
        }

        loop: while true {
            if let pending = state.pending {
                switch decision(for: pending, in: state.inbox, now: now) {
                case .tap(let index):
                    let instant = state.inbox[index].at
                    state.inbox.remove(at: index)
                    resolveTap(pending, at: instant, state: &state, into: &outputs)
                    continue
                case .hold:
                    resolveHold(pending, state: &state, into: &outputs)
                    continue
                case .undecided:
                    guard let head = state.inbox.first else { break loop }
                    switch head.input {
                    case .keyDown(let key, _) where key == pending.key:
                        // A repeat or duplicate down of the undecided key itself.
                        state.inbox.removeFirst()
                    case .keyUp(let key) where state.down[key] != nil || state.holds[key] != nil:
                        // A key pressed before the mod-tap. Releasing it cannot
                        // reorder the pending tap and must never be stranded.
                        state.inbox.removeFirst()
                        release(key, at: head.at, state: &state, into: &outputs)
                    default:
                        // Everything else waits, so that whatever the mod-tap
                        // turns out to be is emitted before the keys rolled
                        // onto it.
                        break loop
                    }
                    continue
                }
            }

            guard let head = state.inbox.first else { break }
            state.inbox.removeFirst()
            switch head.input {
            case .keyDown(let key, let isRepeat):
                press(key, isRepeat: isRepeat, at: head.at, policy: policy, state: &state, into: &outputs)
            case .keyUp(let key):
                release(key, at: head.at, state: &state, into: &outputs)
            }
        }

        devices[device] = state.isEmpty ? nil : state
    }

    private enum PendingDecision {
        /// Resolve as a tap; the payload is the index of the release that
        /// decided it, which is consumed rather than replayed.
        case tap(index: Int)
        case hold
        case undecided
    }

    /// Decides an undecided mod-tap from the evidence already buffered, in
    /// arrival order, so that a decision is never delayed behind a key that was
    /// rolled onto it. Buffered timestamps are non-decreasing, so the first
    /// event at or past the threshold settles it as a hold.
    private func decision(for pending: Pending, in inbox: [Buffered], now: KeyboardInstant) -> PendingDecision {
        var openedAfterPending: Set<KeyCode> = []
        for (index, buffered) in inbox.enumerated() {
            if buffered.at >= pending.deadline { return .hold }
            switch buffered.input {
            case .keyUp(let key) where key == pending.key:
                return .tap(index: index)
            case .keyDown(let key, let isRepeat) where key != pending.key:
                guard !isRepeat else { break }
                if pending.timing.rollover == .otherKeyPress { return .hold }
                openedAfterPending.insert(key)
            case .keyUp(let key):
                if pending.timing.rollover == .otherKeyRelease, openedAfterPending.contains(key) { return .hold }
            case .keyDown:
                break
            }
        }
        return now >= pending.deadline ? .hold : .undecided
    }

    // MARK: - Decisions

    private mutating func resolveTap(_ pending: Pending,
                                     at instant: KeyboardInstant,
                                     state: inout DeviceState,
                                     into outputs: inout [KeyboardOutput]) {
        state.pending = nil
        guard let tap = pending.behavior.tap else { return }
        emitTap(tap, into: &outputs)
        state.lastTapEnd[pending.key] = instant
    }

    private mutating func resolveHold(_ pending: Pending,
                                      state: inout DeviceState,
                                      into outputs: inout [KeyboardOutput]) {
        state.pending = nil
        guard !pending.behavior.hold.isEmpty else { return }
        state.holds[pending.key] = pending.behavior.hold
        for modifier in pending.behavior.hold.ordered { retain(modifier, into: &outputs) }
    }

    private mutating func press(_ key: KeyCode,
                                isRepeat: Bool,
                                at instant: KeyboardInstant,
                                policy: DeviceKeyboardPolicy,
                                state: inout DeviceState,
                                into outputs: inout [KeyboardOutput]) {
        if let emitted = state.down[key] {
            // Auto-repeat of something already down, including a quick-tapped
            // mod-tap; a duplicate non-repeat down is ignored rather than
            // emitting an unbalanced second down.
            if isRepeat { outputs.append(.keyDown(emitted)) }
            return
        }
        if state.holds[key] != nil { return }

        guard let behavior = policy.keys[key] else {
            retain(key, into: &outputs)
            state.down[key] = key
            return
        }
        // A repeat with nothing tracked down is stale (its down was cancelled).
        if isRepeat { return }

        let timing = behavior.timing ?? policy.timing

        if let tap = behavior.tap,
           timing.quickTapMilliseconds > 0,
           let lastTap = state.lastTapEnd[key],
           instant.elapsed(since: lastTap) <= timing.quickTapMilliseconds {
            retain(tap, into: &outputs)
            state.down[key] = tap
            return
        }

        if behavior.hold.isEmpty {
            guard let tap = behavior.tap else { return }
            retain(tap, into: &outputs)
            state.down[key] = tap
            return
        }

        guard behavior.tap != nil else {
            // Hold-only: there is no tap to protect, so form it immediately.
            state.holds[key] = behavior.hold
            for modifier in behavior.hold.ordered { retain(modifier, into: &outputs) }
            return
        }

        state.pending = Pending(key: key, behavior: behavior, timing: timing, downAt: instant)
    }

    private mutating func release(_ key: KeyCode,
                                  at instant: KeyboardInstant,
                                  state: inout DeviceState,
                                  into outputs: inout [KeyboardOutput]) {
        if let modifiers = state.holds.removeValue(forKey: key) {
            for modifier in modifiers.ordered.reversed() { relinquish(modifier, into: &outputs) }
            return
        }
        if let emitted = state.down.removeValue(forKey: key) {
            relinquish(emitted, into: &outputs)
            state.lastTapEnd[key] = instant
            return
        }
        // An up with no matching down: emitting a release here would be
        // unbalanced, so it is ignored.
    }

    // MARK: - Output accounting

    /// A press that will be released later. The down is always emitted — a
    /// second owner re-pressing the key is what a host sees as a repeat — but
    /// only the last owner's release reaches the virtual keyboard.
    private mutating func retain(_ key: KeyCode, into outputs: inout [KeyboardOutput]) {
        keyCounts[key] = (keyCounts[key] ?? 0) + 1
        outputs.append(.keyDown(key))
    }

    private mutating func relinquish(_ key: KeyCode, into outputs: inout [KeyboardOutput]) {
        guard let count = keyCounts[key], count > 0 else { return }
        if count == 1 {
            keyCounts[key] = nil
            outputs.append(.keyUp(key))
        } else {
            keyCounts[key] = count - 1
        }
    }

    /// A complete tap. If something else is already holding that key, the tap
    /// is a re-press rather than a release the holder still owes.
    private mutating func emitTap(_ key: KeyCode, into outputs: inout [KeyboardOutput]) {
        outputs.append(.keyDown(key))
        if (keyCounts[key] ?? 0) == 0 { outputs.append(.keyUp(key)) }
    }

    private mutating func retain(_ modifier: KeyModifier, into outputs: inout [KeyboardOutput]) {
        let count = (modifierCounts[modifier] ?? 0) + 1
        modifierCounts[modifier] = count
        if count == 1 { outputs.append(.modifierDown(modifier)) }
    }

    private mutating func relinquish(_ modifier: KeyModifier, into outputs: inout [KeyboardOutput]) {
        guard let count = modifierCounts[modifier], count > 0 else { return }
        if count == 1 {
            modifierCounts[modifier] = nil
            outputs.append(.modifierUp(modifier))
        } else {
            modifierCounts[modifier] = count - 1
        }
    }

    // MARK: - Cancellation

    /// Drop unresolved state for one device and release everything it holds.
    /// An undecided mod-tap is discarded, never completed as a tap.
    private mutating func cancel(_ device: KeyboardDeviceID, into outputs: inout [KeyboardOutput]) {
        guard var state = devices[device] else { return }
        state.pending = nil
        state.inbox.removeAll()
        for key in state.down.keys.sorted() {
            if let emitted = state.down[key] { relinquish(emitted, into: &outputs) }
        }
        state.down.removeAll()
        for key in state.holds.keys.sorted().reversed() {
            guard let modifiers = state.holds[key] else { continue }
            for modifier in modifiers.ordered.reversed() { relinquish(modifier, into: &outputs) }
        }
        state.holds.removeAll()
        devices[device] = nil
    }

    private mutating func cancelEverything(into outputs: inout [KeyboardOutput]) {
        for device in devices.keys.sorted() { cancel(device, into: &outputs) }
        devices.removeAll()
        // Defensive balance: nothing should remain, but a stranded modifier
        // must be released rather than left down on the virtual keyboard.
        for modifier in modifierCounts.keys.sorted().reversed() {
            modifierCounts[modifier] = 1
            relinquish(modifier, into: &outputs)
        }
        modifierCounts.removeAll()
    }
}
