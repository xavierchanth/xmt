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
        serialNumber = descriptor.serialNumber?.nilIfEmpty
        locationID = descriptor.locationID
        transport = descriptor.transport?.nilIfEmpty?.lowercased()
    }
}

struct KeyboardDeviceRule: Hashable, Sendable {
    let builtIn: Bool
    let vendorID: UInt16
    let productID: UInt16
    let serialNumber: String?
    let locationID: UInt32?
    let transport: String?

    func matches(_ identity: KeyboardDeviceIdentity) -> Bool {
        guard builtIn == identity.builtIn, vendorID == identity.vendorID,
              productID == identity.productID else { return false }
        if let serialNumber, serialNumber != identity.serialNumber { return false }
        if let locationID, locationID != identity.locationID { return false }
        if let transport, transport.lowercased() != identity.transport { return false }
        return true
    }
}

enum KeyboardDeviceMatch: Equatable { case allowed, excluded, unmatched, ambiguous }

struct KeyboardDevicePolicy: Sendable {
    let allow: [KeyboardDeviceRule]
    let exclude: [KeyboardDeviceRule]

    func evaluate(_ descriptor: KeyboardDeviceDescriptor) -> KeyboardDeviceMatch {
        let identity = KeyboardDeviceIdentity(descriptor)
        if exclude.contains(where: { $0.matches(identity) }) { return .excluded }
        let matches = allow.filter { $0.matches(identity) }
        guard !matches.isEmpty else { return .unmatched }
        // More than one policy rule claiming a device is a configuration error,
        // even if the rules happen to be identical.
        return matches.count == 1 ? .allowed : .ambiguous
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
