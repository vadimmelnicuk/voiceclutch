import Foundation

enum ClipboardContextFormattingPreference {
    private static let defaultsKey = "clipboardContextForLlmFormattingEnabled"
    private static let defaultValue = true

    static func load(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: defaultsKey) != nil else {
            return defaultValue
        }

        return userDefaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: defaultsKey)
    }
}
