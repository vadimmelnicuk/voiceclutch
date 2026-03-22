import Foundation

public enum ListeningShortcut: String, CaseIterable, Sendable {
    case leftOption
    case rightOption
    case control
    case command
    case rightCommand
    case shift

    private static let defaultsKey = "listeningShortcut"

    static let defaultValue: ListeningShortcut = .leftOption

    var displayName: String {
        switch self {
        case .leftOption:
            return "Left Option"
        case .rightOption:
            return "Right Option"
        case .control:
            return "Control"
        case .command:
            return "Left Command"
        case .rightCommand:
            return "Right Command"
        case .shift:
            return "Shift"
        }
    }

    var symbol: String {
        switch self {
        case .leftOption, .rightOption:
            return "⌥"
        case .control:
            return "⌃"
        case .command, .rightCommand:
            return "⌘"
        case .shift:
            return "⇧"
        }
    }

    public var menuTitle: String {
        "\(symbol) \(displayName)"
    }

    public var hotkeyConfig: HotkeyConfig {
        let keyCode: UInt32

        switch self {
        case .leftOption:
            keyCode = HotkeyConfig.optionKey
        case .rightOption:
            keyCode = HotkeyConfig.rightOptionKey
        case .control:
            keyCode = HotkeyConfig.controlKey
        case .command:
            keyCode = HotkeyConfig.commandKey
        case .rightCommand:
            keyCode = HotkeyConfig.rightCommandKey
        case .shift:
            keyCode = HotkeyConfig.shiftKey
        }

        return HotkeyConfig(keyCode: keyCode, modifiers: 0)
    }

    public static func load() -> ListeningShortcut {
        guard
            let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
            let shortcut = ListeningShortcut(rawValue: rawValue)
        else {
            return defaultValue
        }

        return shortcut
    }

    public func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
