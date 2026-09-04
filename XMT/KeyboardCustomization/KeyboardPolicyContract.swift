import Foundation

struct KeyboardPolicyDTO: Codable, Equatable, Sendable {
    static let maximumDevices = 16
    static let maximumKeysPerDevice = 64

    let revision: UInt64
    let devices: [Device]

    struct Device: Codable, Equatable, Sendable {
        let id: String
        let identity: Identity
        let timing: Timing
        let keys: [Key]
    }

    struct Identity: Codable, Equatable, Hashable, Sendable {
        let builtIn: Bool
        let vendorID: UInt16
        let productID: UInt16
        let serialNumber: String?
        let locationID: UInt32?
        let transport: String?
    }

    struct Timing: Codable, Equatable, Sendable {
        let holdMilliseconds: Int
        let quickTapMilliseconds: Int
        let rollover: RolloverPolicy
    }

    struct Key: Codable, Equatable, Sendable {
        let physicalCode: UInt16
        let tapCode: UInt16?
        let holdModifiers: [Modifier]
        let timing: Timing?
    }

    enum Modifier: String, Codable, CaseIterable, Equatable, Sendable {
        case control, shift, option, command
    }
}

enum KeyboardPolicyValidationError: Error, Equatable, Sendable {
    case invalidRevision
    case tooManyDevices
    case invalidDeviceID(index: Int)
    case duplicateDeviceID(String)
    case malformedIdentity(device: String)
    case insufficientIdentity(device: String)
    case duplicateIdentity(first: String, second: String)
    case tooManyKeys(device: String)
    case duplicateKey(device: String, code: UInt16)
    case duplicateModifier(device: String, code: UInt16)
    case invalidConfiguration(KeyboardConfigurationError)
}

/// Strict owner policy. Its initializer is private so all effectful code receives configuration
/// that has already passed identity, collection-bound, timing, and key-behavior validation.
struct ValidatedKeyboardOwnerPolicy: Equatable, Sendable {
    struct Device: Equatable, Sendable {
        let id: KeyboardDeviceID
        let identityRule: KeyboardDeviceRule
    }

    let revision: KeyboardPolicyRevision
    let configuration: KeyboardConfiguration
    let devices: [Device]

    private init(revision: KeyboardPolicyRevision,
                 configuration: KeyboardConfiguration,
                 devices: [Device]) {
        self.revision = revision
        self.configuration = configuration
        self.devices = devices
    }

    func deviceID(for descriptor: KeyboardDeviceDescriptor,
                  in inventory: [KeyboardDeviceDescriptor]) -> KeyboardDeviceID? {
        let matcher = KeyboardDevicePolicy(allow: devices.map(\.identityRule), exclude: [])
        let matches = matcher.evaluateInventory(inventory)
        guard let index = inventory.firstIndex(of: descriptor), matches[index] == .allowed else { return nil }
        let identity = KeyboardDeviceIdentity(descriptor)
        let candidates = devices.filter { $0.identityRule.matches(identity) }
        guard candidates.count == 1 else { return nil }
        let matchingInventoryCount = inventory.lazy
            .map(KeyboardDeviceIdentity.init)
            .filter(candidates[0].identityRule.matches)
            .count
        return matchingInventoryCount == 1 ? candidates[0].id : nil
    }

    static func validate(_ dto: KeyboardPolicyDTO) throws -> Self {
        guard let revision = KeyboardPolicyRevision(dto.revision) else {
            throw KeyboardPolicyValidationError.invalidRevision
        }
        guard dto.devices.count <= KeyboardPolicyDTO.maximumDevices else {
            throw KeyboardPolicyValidationError.tooManyDevices
        }

        var seenIDs = Set<String>()
        var seenIdentities: [KeyboardPolicyDTO.Identity: String] = [:]
        var configuration: [KeyboardDeviceID: DeviceKeyboardPolicy] = [:]
        var devices: [Device] = []

        for (index, device) in dto.devices.enumerated() {
            let trimmedID = device.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty, trimmedID == device.id else {
                throw KeyboardPolicyValidationError.invalidDeviceID(index: index)
            }
            guard seenIDs.insert(trimmedID).inserted else {
                throw KeyboardPolicyValidationError.duplicateDeviceID(trimmedID)
            }
            guard device.keys.count <= KeyboardPolicyDTO.maximumKeysPerDevice else {
                throw KeyboardPolicyValidationError.tooManyKeys(device: trimmedID)
            }

            let identity = try normalizedIdentity(device.identity, deviceID: trimmedID)
            if let first = seenIdentities.updateValue(trimmedID, forKey: identity) {
                throw KeyboardPolicyValidationError.duplicateIdentity(first: first, second: trimmedID)
            }

            let id = KeyboardDeviceID(trimmedID)
            let defaultTiming = Self.timing(device.timing)
            var keys: [KeyCode: KeyBehavior] = [:]
            for key in device.keys {
                let code = KeyCode(key.physicalCode)
                guard keys[code] == nil else {
                    throw KeyboardPolicyValidationError.duplicateKey(device: trimmedID, code: key.physicalCode)
                }
                guard Set(key.holdModifiers).count == key.holdModifiers.count else {
                    throw KeyboardPolicyValidationError.duplicateModifier(device: trimmedID, code: key.physicalCode)
                }
                let modifiers = key.holdModifiers.reduce(into: ModifierSet()) { result, modifier in
                    result.formUnion(modifier.domainValue)
                }
                keys[code] = KeyBehavior(
                    tap: key.tapCode.map(KeyCode.init),
                    hold: modifiers,
                    timing: key.timing.map(Self.timing)
                )
            }
            configuration[id] = DeviceKeyboardPolicy(timing: defaultTiming, keys: keys)
            devices.append(.init(
                id: id,
                identityRule: KeyboardDeviceRule(
                    builtIn: identity.builtIn,
                    vendorID: identity.vendorID,
                    productID: identity.productID,
                    serialNumber: identity.serialNumber,
                    locationID: identity.locationID,
                    transport: identity.transport
                )
            ))
        }

        let candidate = KeyboardConfiguration(devices: configuration)
        do {
            return Self(revision: revision, configuration: try candidate.validated(), devices: devices)
        } catch let error as KeyboardConfigurationError {
            throw KeyboardPolicyValidationError.invalidConfiguration(error)
        }
    }

    private static func normalizedIdentity(_ identity: KeyboardPolicyDTO.Identity,
                                           deviceID: String) throws -> KeyboardPolicyDTO.Identity {
        func normalize(_ value: String?, lowercase: Bool = false) throws -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw KeyboardPolicyValidationError.malformedIdentity(device: deviceID)
            }
            return lowercase ? trimmed.lowercased() : trimmed
        }
        let serial = try normalize(identity.serialNumber)
        let transport = try normalize(identity.transport, lowercase: true)
        guard serial != nil || identity.locationID != nil else {
            throw KeyboardPolicyValidationError.insufficientIdentity(device: deviceID)
        }
        return .init(
            builtIn: identity.builtIn,
            vendorID: identity.vendorID,
            productID: identity.productID,
            serialNumber: serial,
            locationID: identity.locationID,
            transport: transport
        )
    }

    private static func timing(_ value: KeyboardPolicyDTO.Timing) -> KeyTiming {
        .init(
            holdMilliseconds: value.holdMilliseconds,
            quickTapMilliseconds: value.quickTapMilliseconds,
            rollover: value.rollover
        )
    }
}

private extension KeyboardPolicyDTO.Modifier {
    var domainValue: ModifierSet {
        switch self {
        case .control: .control
        case .shift: .shift
        case .option: .option
        case .command: .command
        }
    }
}
