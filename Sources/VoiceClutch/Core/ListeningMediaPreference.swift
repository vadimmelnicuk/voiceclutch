import Foundation

enum ListeningMediaPreference {
    private static let defaultsKey = "pauseMediaWhileListening"
    private static let defaultValue = false

    static func load() -> Bool {
        guard UserDefaults.standard.object(forKey: defaultsKey) != nil else {
            return defaultValue
        }

        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }
}
