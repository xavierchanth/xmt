@MainActor
extension LocalSettingsRepository {
    static let shared = LocalSettingsRepository(
        windowMover: WindowMoverModule.shared,
        voice: VoiceTranscriptionModule.shared
    )
}
