import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let moveToNextScreen = Self(
        "moveToNextScreen",
        default: .init(.space, modifiers: [.option])
    )
    static let rotateDesktops = Self(
        "rotateAllWindows",
        default: .init(.space, modifiers: [.option, .shift])
    )
}
