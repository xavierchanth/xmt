import Foundation
import Speech

@available(macOS 26.0, *)
actor VoiceAssetManager {
    enum Status: Equatable { case unsupported; case missing; case downloading; case installed; case failure(String) }
    private var installing = false
    private var reservedLocale: Locale?

    /// On-demand snapshot only; this object performs no idle polling.
    func status(locale: Locale) async -> Status {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: return .unsupported
        case .supported: return .missing
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .failure("Unknown asset status")
        }
    }

    /// Must originate from an explicit user action. The supplied Foundation Progress is the SDK's
    /// live, event-observable progress object; no timer or fabricated percentage is used.
    func install(locale: Locale, progress: @escaping @Sendable (Progress) -> Void) async -> Status {
        guard !installing else { return .downloading }
        installing = true // sentinel is set before the first suspension point
        defer { installing = false }
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                return await status(locale: supported)
            }
            progress(request.progress)
            try await request.downloadAndInstall()
            return .installed
        } catch { return .failure(error.localizedDescription) }
    }

    func reserve(locale: Locale) async throws -> Bool {
        if let reservedLocale { return reservedLocale == locale }
        guard try await AssetInventory.reserve(locale: locale) else { return false }
        reservedLocale = locale; return true
    }

    @discardableResult func releaseReservation() async -> Bool {
        guard let locale = reservedLocale else { return true }
        let released = await AssetInventory.release(reservedLocale: locale)
        if released { reservedLocale = nil }
        return released
    }
}
