import Foundation

/// A synthetic/public-property-only description of a HID keyboard.
/// Stage 1 never populates this from live hardware.
struct KeyboardDeviceDescriptor: Hashable, Sendable {
    let builtIn: Bool
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?
    let locationID: UInt32?
    let transport: String?
}

struct KeyboardDeviceIdentity: Hashable, Sendable {
    let builtIn: Bool
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?
    let locationID: UInt32?
    let transport: String?

    init(_ descriptor: KeyboardDeviceDescriptor) {
        builtIn = descriptor.builtIn
        vendorID = descriptor.vendorID
        productID = descriptor.productID
        serialNumber = descriptor.serialNumber.normalizedIdentityField
        locationID = descriptor.locationID
        transport = descriptor.transport.normalizedTransport
    }
}

/// Rule input is normalized at construction, before it can reach either policy list.
/// A blank optional field becomes an omitted constraint; for an exclusion this
/// deliberately broadens the match rather than allowing a malformed exclude to fail open.
struct KeyboardDeviceRule: Hashable, Sendable {
    let builtIn: Bool
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?
    let locationID: UInt32?
    let transport: String?
    let hasMalformedOptionalConstraint: Bool

    init(builtIn: Bool, vendorID: UInt16, productID: UInt16, serialNumber: String?,
         locationID: UInt32?, transport: String?) {
        self.builtIn = builtIn
        self.vendorID = vendorID
        self.productID = productID
        hasMalformedOptionalConstraint = [serialNumber, transport].contains { value in
            value != nil && value!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.serialNumber = serialNumber.normalizedIdentityField
        self.locationID = locationID
        self.transport = transport.normalizedTransport
    }

    func matches(_ identity: KeyboardDeviceIdentity) -> Bool {
        guard builtIn == identity.builtIn, vendorID == identity.vendorID,
              productID == identity.productID else { return false }
        if let serialNumber, serialNumber != identity.serialNumber { return false }
        if let locationID, locationID != identity.locationID { return false }
        if let transport, transport != identity.transport { return false }
        return true
    }
}

enum KeyboardDeviceMatch: Equatable { case allowed, excluded, unmatched, ambiguous }

struct KeyboardDevicePolicy: Sendable {
    let allow: [KeyboardDeviceRule]
    let exclude: [KeyboardDeviceRule]

    func evaluate(_ descriptor: KeyboardDeviceDescriptor) -> KeyboardDeviceMatch {
        let identity = KeyboardDeviceIdentity(descriptor)
        // Exclusions are fail-closed: one or multiple matching rules always exclude.
        if exclude.contains(where: { $0.matches(identity) }) { return .excluded }
        guard !allow.contains(where: \.hasMalformedOptionalConstraint) else { return .ambiguous }
        let matches = allow.filter { $0.matches(identity) }
        guard !matches.isEmpty else { return .unmatched }
        return matches.count == 1 ? .allowed : .ambiguous
    }

    /// Evaluates a complete attachment snapshot so indistinguishable devices cannot both pass a
    /// broad allow rule. The result order matches the descriptor order.
    func evaluateInventory(_ descriptors: [KeyboardDeviceDescriptor]) -> [KeyboardDeviceMatch] {
        var results = descriptors.map(evaluate)
        let allowed = descriptors.indices.filter { results[$0] == .allowed }
        for index in allowed {
            let identity = KeyboardDeviceIdentity(descriptors[index])
            let duplicates = allowed.filter { KeyboardDeviceIdentity(descriptors[$0]) == identity }
            if duplicates.count > 1 { duplicates.forEach { results[$0] = .ambiguous } }
        }
        return results
    }
}

private extension Optional where Wrapped == String {
    var normalizedIdentityField: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    var normalizedTransport: String? { normalizedIdentityField?.lowercased() }
}
