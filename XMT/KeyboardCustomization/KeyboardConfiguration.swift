import Foundation

/// How a still-undecided mod-tap reacts to other keys pressed during rollover.
enum RolloverPolicy: String, Codable, Equatable, Sendable {
    /// Only the hold threshold or the key's own release decides it.
    case timeoutOnly
    /// Any other key going down decides the pending key as a hold.
    case otherKeyPress
    /// Another key going down *and* up while the key is still held decides it
    /// as a hold; a fast roll that releases the mod-tap first stays a tap.
    case otherKeyRelease
}

/// Timing policy for a device, optionally overridden per key. Values are
/// configuration, not defaults copied from any other firmware project.
struct KeyTiming: Equatable, Sendable {
    /// Milliseconds a key must stay down before it resolves as a hold.
    var holdMilliseconds: Int
    /// Window after a tap release in which pressing the same key again types
    /// the tap key (held, and repeating) instead of arming the hold. Zero
    /// disables quick tap.
    var quickTapMilliseconds: Int
    var rollover: RolloverPolicy

    init(holdMilliseconds: Int, quickTapMilliseconds: Int = 0, rollover: RolloverPolicy = .timeoutOnly) {
        self.holdMilliseconds = holdMilliseconds
        self.quickTapMilliseconds = quickTapMilliseconds
        self.rollover = rollover
    }
}

/// What one physical key does. A key with both a tap and a hold is a mod-tap.
struct KeyBehavior: Equatable, Sendable {
    /// Key emitted on tap, or nil for a hold-only key.
    var tap: KeyCode?
    /// Modifiers formed by holding, or empty for a plain remap.
    var hold: ModifierSet
    /// Per-key timing override; nil uses the device policy.
    var timing: KeyTiming?

    init(tap: KeyCode? = nil, hold: ModifierSet = [], timing: KeyTiming? = nil) {
        self.tap = tap
        self.hold = hold
        self.timing = timing
    }
}

struct DeviceKeyboardPolicy: Equatable, Sendable {
    var timing: KeyTiming
    var keys: [KeyCode: KeyBehavior]

    init(timing: KeyTiming, keys: [KeyCode: KeyBehavior] = [:]) {
        self.timing = timing
        self.keys = keys
    }
}

/// Explicit device scope plus per-device behavior. A device that is absent is
/// excluded; there is no implicit inclusion and no wildcard.
struct KeyboardConfiguration: Equatable, Sendable {
    static let maximumTimingMilliseconds = 60_000
    var devices: [KeyboardDeviceID: DeviceKeyboardPolicy]

    init(devices: [KeyboardDeviceID: DeviceKeyboardPolicy] = [:]) { self.devices = devices }

    static let excludingEverything = KeyboardConfiguration()

    func policy(for device: KeyboardDeviceID) -> DeviceKeyboardPolicy? { devices[device] }

    /// Total, trap-free validation. Callers keep the last known-good
    /// configuration when this throws; the engine only ever receives a
    /// validated value.
    func validated() throws -> KeyboardConfiguration {
        for device in devices.keys.sorted() {
            guard let policy = devices[device] else { continue }
            guard !device.rawValue.isEmpty,
                  device.rawValue == device.rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw KeyboardConfigurationError.emptyDeviceIdentity
            }
            try Self.check(policy.timing, device: device, key: nil)
            for key in policy.keys.keys.sorted() {
                guard let behavior = policy.keys[key] else { continue }
                if behavior.tap == nil, behavior.hold.isEmpty {
                    throw KeyboardConfigurationError.behaviorDoesNothing(device: device, key: key)
                }
                guard behavior.hold.containsOnlyKnownModifiers else {
                    throw KeyboardConfigurationError.unknownModifierBits(device: device, key: key)
                }
                if let timing = behavior.timing { try Self.check(timing, device: device, key: key) }
            }
        }
        return self
    }

    private static func check(_ timing: KeyTiming, device: KeyboardDeviceID, key: KeyCode?) throws {
        guard timing.holdMilliseconds > 0 else {
            throw KeyboardConfigurationError.nonPositiveHoldThreshold(device: device, key: key)
        }
        guard timing.quickTapMilliseconds >= 0 else {
            throw KeyboardConfigurationError.negativeQuickTapWindow(device: device, key: key)
        }
        guard timing.holdMilliseconds <= maximumTimingMilliseconds,
              timing.quickTapMilliseconds <= maximumTimingMilliseconds else {
            throw KeyboardConfigurationError.timingOutOfRange(device: device, key: key)
        }
    }
}

enum KeyboardConfigurationError: Error, Equatable, Sendable {
    case emptyDeviceIdentity
    case nonPositiveHoldThreshold(device: KeyboardDeviceID, key: KeyCode?)
    case negativeQuickTapWindow(device: KeyboardDeviceID, key: KeyCode?)
    case behaviorDoesNothing(device: KeyboardDeviceID, key: KeyCode)
    case unknownModifierBits(device: KeyboardDeviceID, key: KeyCode)
    case timingOutOfRange(device: KeyboardDeviceID, key: KeyCode?)
}
