import Foundation
import Speech

@available(macOS 26.0, *)
actor VoiceAssetManager {
    struct Reservation: Equatable, Sendable {
        fileprivate let id: UUID
        let locale: Locale
    }

    enum Status: Equatable { case unsupported; case missing; case downloading; case installed; case failure(String) }
    private var installing = false
    private var reservation: Reservation?

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

    func reserve(locale: Locale) async throws -> Reservation? {
        guard reservation == nil else { return nil }
        guard try await AssetInventory.reserve(locale: locale) else { return nil }
        let token = Reservation(id: UUID(), locale: locale)
        reservation = token
        return token
    }

    @discardableResult func release(_ token: Reservation) async -> Bool {
        guard reservation?.id == token.id else { return false }
        // Keep ownership recorded across the suspension so another caller cannot reserve a new
        // locale that a stale release would then accidentally relinquish.
        let released = await AssetInventory.release(reservedLocale: token.locale)
        if reservation?.id == token.id { reservation = nil }
        return released
    }
}
