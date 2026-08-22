import Foundation
import IOBluetooth

/// Read-only link-state adapter. It never performs discovery or opens a connection.
public struct BluetoothLinkOracle: BluetoothLinkChecking {
    public init() {}

    public func isConnected(device input: AudioInputDevice) -> Bool {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let matches: [IOBluetoothDevice]
        if let address = input.bluetoothAddress {
            matches = paired.filter { $0.addressString.caseInsensitiveCompare(address) == .orderedSame }
        } else {
            // HAL exposes no documented Bluetooth address. Exact unique paired-name mapping is
            // intentionally fail-closed; duplicate names cannot identify the selected HAL device.
            matches = paired.filter { $0.name == input.name }
        }
        guard matches.count == 1 else { return false }
        return matches[0].isConnected()
    }
}
