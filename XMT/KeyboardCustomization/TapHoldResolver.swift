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
    static let maximumBufferedInputsPerDevice = 64
    private(set) var configuration: KeyboardConfiguration

    init(configuration: KeyboardConfiguration = .excludingEverything) {
        self.configuration = (try? configuration.validated()) ?? .excludingEverything
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
        /// Physical downs observed from the seized device, including unresolved keys.
        var pressed: Set<KeyCode> = []
        /// Presses invalidated by a policy change remain consumed until their real key-up.
        var suppressedUntilUp: Set<KeyCode> = []

        var isEmpty: Bool {
            pending == nil && inbox.isEmpty && down.isEmpty && holds.isEmpty && lastTapEnd.isEmpty
                && pressed.isEmpty && suppressedUntilUp.isEmpty
        }
    }

    private var devices: [KeyboardDeviceID: DeviceState] = [:]
    /// Reference counts, so two keys holding Control emit one Control down.
    private var modifierCounts: [KeyModifier: Int] = [:]
    private var physicalModifierCounts: [KeyModifier: Int] = [:]
    private var hyperHoldCount = 0
    private var syntheticModifierOutputs: Set<KeyModifier> = []
    private var physicalModifierOutputs: Set<KeyCode> = []
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
        var failure: KeyboardResolutionFailure?

        switch input {
        case .keyDown(let device, let key, let isRepeat):
            guard configuration.devices[device] != nil else {
                return KeyboardResolution(outputs: [], deadline: nextDeadline(), isInScope: false)
            }
            failure = enqueue(.keyDown(key, isRepeat: isRepeat), device: device, at: now, into: &outputs)

        case .keyUp(let device, let key):
            guard configuration.devices[device] != nil else {
                return KeyboardResolution(outputs: [], deadline: nextDeadline(), isInScope: false)
            }
            failure = enqueue(.keyUp(key), device: device, at: now, into: &outputs)

        case .deadline:
            for device in devices.keys.sorted() { drain(device, at: now, into: &outputs) }

        case .deviceRemoved(let device):
            cancel(device, into: &outputs)

        case .configurationReplaced(let replacement):
            // Reject atomically: invalid input cannot cancel active keys or replace last-known-good.
            guard let validated = try? replacement.validated() else { break }
            replaceConfiguration(validated, into: &outputs)

        case .teardown:
            cancelEverything(into: &outputs)
        }

        return KeyboardResolution(outputs: outputs, deadline: nextDeadline(), isInScope: true,
                                  failure: failure)
    }

    /// The instant the caller must deliver `.deadline`, or nil for no timer.
    private func nextDeadline() -> KeyboardInstant? {
        devices.values.compactMap { $0.pending?.deadline }.min()
    }

    private mutating func enqueue(_ input: BufferedInput,
                                  device: KeyboardDeviceID,
                                  at now: KeyboardInstant,
                                  into outputs: inout [KeyboardOutput]) -> KeyboardResolutionFailure? {
        var state = devices[device] ?? DeviceState()
        switch input {
        case .keyDown(let key, let isRepeat):
            if state.suppressedUntilUp.contains(key) { devices[device] = state; return nil }
            if !isRepeat { state.pressed.insert(key) }
        case .keyUp(let key):
            state.pressed.remove(key)
            if state.suppressedUntilUp.remove(key) != nil { devices[device] = state; return nil }
        }
        guard state.inbox.count < Self.maximumBufferedInputsPerDevice else {
            devices[device] = state
            cancelEverything(into: &outputs)
            configuration = .excludingEverything
            return .inboxCapacityExceeded(device: device, limit: Self.maximumBufferedInputsPerDevice)
        }
        state.inbox.append(Buffered(input: input, at: now))
        devices[device] = state
        drain(device, at: now, into: &outputs)
        return nil
    }

    // MARK: - Resolution loop

    private mutating func drain(_ device: KeyboardDeviceID,
                                at now: KeyboardInstant,
                                into outputs: inout [KeyboardOutput]) {
        guard var state = devices[device] else { return }
        guard let policy = configuration.devices[device] else {
            // Defensive fail-safe if scope disappears outside the normal validated replacement path.
            cancel(device, into: &outputs)
            return
        }

        loop: while true {
            if let pending = state.pending {
                if policy.productSemantics,
                   pending.behavior.hold != .hyper,
                   let head = state.inbox.first,
                   head.at < pending.deadline,
                   case .keyDown(let key, let repeatValue) = head.input,
                   !repeatValue, key.physicalModifier != nil {
                    resolveTap(pending, at: head.at, state: &state, into: &outputs)
                    continue
                }
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
        if pending.behavior.hold == .hyper { hyperHoldCount += 1 }
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

        if let modifier = key.physicalModifier {
            retainPhysicalModifier(key, modifier: modifier, state: &state, into: &outputs)
            return
        }

        guard let behavior = policy.keys[key] else {
            retain(key, into: &outputs)
            state.down[key] = key
            return
        }
        // A repeat with nothing tracked down is stale (its down was cancelled).
        if isRepeat { return }

        let timing = behavior.timing ?? policy.timing

        if policy.productSemantics, behavior.tap != nil, !behavior.hold.isEmpty,
           behavior.hold != .hyper,
           (hyperHoldCount > 0 || !physicalModifierCounts.isEmpty) {
            guard let tap = behavior.tap else { return }
            retain(tap, into: &outputs)
            state.down[key] = tap
            return
        }

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
            if modifiers == .hyper { hyperHoldCount = max(0, hyperHoldCount - 1) }
            for modifier in modifiers.ordered.reversed() { relinquish(modifier, into: &outputs) }
            return
        }
        if let emitted = state.down.removeValue(forKey: key) {
            if let modifier = key.physicalModifier {
                relinquishPhysicalModifier(key, modifier: modifier, into: &outputs)
            } else {
                relinquish(emitted, into: &outputs)
            }
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
        if count == 1,
           canonicalPhysicalCount(for: modifier) == 0,
           (physicalModifierCounts[modifier] ?? 0) == 0 {
            syntheticModifierOutputs.insert(modifier)
            outputs.append(.modifierDown(modifier))
        }
    }

    private mutating func relinquish(_ modifier: KeyModifier, into outputs: inout [KeyboardOutput]) {
        guard let count = modifierCounts[modifier], count > 0 else { return }
        if count == 1 {
            modifierCounts[modifier] = nil
            if canonicalPhysicalCount(for: modifier) > 0 {
                if syntheticModifierOutputs.remove(modifier) != nil {
                    physicalModifierOutputs.insert(canonicalUsage(for: modifier))
                }
            } else if syntheticModifierOutputs.remove(modifier) != nil {
                outputs.append(.modifierUp(modifier))
            }
        } else {
            modifierCounts[modifier] = count - 1
        }
    }

    private mutating func retainPhysicalModifier(_ key: KeyCode, modifier: KeyModifier,
                                                 state: inout DeviceState,
                                                 into outputs: inout [KeyboardOutput]) {
        physicalModifierCounts[modifier, default: 0] += 1
        keyCounts[key, default: 0] += 1
        state.down[key] = key
        // A synthetic modifier uses the canonical left usage. Replaying the same physical usage
        // would let its later up cancel the synthetic owner; the combined state already is down.
        if !(key.isCanonicalSyntheticModifierUsage && syntheticModifierOutputs.contains(modifier)) {
            physicalModifierOutputs.insert(key)
            outputs.append(.keyDown(key))
        }
    }

    private mutating func relinquishPhysicalModifier(_ key: KeyCode, modifier: KeyModifier,
                                                     into outputs: inout [KeyboardOutput]) {
        let isCanonical = key.isCanonicalSyntheticModifierUsage
        if let keyCount = keyCounts[key] {
            if keyCount == 1 {
                keyCounts[key] = nil
                if isCanonical, (modifierCounts[modifier] ?? 0) > 0 {
                    if physicalModifierOutputs.remove(key) != nil {
                        syntheticModifierOutputs.insert(modifier)
                    }
                } else if physicalModifierOutputs.contains(key) {
                    // When a right-side physical usage was the only modifier output while a
                    // synthetic owner waited, establish the canonical usage before releasing it.
                    if !isCanonical, (modifierCounts[modifier] ?? 0) > 0,
                       canonicalPhysicalCount(for: modifier) == 0,
                       !syntheticModifierOutputs.contains(modifier) {
                        syntheticModifierOutputs.insert(modifier)
                        outputs.append(.modifierDown(modifier))
                    }
                    physicalModifierOutputs.remove(key)
                    outputs.append(.keyUp(key))
                }
            } else {
                keyCounts[key] = keyCount - 1
            }
        }
        let physicalCount = physicalModifierCounts[modifier] ?? 0
        if physicalCount <= 1 {
            physicalModifierCounts[modifier] = nil
            if (modifierCounts[modifier] ?? 0) > 0,
               canonicalPhysicalCount(for: modifier) == 0,
               !syntheticModifierOutputs.contains(modifier) {
                syntheticModifierOutputs.insert(modifier)
                outputs.append(.modifierDown(modifier))
            }
        } else {
            physicalModifierCounts[modifier] = physicalCount - 1
        }
    }

    private func canonicalUsage(for modifier: KeyModifier) -> KeyCode {
        switch modifier {
        case .control: KeyCode(0xE0)
        case .shift: KeyCode(0xE1)
        case .option: KeyCode(0xE2)
        case .command: KeyCode(0xE3)
        }
    }

    private func canonicalPhysicalCount(for modifier: KeyModifier) -> Int {
        keyCounts[canonicalUsage(for: modifier)] ?? 0
    }

    // MARK: - Cancellation

    /// Drop unresolved state for one device and release everything it holds.
    /// An undecided mod-tap is discarded, never completed as a tap.
    private mutating func cancel(_ device: KeyboardDeviceID, into outputs: inout [KeyboardOutput]) {
        guard var state = devices[device] else { return }
        state.pending = nil
        state.inbox.removeAll()
        for key in state.down.keys.sorted() {
            guard let emitted = state.down[key] else { continue }
            if let modifier = key.physicalModifier {
                relinquishPhysicalModifier(key, modifier: modifier, into: &outputs)
            } else {
                relinquish(emitted, into: &outputs)
            }
        }
        state.down.removeAll()
        for key in state.holds.keys.sorted().reversed() {
            guard let modifiers = state.holds[key] else { continue }
            if modifiers == .hyper { hyperHoldCount = max(0, hyperHoldCount - 1) }
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
        physicalModifierCounts.removeAll()
        syntheticModifierOutputs.removeAll()
        physicalModifierOutputs.removeAll()
        hyperHoldCount = 0
        // Mirror modifier defence for ordinary keys: no malformed sequence may leave a key down.
        for key in keyCounts.keys.sorted().reversed() {
            keyCounts[key] = 1
            relinquish(key, into: &outputs)
        }
        keyCounts.removeAll()
    }

    // MARK: - Scoped configuration replacement

    private mutating func replaceConfiguration(_ replacement: KeyboardConfiguration,
                                               into outputs: inout [KeyboardOutput]) {
        let oldConfiguration = configuration
        for device in devices.keys.sorted() {
            guard let oldPolicy = oldConfiguration.devices[device],
                  let newPolicy = replacement.devices[device] else {
                cancel(device, into: &outputs)
                continue
            }
            guard oldPolicy != newPolicy, var state = devices[device] else { continue }

            let knownKeys = Set(oldPolicy.keys.keys).union(newPolicy.keys.keys)
            let affected = Set(knownKeys.filter { key in
                !sameStructuralBehavior(oldPolicy.keys[key], newPolicy.keys[key])
                    || oldPolicy.productSemantics != newPolicy.productSemantics
            })
            if let pending = state.pending, affected.contains(pending.key) { state.pending = nil }
            state.inbox.removeAll { buffered in
                switch buffered.input {
                case .keyDown(let key, _), .keyUp(let key): affected.contains(key)
                }
            }
            for key in affected.sorted() {
                if let modifiers = state.holds.removeValue(forKey: key) {
                    if modifiers == .hyper { hyperHoldCount = max(0, hyperHoldCount - 1) }
                    for modifier in modifiers.ordered.reversed() { relinquish(modifier, into: &outputs) }
                }
                if let emitted = state.down.removeValue(forKey: key) {
                    if let modifier = key.physicalModifier {
                        relinquishPhysicalModifier(key, modifier: modifier, into: &outputs)
                    } else {
                        relinquish(emitted, into: &outputs)
                    }
                }
                state.lastTapEnd.removeValue(forKey: key)
                if state.pressed.contains(key) { state.suppressedUntilUp.insert(key) }
            }
            devices[device] = state
        }
        configuration = replacement
        for device in devices.keys.sorted() { drain(device, at: lastInstant ?? .init(milliseconds: 0), into: &outputs) }
    }

    private func sameStructuralBehavior(_ lhs: KeyBehavior?, _ rhs: KeyBehavior?) -> Bool {
        lhs?.tap == rhs?.tap && lhs?.hold == rhs?.hold
    }
}
