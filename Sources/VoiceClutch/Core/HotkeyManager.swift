import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Hotkey Event Types

public enum HotkeyEventType: Int32, Sendable {
    case pressed = 0
    case released = 1
}

// MARK: - Hotkey Configuration

public struct HotkeyConfig: Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    
    // Common key codes
    public static let optionKey: UInt32 = 0x3A  // Left Option/Alt
    public static let rightOptionKey: UInt32 = 0x3D  // Right Option/Alt
    public static let commandKey: UInt32 = 0x37  // Left Command
    public static let rightCommandKey: UInt32 = 0x36  // Right Command
    public static let shiftKey: UInt32 = 0x38  // Left Shift
    public static let controlKey: UInt32 = 0x3B  // Left Control
    public static let spaceKey: UInt32 = 0x31
    public static let dKey: UInt32 = 0x02
    public static let rKey: UInt32 = 0x0F
    
    // CGEvent modifier flags
    public static let cmdModifier: UInt32 = UInt32(CGEventFlags.maskCommand.rawValue)
    public static let optionModifier: UInt32 = UInt32(CGEventFlags.maskAlternate.rawValue)
    public static let controlModifier: UInt32 = UInt32(CGEventFlags.maskControl.rawValue)
    public static let shiftModifier: UInt32 = UInt32(CGEventFlags.maskShift.rawValue)
    
    // Default: Left Option key alone
    public static func `default`() -> HotkeyConfig {
        HotkeyConfig(
            keyCode: optionKey,
            modifiers: 0  // No modifiers for single key
        )
    }
}

// MARK: - Hotkey Callback

public typealias HotkeyCallback = @Sendable (HotkeyEventType) -> Void

// MARK: - Hotkey Manager

public class HotkeyManager: @unchecked Sendable {
    private var callback: HotkeyCallback?
    private var isPressed = false
    private var config: HotkeyConfig?
    
    // CGEventTap resources
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    // Serial queue for thread-safe access
    private let queue = DispatchQueue(label: "dev.vm.voiceclutch.hotkey", qos: .userInteractive)
    
    // Throttling to prevent callback flooding
    private var lastCallbackTime: Date = Date.distantPast
    private let minCallbackInterval: TimeInterval = 0.05  // 50ms minimum between callbacks
    private var eventCount = 0
    private var pendingPress = false
    private var pendingRelease = false
    
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
                    return Unmanaged.passRetained(event)
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
            self.eventCount = 0
            self.pendingPress = false
            self.pendingRelease = false
        }
    }
    
    // MARK: - Event Handling
    
    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let config = self.config else {
            return Unmanaged.passRetained(event)
        }

        // Ignore synthetic events emitted by TextInjector to avoid re-entrant
        // hotkey press/release transitions while streaming text updates.
        let sourceTag = event.getIntegerValueField(.eventSourceUserData)
        if sourceTag == TextInjector.syntheticEventTag {
            return Unmanaged.passRetained(event)
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        
        // Handle modifier-only hotkeys (when config.modifiers == 0 and keyCode is a modifier key)
        if config.modifiers == 0 && isModifierKey(config.keyCode) {
            return handleModifierKeyEvent(type: type, keyCode: keyCode, flags: flags, config: config, event: event)
        }
        
        // Handle regular key hotkeys
        if UInt32(keyCode) == config.keyCode {
            // Check if modifiers match
            let modifiersMatch = checkModifiers(flags, expected: config.modifiers)
            
            if modifiersMatch {
                if type == .keyDown && !isPressed {
                    isPressed = true
                    DispatchQueue.main.async { [weak self] in
                        self?.callback?(.pressed)
                    }
                } else if type == .keyUp && isPressed {
                    isPressed = false
                    DispatchQueue.main.async { [weak self] in
                        self?.callback?(.released)
                    }
                }
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    /// Handle modifier-only hotkeys (Option, Command, Control, Shift alone)
    /// Uses flagsChanged events but filters to only our specific keyCode to avoid interference from
    /// programmatic key events like Command+V from text injection
    private func handleModifierKeyEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags, config: HotkeyConfig, event: CGEvent) -> Unmanaged<CGEvent>? {
        eventCount += 1

        // Only process flagsChanged events for our specific key code
        // This filters out events from other keys (e.g., Command key from Command+V)
        guard type == .flagsChanged && Int64(config.keyCode) == keyCode else {
            return Unmanaged.passRetained(event)
        }

        // Check if our specific modifier is pressed
        let isOurModifierPressed = isSpecificModifierPressed(flags, keyCode: config.keyCode)

        if isOurModifierPressed && !isPressed {
            isPressed = true
            invokeCallback(.pressed)
        } else if !isOurModifierPressed && isPressed {
            isPressed = false
            invokeCallback(.released)
        }

        // Always pass the event through to avoid system issues
        return Unmanaged.passRetained(event)
    }
    
    /// Invoke callback with throttling to prevent stack overflow
    /// Direct callback - no more Bun FFI issues in pure Swift app!
    private func invokeCallback(_ eventType: HotkeyEventType) {
        // Direct callback to Swift handler - no polling needed
        callback?(eventType)
    }
    
    // MARK: - Helper Methods
    
    private func isModifierKey(_ keyCode: UInt32) -> Bool {
        return keyCode == HotkeyConfig.optionKey ||
               keyCode == HotkeyConfig.rightOptionKey ||
               keyCode == HotkeyConfig.commandKey ||
               keyCode == HotkeyConfig.rightCommandKey ||
               keyCode == HotkeyConfig.shiftKey ||
               keyCode == HotkeyConfig.controlKey
    }
    
    private func isSpecificModifierPressed(_ flags: CGEventFlags, keyCode: UInt32) -> Bool {
        switch keyCode {
        case HotkeyConfig.optionKey:
            // Check if left option is pressed (maskAlternate without maskLeftAlternate distinction)
            return flags.contains(.maskAlternate)
        case HotkeyConfig.rightOptionKey:
            return flags.contains(.maskAlternate)
        case HotkeyConfig.commandKey:
            return flags.contains(.maskCommand)
        case HotkeyConfig.rightCommandKey:
            return flags.contains(.maskCommand)
        case HotkeyConfig.shiftKey:
            return flags.contains(.maskShift)
        case HotkeyConfig.controlKey:
            return flags.contains(.maskControl)
        default:
            return false
        }
    }
    
    private func checkModifiers(_ flags: CGEventFlags, expected: UInt32) -> Bool {
        // For now, simple check - if we expect 0 modifiers, ensure no modifiers are pressed
        // If we expect specific modifiers, check for them
        if expected == 0 {
            return !flags.contains(.maskCommand) &&
                   !flags.contains(.maskAlternate) &&
                   !flags.contains(.maskControl) &&
                   !flags.contains(.maskShift)
        }
        // TODO: Implement proper modifier checking for combinations
        return true
    }
    
    // MARK: - State Queries
    
    public func isHotkeyPressed() -> Bool {
        return queue.sync { isPressed }
    }
}

// MARK: - String Extension

extension String {
    var fourCharCode: Int {
        let utf8 = self.utf8
        var result: Int = 0
        for (index, byte) in utf8.enumerated() {
            guard index < 4 else { break }
            result = result << 8 | Int(byte)
        }
        return result
    }
}
