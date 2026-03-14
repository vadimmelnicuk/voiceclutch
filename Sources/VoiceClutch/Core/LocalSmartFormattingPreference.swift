import Foundation

enum LocalSmartFormattingPreference {
    private static let defaultsKey = "llmFinalPassEnabled"
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

extension LocalSmartFormattingPreference {
    private static let preloadDefaultsKey = "llmPreloadAtStartup"
    private static let preloadDefaultValue = true

    static func shouldPreloadAtStartup(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: preloadDefaultsKey) != nil else {
            return preloadDefaultValue
        }

        return userDefaults.bool(forKey: preloadDefaultsKey)
    }

    static func setPreloadAtStartup(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: preloadDefaultsKey)
    }
}
