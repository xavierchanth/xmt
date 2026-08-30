import XCTest

final class DeviceIdentityMatcherTests: XCTestCase {
    private let external = KeyboardDeviceDescriptor(builtIn: false, vendorID: 0x1234, productID: 0x5678, serialNumber: "unit-a", locationID: 7, transport: "USB")

    func testExactSyntheticIdentityIsAllowed() {
        XCTAssertEqual(policy(rule()).evaluate(external), .allowed)
    }

    func testExcludeAlwaysWins() {
        XCTAssertEqual(KeyboardDevicePolicy(allow: [rule()], exclude: [rule()]).evaluate(external), .excluded)
    }

    func testMissingOptionalIdentityDoesNotSatisfySpecificRule() {
        let anonymous = KeyboardDeviceDescriptor(builtIn: false, vendorID: 0x1234, productID: 0x5678, serialNumber: nil, locationID: nil, transport: "USB")
        XCTAssertEqual(policy(rule()).evaluate(anonymous), .unmatched)
    }

    func testBuiltInAndExternalCannotAlias() {
        var builtInRule = rule()
        builtInRule = KeyboardDeviceRule(builtIn: true, vendorID: builtInRule.vendorID, productID: builtInRule.productID, serialNumber: builtInRule.serialNumber, locationID: builtInRule.locationID, transport: builtInRule.transport)
        XCTAssertEqual(policy(builtInRule).evaluate(external), .unmatched)
    }

    func testOverlappingAllowRulesAreRejectedAsAmbiguous() {
        let broad = KeyboardDeviceRule(builtIn: false, vendorID: 0x1234, productID: 0x5678, serialNumber: nil, locationID: nil, transport: nil)
        XCTAssertEqual(KeyboardDevicePolicy(allow: [broad, rule()], exclude: []).evaluate(external), .ambiguous)
    }

    func testTransportIsCaseInsensitiveButSerialIsNot() {
        XCTAssertEqual(policy(rule(transport: "usb")).evaluate(external), .allowed)
        XCTAssertEqual(policy(rule(serial: "UNIT-A")).evaluate(external), .unmatched)
    }

    private func rule(serial: String = "unit-a", transport: String = "USB") -> KeyboardDeviceRule {
        KeyboardDeviceRule(builtIn: false, vendorID: 0x1234, productID: 0x5678, serialNumber: serial, locationID: 7, transport: transport)
    }
    private func policy(_ rule: KeyboardDeviceRule) -> KeyboardDevicePolicy { .init(allow: [rule], exclude: []) }
}
