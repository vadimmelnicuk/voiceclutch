import Foundation

public enum ListeningShortcut: String, CaseIterable, Sendable {
    case leftOption
    case rightOption
    case control
    case command
    case rightCommand
    case shift
    case rightShift
    case rightControl
    case custom

    private static let defaultsKey = "listeningShortcut"
    private static let customConfigKey = "listeningShortcutCustomConfig"

    static let defaultValue: ListeningShortcut = .leftOption

    var displayName: String {
        switch self {
        case .leftOption:
            return "Left Option"
        case .rightOption:
            return "Right Option"
        case .control:
            return "Left Control"
        case .command:
            return "Left Command"
        case .rightCommand:
            return "Right Command"
        case .shift:
            return "Left Shift"
        case .rightShift:
            return "Right Shift"
        case .rightControl:
            return "Right Control"
        case .custom:
            return "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .leftOption, .rightOption:
            return "⌥"
        case .control:
            return "⌃"
        case .rightShift:
            return "⇧"
        case .command, .rightCommand:
            return "⌘"
        case .rightControl:
            return "⌃"
        case .shift:
            return "⇧"
        case .custom:
            return ""
        }
    }

    public var menuTitle: String {
        if self == .custom {
            return "Custom"
        }

        return "\(symbol) \(displayName)"
    }

    public var hotkeyConfig: HotkeyConfig {
        let keyCode: UInt32

        switch self {
        case .control:
            keyCode = HotkeyConfig.controlKey
        case .leftOption:
            keyCode = HotkeyConfig.optionKey
        case .rightOption:
            keyCode = HotkeyConfig.rightOptionKey
        case .command:
            keyCode = HotkeyConfig.commandKey
        case .rightCommand:
            keyCode = HotkeyConfig.rightCommandKey
        case .rightControl:
            keyCode = HotkeyConfig.rightControlKey
        case .shift:
            keyCode = HotkeyConfig.shiftKey
        case .rightShift:
            keyCode = HotkeyConfig.rightShiftKey
        case .custom:
            return Self.customConfig()
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

    public static func customConfig() -> HotkeyConfig {
        guard
            let rawValues = UserDefaults.standard.array(forKey: customConfigKey),
            !rawValues.isEmpty
        else {
            return HotkeyConfig.default()
        }

        let keyCodes = Set(
            rawValues.compactMap { value in
                if let number = value as? NSNumber {
                    return number.uint32Value
                }

                if let integer = value as? Int {
                    return UInt32(integer)
                }

                return nil
            }
        )

        guard !keyCodes.isEmpty else {
            return HotkeyConfig.default()
        }

        return HotkeyConfig(keyCodes: Array(keyCodes))
    }

    public static func saveCustomConfig(_ config: HotkeyConfig) {
        let sortedCodes = config.requiredKeyCodes.sorted()
        let storedValues = sortedCodes.map { NSNumber(value: $0) }
        UserDefaults.standard.set(storedValues, forKey: customConfigKey)
    }

    public func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
