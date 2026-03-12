import Foundation

enum ListeningInteractionMode: String, Sendable {
    case holdToTalk
    case listenToggle

    private static let defaultsKey = "listeningInteractionMode"
    private static let defaultValue: ListeningInteractionMode = .holdToTalk

    static func load() -> ListeningInteractionMode {
        guard
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let mode = ListeningInteractionMode(rawValue: rawValue)
        else {
            return defaultValue
        }

        return mode
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
