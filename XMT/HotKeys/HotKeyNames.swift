import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let voiceHoldToTalk = Self("voiceHoldToTalk")
    static let voiceToggleRecording = Self("voiceToggleRecording")
    static let voiceCancel = Self("voiceCancel")
    static let voiceBindingSlotCount = VoiceBindingPersistence.maximumBindingsPerAction
    static func voiceBindingSlot(action: VoiceBindingAction, index: Int) -> Self {
        if index == 0 {
            switch action { case .holdToTalk: return .voiceHoldToTalk; case .toggleRecording: return .voiceToggleRecording; case .cancel: return .voiceCancel }
        }
        return Self("voice.\(action.rawValue).\(index)")
    }

    static let moveToNextScreen = Self(
        "moveToNextScreen",
        default: .init(.space, modifiers: [.option])
    )

    static let pasteLatestTranscript = Self(
        "pasteLatestTranscript",
        default: .init(.v, modifiers: [.control, .command])
    )
}
