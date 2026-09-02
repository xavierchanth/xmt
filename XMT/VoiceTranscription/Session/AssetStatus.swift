import Foundation
import Speech

@available(macOS 26.0, *)
actor VoiceAssetManager {
    enum Status: Equatable { case unsupported; case missing; case downloading; case installed; case failure(String) }
    private var installing = false

    func resolve(_ locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    func supportedLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales
    }

    /// Event-driven snapshot. `supported` means downloadable, not installed.
    func status(locale: Locale) async -> Status {
        guard let supported = await resolve(locale) else { return .unsupported }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: return .unsupported
        case .supported: return .missing
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .failure("Unknown asset status")
        }
    }

    /// Called only by the explicit Download button. Progress is Apple's observable object.
    func install(locale: Locale, progress: @escaping @Sendable (Progress) -> Void) async -> Status {
        guard !installing else { return .downloading }
        installing = true; defer { installing = false }
        guard let supported = await resolve(locale) else { return .unsupported }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                return await status(locale: supported)
            }
            progress(request.progress)
            try await request.downloadAndInstall()
            return await status(locale: supported)
        } catch { return .failure(error.localizedDescription) }
    }
}
