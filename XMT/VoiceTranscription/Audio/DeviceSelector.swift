import Foundation

public struct AudioInputDevice: Equatable, Sendable {
    public enum Transport: Equatable, Sendable { case builtIn, usb, bluetooth, other(UInt32) }

    public let uid: String
    public let name: String
    public let transport: Transport
    public let isAlive: Bool
    public let hasInput: Bool
    /// A documented Bluetooth address, when the adapter can establish one.
    public let bluetoothAddress: String?

    public init(uid: String, name: String, transport: Transport, isAlive: Bool, hasInput: Bool, bluetoothAddress: String?) {
        self.uid = uid; self.name = name; self.transport = transport; self.isAlive = isAlive; self.hasInput = hasInput; self.bluetoothAddress = bluetoothAddress
    }
}

public struct AudioDevicePreference: Equatable, Sendable {
    public let uid: String?
    let exactName: String?

    public init(uid: String? = nil, exactName: String? = nil) {
        self.uid = uid
        self.exactName = exactName
    }
}

public protocol AudioDeviceProviding {
    func inputDevices() throws -> [AudioInputDevice]
    func systemDefaultInputUID() throws -> String?
}

public protocol BluetoothLinkChecking {
    /// Read-only determination; unknown or ambiguous mappings return false.
    func isConnected(device: AudioInputDevice) -> Bool
}

public enum DeviceSelectionError: Error, Equatable {
    case noEligibleConfiguredDevice
    case systemDefaultUnavailable
    case systemDefaultIneligible
}

public struct DeviceSelector {
    public init(devices: AudioDeviceProviding, bluetooth: BluetoothLinkChecking) { self.devices = devices; self.bluetooth = bluetooth }
    let devices: AudioDeviceProviding
    let bluetooth: BluetoothLinkChecking

    public func select(priorities: [AudioDevicePreference], allowSystemDefaultFallback: Bool) throws -> AudioInputDevice {
        let available = try devices.inputDevices()
        for preference in priorities {
            if let uid = preference.uid, let candidate = available.first(where: { $0.uid == uid }) {
                if eligible(candidate) { return candidate }
                // A present stable identity must never drift to a different same-name device.
                continue
            }
            if let name = preference.exactName {
                let matches = available.filter { $0.name == name && eligible($0) }
                if matches.count == 1 { return matches[0] }
                // Zero or ambiguous migration matches are ineligible; continue priority order.
            }
        }
        guard allowSystemDefaultFallback else { throw DeviceSelectionError.noEligibleConfiguredDevice }
        guard let uid = try devices.systemDefaultInputUID(),
              let candidate = available.first(where: { $0.uid == uid }) else {
            throw DeviceSelectionError.systemDefaultUnavailable
        }
        guard eligible(candidate) else { throw DeviceSelectionError.systemDefaultIneligible }
        return candidate
    }

    private func eligible(_ device: AudioInputDevice) -> Bool {
        guard device.isAlive, device.hasInput else { return false }
        guard device.transport == .bluetooth else { return true }
        return bluetooth.isConnected(device: device)
    }
}
