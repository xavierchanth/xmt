import Foundation

enum KeyboardSettingsError: Error { case unavailable }

@MainActor
protocol KeyboardLocalSettingsAdapter: AnyObject {
    func readKeyboardLocalSettings() -> KeyboardCustomizationDTO
    func persistKeyboardLocalSettings(_ value: KeyboardCustomizationDTO) throws
}

/// Preferences only. This store never discovers, opens, or acquires an input device.
@MainActor
final class KeyboardSettingsStore: KeyboardLocalSettingsAdapter {
    static let shared = KeyboardSettingsStore()
    static let storageKey = "keyboardCustomization.settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func readKeyboardLocalSettings() -> KeyboardCustomizationDTO {
        guard let data = defaults.data(forKey: Self.storageKey),
              let value = try? JSONDecoder().decode(KeyboardCustomizationDTO.self, from: data),
              (try? value.validate()) != nil else { return .init() }
        return value
    }

    func persistKeyboardLocalSettings(_ value: KeyboardCustomizationDTO) throws {
        try value.validate()
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: Self.storageKey)
    }
}
