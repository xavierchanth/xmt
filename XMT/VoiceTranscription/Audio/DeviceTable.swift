import CoreAudio
import Foundation

public struct DeviceTable: AudioDeviceProviding {
    public init() {}
    public func inputDevices() throws -> [AudioInputDevice] {
        try propertyArray(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices, as: AudioDeviceID.self)
            .compactMap { id in
                guard let uid: String = try? stringProperty(id, kAudioDevicePropertyDeviceUID),
                      let name: String = try? stringProperty(id, kAudioObjectPropertyName) else { return nil }
                let alive: UInt32 = (try? scalarProperty(id, kAudioDevicePropertyDeviceIsAlive)) ?? 0
                let transport: UInt32 = (try? scalarProperty(id, kAudioDevicePropertyTransportType)) ?? 0
                let inputBytes = (try? inputStreamConfigurationSize(id)) ?? 0
                return AudioInputDevice(uid: uid, name: name, transport: classify(transport),
                                        isAlive: alive != 0, hasInput: inputBytes > 0,
                                        bluetoothAddress: nil)
            }
    }

    public func systemDefaultInputUID() throws -> String? {
        let id: AudioDeviceID = try scalarProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        guard id != kAudioObjectUnknown else { return nil }
        return try stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private func classify(_ value: UInt32) -> AudioInputDevice.Transport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        default: return .other(value)
        }
    }

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func scalarProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        var property = address(selector)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, raw)
        guard status == noErr else { throw DeviceTableError.coreAudio(status) }
        return raw.load(as: T.self)
    }

    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var property = address(selector)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        guard status == noErr else { throw DeviceTableError.coreAudio(status) }
        guard let value else { throw DeviceTableError.missingProperty(selector) }
        return value.takeRetainedValue() as String
    }

    private func propertyArray<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, as: T.Type) throws -> [T] {
        var property = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size)
        guard status == noErr else { throw DeviceTableError.coreAudio(status) }
        let count = Int(size) / MemoryLayout<T>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, raw)
        guard status == noErr else { throw DeviceTableError.coreAudio(status) }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    private func inputStreamConfigurationSize(_ device: AudioDeviceID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size)
        guard status == noErr else { throw DeviceTableError.coreAudio(status) }
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var mutableSize = size
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &mutableSize, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }
}

public enum DeviceTableError: Error { case coreAudio(OSStatus); case missingProperty(AudioObjectPropertySelector) }
