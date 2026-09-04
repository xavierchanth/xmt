import Foundation

/// Build-only process boundary for the future protected-input owner. It exits without opening an
/// XPC listener or touching HID; the target proves that the owner domain compiles in isolation.
@main
enum XMTKeyboardOwnerMain {
    static func main() {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--protocol-version"] else { return }
        print(KeyboardWireEnvelope.currentVersion)
    }
}
