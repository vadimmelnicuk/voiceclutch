import Foundation

enum MicrophoneChimePreference {
    private static let defaultsKey = "playMicrophoneChimes"
    private static let defaultValue = true

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
