import XCTest
@testable import XMT

final class DeviceSelectorTests: XCTestCase {
    private let builtIn = AudioInputDevice(uid: "builtin", name: "Mac Microphone", transport: .builtIn, isAlive: true, hasInput: true, bluetoothAddress: nil)

    func testPriorityOrderAndUIDBeforeNameFallback() throws {
        let named = device("named", "Headset")
        let uid = device("wanted", "Other")
        let selector = make([builtIn, named, uid])
        let result = try selector.select(priorities: [
            .init(uid: "missing", exactName: "Headset"), .init(uid: "wanted", exactName: nil)
        ], allowSystemDefaultFallback: false)
        XCTAssertEqual(result, named)
    }

    func testSkipsAbsentDeadAndInputlessEntries() throws {
        let dead = AudioInputDevice(uid: "dead", name: "Dead", transport: .usb, isAlive: false, hasInput: true, bluetoothAddress: nil)
        let output = AudioInputDevice(uid: "output", name: "Output", transport: .usb, isAlive: true, hasInput: false, bluetoothAddress: nil)
        let selector = make([dead, output, builtIn])
        XCTAssertEqual(try selector.select(priorities: [.init(uid: "absent"), .init(uid: "dead"), .init(uid: "output"), .init(uid: "builtin")], allowSystemDefaultFallback: false), builtIn)
    }

    func testBluetoothRequiresKnownAlreadyConnectedAddress() throws {
        let unknown = AudioInputDevice(uid: "unknown", name: "Unknown", transport: .bluetooth, isAlive: true, hasInput: true, bluetoothAddress: nil)
        let unlinked = AudioInputDevice(uid: "off", name: "Off", transport: .bluetooth, isAlive: true, hasInput: true, bluetoothAddress: "AA")
        let linked = AudioInputDevice(uid: "on", name: "On", transport: .bluetooth, isAlive: true, hasInput: true, bluetoothAddress: "BB")
        let oracle = FakeBluetooth(connected: ["BB"])
        let selector = DeviceSelector(devices: FakeDevices(all: [unknown, unlinked, linked], defaultUID: nil), bluetooth: oracle)
        XCTAssertEqual(try selector.select(priorities: [.init(uid: "unknown"), .init(uid: "off"), .init(uid: "on")], allowSystemDefaultFallback: false), linked)
        XCTAssertEqual(oracle.queries, ["unknown", "off", "on"])
    }

    func testFallbackIsSeparateAndUsesEligibilityRules() {
        let unsafeDefault = AudioInputDevice(uid: "bt", name: "BT", transport: .bluetooth, isAlive: true, hasInput: true, bluetoothAddress: nil)
        XCTAssertThrowsError(try make([unsafeDefault], defaultUID: "bt").select(priorities: [], allowSystemDefaultFallback: true)) {
            XCTAssertEqual($0 as? DeviceSelectionError, .systemDefaultIneligible)
        }
        XCTAssertThrowsError(try make([builtIn], defaultUID: "builtin").select(priorities: [], allowSystemDefaultFallback: false)) {
            XCTAssertEqual($0 as? DeviceSelectionError, .noEligibleConfiguredDevice)
        }
    }

    func testFallbackReadsButNeverMutatesDefault() throws {
        let table = FakeDevices(all: [builtIn], defaultUID: "builtin")
        let result = try DeviceSelector(devices: table, bluetooth: FakeBluetooth()).select(priorities: [], allowSystemDefaultFallback: true)
        XCTAssertEqual(result, builtIn)
        XCTAssertEqual(table.defaultReads, 1) // Protocol intentionally exposes no setter.
    }

    func testBoundedQueueOverflowIsTerminalAndVisible() async throws {
        let queue = BoundedAudioQueue<Int>(capacity: 1)
        XCTAssertSuccess(queue.send(1))
        XCTAssertFailure(queue.send(2), equals: .overflow)
        XCTAssertFailure(queue.send(3), equals: .closed)
        var iterator = queue.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, 1)
        do { _ = try await iterator.next(); XCTFail("expected overflow") }
        catch { XCTAssertEqual(error as? BoundedAudioQueueError, .overflow) }
    }

    func testBoundedQueueFinishDrainsThenEndsAndRejectsClosedSend() async throws {
        let queue = BoundedAudioQueue<Int>(capacity: 2)
        _ = queue.send(1); _ = queue.send(2); queue.finish()
        XCTAssertFailure(queue.send(3), equals: .closed)
        var values: [Int] = []
        for try await value in queue { values.append(value) }
        XCTAssertEqual(values, [1, 2])
    }

    func testBoundedQueueRejectsSecondConsumerWithTypedError() async throws {
        let queue = BoundedAudioQueue<Int>(capacity: 1)
        var first = queue.makeAsyncIterator()
        var second = queue.makeAsyncIterator()
        _ = queue.send(7)
        let value = try await first.next()
        XCTAssertEqual(value, 7)
        do { _ = try await second.next(); XCTFail("expected multiple-consumer error") }
        catch { XCTAssertEqual(error as? BoundedAudioQueueError, .multipleConsumers) }
        queue.finish()
    }

    private func device(_ uid: String, _ name: String) -> AudioInputDevice {
        .init(uid: uid, name: name, transport: .usb, isAlive: true, hasInput: true, bluetoothAddress: nil)
    }
    private func make(_ all: [AudioInputDevice], defaultUID: String? = nil) -> DeviceSelector {
        DeviceSelector(devices: FakeDevices(all: all, defaultUID: defaultUID), bluetooth: FakeBluetooth())
    }
}

private final class FakeDevices: AudioDeviceProviding {
    let all: [AudioInputDevice]; let defaultUID: String?; var defaultReads = 0
    init(all: [AudioInputDevice], defaultUID: String?) { self.all = all; self.defaultUID = defaultUID }
    func inputDevices() throws -> [AudioInputDevice] { all }
    func systemDefaultInputUID() throws -> String? { defaultReads += 1; return defaultUID }
}

private final class FakeBluetooth: BluetoothLinkChecking {
    let connected: Set<String>; var queries: [String] = []
    init(connected: Set<String> = []) { self.connected = connected }
    func isConnected(device: AudioInputDevice) -> Bool {
        queries.append(device.uid)
        guard let address = device.bluetoothAddress else { return false }
        return connected.contains(address)
    }
}

private func XCTAssertSuccess(_ result: Result<Void, Error>, file: StaticString = #filePath, line: UInt = #line) {
    if case .failure(let error) = result { XCTFail("unexpected failure: \(error)", file: file, line: line) }
}
private func XCTAssertFailure(_ result: Result<Void, Error>, equals expected: BoundedAudioQueueError, file: StaticString = #filePath, line: UInt = #line) {
    guard case .failure(let error) = result else { return XCTFail("expected failure", file: file, line: line) }
    XCTAssertEqual(error as? BoundedAudioQueueError, expected, file: file, line: line)
}
