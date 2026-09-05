@MainActor
extension LocalSettingsRepository {
    static let shared = LocalSettingsRepository(
        windowMover: WindowMoverModule.shared,
        voice: XMTBuildFeatures.voice ? VoiceTranscriptionModule.shared : nil,
        keyboard: KeyboardSettingsStore.shared
    )
}
