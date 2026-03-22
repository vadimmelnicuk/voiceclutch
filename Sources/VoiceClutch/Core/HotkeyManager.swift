import Foundation
import CoreGraphics
import ApplicationServices
import Carbon

// MARK: - Hotkey Event Types

public enum HotkeyEventType: Int32, Sendable {
    case pressed = 0
    case released = 1
}

public enum ObservedKeyEventKind: Sendable {
    case keyDown
    case keyUp
    case flagsChanged
}

public struct ObservedKeyEvent: Sendable {
    public let kind: ObservedKeyEventKind
    public let keyCode: UInt32
    public let modifierFlagsRawValue: UInt64
    public let characters: String?
    public let eventSourceUserData: Int64

    public init(
        kind: ObservedKeyEventKind,
        keyCode: UInt32,
        modifierFlagsRawValue: UInt64,
        characters: String? = nil,
        eventSourceUserData: Int64 = 0
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlagsRawValue = modifierFlagsRawValue
        self.characters = characters
        self.eventSourceUserData = eventSourceUserData
    }
}

// MARK: - Hotkey Configuration

public struct HotkeyConfig: Sendable, Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let requiredKeyCodes: Set<UInt32>
    
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.requiredKeyCodes = Set([keyCode])
    }

    public init(keyCodes: [UInt32]) {
        let normalized = Set(keyCodes)
        let fallback = normalized.sorted().first ?? HotkeyConfig.controlKey

        self.keyCode = fallback
        self.modifiers = 0
        self.requiredKeyCodes = normalized.isEmpty ? Set([fallback]) : normalized
    }
    
    // Common key codes
    public static let optionKey: UInt32 = 0x3A  // Left Option/Alt
    public static let rightOptionKey: UInt32 = 0x3D  // Right Option/Alt
    public static let commandKey: UInt32 = 0x37  // Left Command
    public static let rightCommandKey: UInt32 = 0x36  // Right Command
    public static let shiftKey: UInt32 = 0x38  // Left Shift
    public static let rightShiftKey: UInt32 = 0x3C  // Right Shift
    public static let controlKey: UInt32 = 0x3B  // Left Control
    public static let rightControlKey: UInt32 = 0x3E  // Right Control
    public static let spaceKey: UInt32 = 0x31
    
    public static let modifierKeyCodes: Set<UInt32> = [
        optionKey,
        rightOptionKey,
        commandKey,
        rightCommandKey,
        shiftKey,
        rightShiftKey,
        controlKey,
        rightControlKey
    ]

    static let modifierFlagsByKeyCode: [UInt32: CGEventFlags] = [
        optionKey: .maskAlternate,
        rightOptionKey: .maskAlternate,
        commandKey: .maskCommand,
        rightCommandKey: .maskCommand,
        shiftKey: .maskShift,
        rightShiftKey: .maskShift,
        controlKey: .maskControl,
        rightControlKey: .maskControl
    ]

    public var isValid: Bool {
        !requiredKeyCodes.isEmpty
    }
    
    public var displayText: String {
        let keyNames = requiredKeyCodes
            .sorted { lhs, rhs in
                let lhsIsModifier = Self.modifierKeyCodes.contains(lhs)
                let rhsIsModifier = Self.modifierKeyCodes.contains(rhs)
                if lhsIsModifier != rhsIsModifier {
                    return lhsIsModifier && !rhsIsModifier
                }
                return lhs < rhs
            }
            .map(Self.displayName(for:))
            .filter { !$0.isEmpty }

        return keyNames.joined(separator: " + ")
    }
    
    public static func displayName(for keyCode: UInt32) -> String {
        if let displayName = namedKeyName(by: keyCode) {
            return displayName
        }

        switch keyCode {
        case commandKey, rightCommandKey:
            return "⌘"
        case optionKey, rightOptionKey:
            return "⌥"
        case controlKey, rightControlKey:
            return "⌃"
        case shiftKey, rightShiftKey:
            return "⇧"
        case spaceKey:
            return "Space"
        default:
            return "0x\(String(keyCode, radix: 16, uppercase: true))"
        }
    }

    private static func namedKeyName(by keyCode: UInt32) -> String? {
        switch keyCode {
        case UInt32(kVK_Escape):
            return "Esc"
        case UInt32(kVK_Delete):
            return "Delete"
        case UInt32(kVK_Tab):
            return "Tab"
        case UInt32(kVK_Return):
            return "Return"
        case UInt32(kVK_ANSI_Grave):
            return "`"
        case UInt32(kVK_ANSI_1):
            return "1"
        case UInt32(kVK_ANSI_2):
            return "2"
        case UInt32(kVK_ANSI_3):
            return "3"
        case UInt32(kVK_ANSI_4):
            return "4"
        case UInt32(kVK_ANSI_5):
            return "5"
        case UInt32(kVK_ANSI_6):
            return "6"
        case UInt32(kVK_ANSI_7):
            return "7"
        case UInt32(kVK_ANSI_8):
            return "8"
        case UInt32(kVK_ANSI_9):
            return "9"
        case UInt32(kVK_ANSI_0):
            return "0"
        case UInt32(kVK_ANSI_Minus):
            return "-"
        case UInt32(kVK_ANSI_Equal):
            return "="
        case UInt32(kVK_ANSI_Q):
            return "Q"
        case UInt32(kVK_ANSI_W):
            return "W"
        case UInt32(kVK_ANSI_E):
            return "E"
        case UInt32(kVK_ANSI_R):
            return "R"
        case UInt32(kVK_ANSI_T):
            return "T"
        case UInt32(kVK_ANSI_Y):
            return "Y"
        case UInt32(kVK_ANSI_U):
            return "U"
        case UInt32(kVK_ANSI_I):
            return "I"
        case UInt32(kVK_ANSI_O):
            return "O"
        case UInt32(kVK_ANSI_P):
            return "P"
        case UInt32(kVK_ANSI_LeftBracket):
            return "["
        case UInt32(kVK_ANSI_RightBracket):
            return "]"
        case UInt32(kVK_ANSI_A):
            return "A"
        case UInt32(kVK_ANSI_S):
            return "S"
        case UInt32(kVK_ANSI_D):
            return "D"
        case UInt32(kVK_ANSI_F):
            return "F"
        case UInt32(kVK_ANSI_G):
            return "G"
        case UInt32(kVK_ANSI_H):
            return "H"
        case UInt32(kVK_ANSI_J):
            return "J"
        case UInt32(kVK_ANSI_K):
            return "K"
        case UInt32(kVK_ANSI_L):
            return "L"
        case UInt32(kVK_ANSI_Semicolon):
            return ";"
        case UInt32(kVK_ANSI_Quote):
            return "'"
        case UInt32(kVK_ANSI_Z):
            return "Z"
        case UInt32(kVK_ANSI_X):
            return "X"
        case UInt32(kVK_ANSI_C):
            return "C"
        case UInt32(kVK_ANSI_V):
            return "V"
        case UInt32(kVK_ANSI_B):
            return "B"
        case UInt32(kVK_ANSI_N):
            return "N"
        case UInt32(kVK_ANSI_M):
            return "M"
        case UInt32(kVK_ANSI_Comma):
            return ","
        case UInt32(kVK_ANSI_Period):
            return "."
        case UInt32(kVK_ANSI_Slash):
            return "/"
        case UInt32(kVK_ANSI_Backslash):
            return "\\"
        case spaceKey:
            return "Space"
        case UInt32(kVK_ANSI_KeypadDecimal):
            return "Numpad ."
        case UInt32(kVK_ANSI_KeypadMultiply):
            return "Numpad *"
        case UInt32(kVK_ANSI_KeypadPlus):
            return "Numpad +"
        case UInt32(kVK_ANSI_KeypadMinus):
            return "Numpad -"
        case UInt32(kVK_ANSI_KeypadDivide):
            return "Numpad /"
        case UInt32(kVK_ANSI_KeypadEnter):
            return "Numpad Enter"
        case UInt32(kVK_ANSI_Keypad0):
            return "Numpad 0"
        case UInt32(kVK_ANSI_Keypad1):
            return "Numpad 1"
        case UInt32(kVK_ANSI_Keypad2):
            return "Numpad 2"
        case UInt32(kVK_ANSI_Keypad3):
            return "Numpad 3"
        case UInt32(kVK_ANSI_Keypad4):
            return "Numpad 4"
        case UInt32(kVK_ANSI_Keypad5):
            return "Numpad 5"
        case UInt32(kVK_ANSI_Keypad6):
            return "Numpad 6"
        case UInt32(kVK_ANSI_Keypad7):
            return "Numpad 7"
        case UInt32(kVK_ANSI_Keypad8):
            return "Numpad 8"
        case UInt32(kVK_ANSI_Keypad9):
            return "Numpad 9"
        case UInt32(kVK_ANSI_KeypadEquals):
            return "Numpad ="
        case UInt32(kVK_LeftArrow):
            return "←"
        case UInt32(kVK_RightArrow):
            return "→"
        case UInt32(kVK_DownArrow):
            return "↓"
        case UInt32(kVK_UpArrow):
            return "↑"
        case UInt32(kVK_PageUp):
            return "Page Up"
        case UInt32(kVK_PageDown):
            return "Page Down"
        case UInt32(kVK_Home):
            return "Home"
        case UInt32(kVK_End):
            return "End"
        case UInt32(kVK_F1):
            return "F1"
        case UInt32(kVK_F2):
            return "F2"
        case UInt32(kVK_F3):
            return "F3"
        case UInt32(kVK_F4):
            return "F4"
        case UInt32(kVK_F5):
            return "F5"
        case UInt32(kVK_F6):
            return "F6"
        case UInt32(kVK_F7):
            return "F7"
        case UInt32(kVK_F8):
            return "F8"
        case UInt32(kVK_F9):
            return "F9"
        case UInt32(kVK_F10):
            return "F10"
        case UInt32(kVK_F11):
            return "F11"
        case UInt32(kVK_F12):
            return "F12"
        case UInt32(kVK_F13):
            return "F13"
        case UInt32(kVK_F14):
            return "F14"
        case UInt32(kVK_F15):
            return "F15"
        case UInt32(kVK_F16):
            return "F16"
        case UInt32(kVK_F17):
            return "F17"
        case UInt32(kVK_F18):
            return "F18"
        case UInt32(kVK_F19):
            return "F19"
        case UInt32(kVK_F20):
            return "F20"
        default:
            return keyboardDisplayName(for: keyCode)
        }
    }

    private static func keyboardDisplayName(for keyCode: UInt32) -> String? {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        ) else {
            return nil
        }

        var length = 0
        var string = [UniChar](repeating: 0, count: 4)
        string.withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                event.keyboardGetUnicodeString(
                    maxStringLength: buffer.count,
                    actualStringLength: &length,
                    unicodeString: baseAddress
                )
            }
        }
        guard length > 0 else {
            return nil
        }

        let value = String(decoding: string.prefix(length), as: UTF16.self)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    // Default: Left Control key alone
    public static func `default`() -> HotkeyConfig {
        HotkeyConfig(
            keyCode: controlKey,
            modifiers: 0  // No modifiers for single key
        )
    }
}

// MARK: - Hotkey Callback

public typealias HotkeyCallback = @Sendable (HotkeyEventType) -> Void
public typealias RawKeyEventObserver = @Sendable (ObservedKeyEvent) -> Void

// MARK: - Hotkey Manager

public class HotkeyManager: @unchecked Sendable {
    private var callback: HotkeyCallback?
    private var rawEventObserver: RawKeyEventObserver?
    private var isPressed = false
    private var config: HotkeyConfig?
    private var pressedKeyCodes = Set<UInt32>()
    
    // CGEventTap resources
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Serial queue for thread-safe access
    private let queue = DispatchQueue(label: "dev.vm.voiceclutch.hotkey", qos: .userInteractive)
    
    public init() {}
    
    deinit {
        unregister()
    }
    
    // MARK: - Registration
    
    /// Register a global hotkey with the system using CGEventTap
    /// - Parameters:
    ///   - config: Hotkey configuration (key code and modifiers)
    ///   - callback: Called when hotkey is pressed or released
    /// - Returns: True on success
    public func register(config: HotkeyConfig = HotkeyConfig.default(), callback: @escaping HotkeyCallback) -> Bool {
        // Must run on main thread for CGEventTap
        if Thread.isMainThread {
            return performRegistrationWithRetry(config: config, callback: callback, attempt: 1)
        } else {
            return DispatchQueue.main.sync {
                return self.performRegistrationWithRetry(config: config, callback: callback, attempt: 1)
            }
        }
    }

    public func setRawEventObserver(_ observer: RawKeyEventObserver?) {
        queue.sync {
            self.rawEventObserver = observer
        }
    }
    
    /// Attempt registration with retry logic for TCC permission propagation delays
    private func performRegistrationWithRetry(config: HotkeyConfig, callback: @escaping HotkeyCallback, attempt: Int, maxAttempts: Int = 3) -> Bool {
        let success = performRegistration(config: config, callback: callback)
        
        if success {
            return true
        }
        
        if attempt < maxAttempts {
            // Check if we actually have permissions (TCC might just need time to propagate)
            let options = NSMutableDictionary()
            options.setObject(false, forKey: "AXTrustedCheckOptionPrompt" as NSString)
            let isTrusted = AXIsProcessTrustedWithOptions(options)
            
            if isTrusted {
                Thread.sleep(forTimeInterval: Double(attempt) * 0.1) // 100ms, 200ms, etc.
                return performRegistrationWithRetry(config: config, callback: callback, attempt: attempt + 1, maxAttempts: maxAttempts)
            }
        }
        
        return false
    }
    
    private func performRegistration(config: HotkeyConfig, callback: @escaping HotkeyCallback) -> Bool {
        // Unregister any existing hotkey
        self.unregister()
        
        self.config = config
        self.callback = callback
        self.isPressed = false
        self.pressedKeyCodes.removeAll()

        // Check current accessibility state before attempting creation
        let options = NSMutableDictionary()
        options.setObject(false, forKey: "AXTrustedCheckOptionPrompt" as NSString)
        _ = AXIsProcessTrustedWithOptions(options)

        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)
        
        // Keep reference to self for the callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            print("❌ Failed to create hotkey event tap")
            return false
        }
        
        self.eventTap = tap
        
        // Create run loop source and add to main run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        
        // Enable the event tap
        CGEvent.tapEnable(tap: tap, enable: true)

        return true
    }
    
    /// Unregister the hotkey and clean up
    public func unregister() {
        queue.sync {
            // Disable and remove event tap
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let source = self.runLoopSource {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                }
                self.eventTap = nil
                self.runLoopSource = nil
            }

            // Clear callback and state
            self.callback = nil
            self.config = nil
            self.isPressed = false
            self.pressedKeyCodes.removeAll()
        }
    }
    
    // MARK: - Event Handling

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            var callbackToEmit: HotkeyCallback?
            var shouldEmitRelease = false
            var tapToEnable: CFMachPort?

            queue.sync {
                callbackToEmit = self.callback
                tapToEnable = self.eventTap
                self.pressedKeyCodes.removeAll()
                if self.isPressed {
                    self.isPressed = false
                    shouldEmitRelease = true
                }
            }

            if let tapToEnable {
                CGEvent.tapEnable(tap: tapToEnable, enable: true)
            }

            if shouldEmitRelease {
                invokeCallback(.released, callbackToEmit)
            }

            return Unmanaged.passUnretained(event)
        }

        // Ignore synthetic events emitted by TextInjector to avoid re-entrant
        // hotkey press/release transitions while streaming text updates.
        let sourceTag = event.getIntegerValueField(.eventSourceUserData)
        if sourceTag == TextInjector.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        var eventTypeToEmit: HotkeyEventType?
        var callbackToEmit: HotkeyCallback?
        var rawEventObserverToEmit: RawKeyEventObserver?
        let observedKeyEvent = makeObservedKeyEvent(from: event, type: type, keyCode: keyCode)

        queue.sync {
            guard let config = self.config, config.isValid else {
                rawEventObserverToEmit = self.rawEventObserver
                return
            }
            callbackToEmit = self.callback
            rawEventObserverToEmit = self.rawEventObserver

            switch type {
            case .flagsChanged:
                guard HotkeyConfig.modifierKeyCodes.contains(keyCode) else {
                    return
                }

                let wasPressed = pressedKeyCodes.contains(keyCode)
                if isSpecificModifierPressed(flags, keyCode: keyCode, wasPressed: wasPressed) {
                    pressedKeyCodes.insert(keyCode)
                } else {
                    pressedKeyCodes.remove(keyCode)
                }
            case .keyDown:
                pressedKeyCodes.insert(keyCode)
            case .keyUp:
                pressedKeyCodes.remove(keyCode)
            default:
                return
            }

            if !config.requiredKeyCodes.isSubset(of: pressedKeyCodes) {
                if isPressed {
                    isPressed = false
                    eventTypeToEmit = .released
                }
                return
            }

            if !isPressed {
                isPressed = true
                eventTypeToEmit = .pressed
            }
        }
        
        if let eventTypeToEmit {
            invokeCallback(eventTypeToEmit, callbackToEmit)
        }

        if let observedKeyEvent, let rawEventObserverToEmit {
            rawEventObserverToEmit(observedKeyEvent)
        }

        return Unmanaged.passUnretained(event)
    }
    
    private func invokeCallback(_ eventType: HotkeyEventType, _ callback: HotkeyCallback?) {
        callback?(eventType)
    }

    private func makeObservedKeyEvent(
        from event: CGEvent,
        type: CGEventType,
        keyCode: UInt32
    ) -> ObservedKeyEvent? {
        let kind: ObservedKeyEventKind
        switch type {
        case .keyDown:
            kind = .keyDown
        case .keyUp:
            kind = .keyUp
        case .flagsChanged:
            kind = .flagsChanged
        default:
            return nil
        }

        return ObservedKeyEvent(
            kind: kind,
            keyCode: keyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            characters: extractCharacters(from: event),
            eventSourceUserData: event.getIntegerValueField(.eventSourceUserData)
        )
    }

    private func extractCharacters(from event: CGEvent) -> String? {
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        characters.withUnsafeMutableBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                event.keyboardGetUnicodeString(
                    maxStringLength: buffer.count,
                    actualStringLength: &length,
                    unicodeString: baseAddress
                )
            }
        }

        guard length > 0 else {
            return nil
        }

        return String(decoding: characters.prefix(length), as: UTF16.self)
    }
    
    // MARK: - Helper Methods
    
    private func isSpecificModifierPressed(
        _ flags: CGEventFlags,
        keyCode: UInt32,
        wasPressed: Bool
    ) -> Bool {
        guard let modifierFlag = HotkeyConfig.modifierFlagsByKeyCode[keyCode] else { return false }

        // flagsChanged reports aggregate modifier bits (left/right merged). When
        // the aggregate bit remains set, use transition history for this keyCode
        // to disambiguate press vs release of each physical side.
        if !flags.contains(modifierFlag) {
            return false
        }

        return !wasPressed
    }
    
    // MARK: - State Queries
    
    public func isHotkeyPressed() -> Bool {
        return queue.sync { isPressed }
    }
}
