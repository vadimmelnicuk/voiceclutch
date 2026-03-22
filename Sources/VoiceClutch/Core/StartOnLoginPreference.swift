import Foundation
import ServiceManagement

enum StartOnLoginPreference {
    private static let defaultsKey = "startOnLoginEnabled"
    private static let defaultValue = true
    private static let logger = AppLogger(category: "StartOnLoginPreference")

    static func load(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: defaultsKey) != nil else {
            return defaultValue
        }

        return userDefaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: defaultsKey)
    }

    @discardableResult
    static func applyPreferredSetting(userDefaults: UserDefaults = .standard) -> Bool {
        setEnabled(load(userDefaults: userDefaults), userDefaults: userDefaults)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) -> Bool {
        let service = SMAppService.mainApp

        if enabled {
            do {
                try service.register()
                save(true, userDefaults: userDefaults)
                return true
            } catch {
                logger.warning("Failed to enable start on login: \(error.localizedDescription)")
                save(false, userDefaults: userDefaults)
                return false
            }
        }

        do {
            try service.unregister()
            save(false, userDefaults: userDefaults)
            return true
        } catch {
            logger.warning("Failed to disable start on login: \(error.localizedDescription)")
            return false
        }
    }
}
