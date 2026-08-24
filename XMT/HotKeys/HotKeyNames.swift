import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let moveToNextScreen = Self(
        "moveToNextScreen",
        default: .init(.space, modifiers: [.option])
    )

    static let pasteLatestTranscript = Self(
        "pasteLatestTranscript",
        default: .init(.v, modifiers: [.control, .command])
    )
}
