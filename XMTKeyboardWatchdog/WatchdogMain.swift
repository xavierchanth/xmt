import Foundation

/// Build-only process boundary for the future independent watchdog. It has no monitoring loop and
/// exits immediately unless asked to print the compile-time wire version.
@main
enum XMTKeyboardWatchdogMain {
    static func main() {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--protocol-version"] else { return }
        print(KeyboardWireEnvelope.currentVersion)
    }
}
