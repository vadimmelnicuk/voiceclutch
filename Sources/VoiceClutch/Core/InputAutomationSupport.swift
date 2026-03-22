import AppKit
import CoreGraphics
import Foundation

struct ClipboardSnapshot {
    private let items: [Item]
    private let wasEmpty: Bool

    static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return ClipboardSnapshot(items: [], wasEmpty: true)
        }

        let capturedItems = pasteboardItems.compactMap(Item.init)
        return ClipboardSnapshot(items: capturedItems, wasEmpty: false)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !wasEmpty else {
            return
        }

        let restoredItems = items.map { $0.makePasteboardItem() }
        guard !restoredItems.isEmpty else {
            return
        }

        pasteboard.writeObjects(restoredItems)
    }

    struct Item {
        let entries: [Entry]

        init?(pasteboardItem: NSPasteboardItem) {
            let entries = pasteboardItem.types.compactMap { type -> Entry? in
                guard let data = pasteboardItem.data(forType: type) else { return nil }
                return Entry(type: type, data: data)
            }

            guard !entries.isEmpty else {
                return nil
            }

            self.entries = entries
        }

        func makePasteboardItem() -> NSPasteboardItem {
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
    }

    struct Entry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }
}

enum SyntheticInputEvent {
    nonisolated static let syntheticEventTag: Int64 = 0x56434C54 // "VCLT"

    static func postCommandShortcut(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let commandFlags = CGEventFlags.maskCommand

        if let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 55,
            keyDown: true
        ) {
            post(commandDown, flags: commandFlags)
        }

        if let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ) {
            post(keyDown, flags: commandFlags)
        }

        if let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) {
            post(keyUp, flags: commandFlags)
        }

        if let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 55,
            keyDown: false
        ) {
            post(commandUp, flags: commandFlags)
        }
    }

    static func postKeyStroke(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)

        if let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ) {
            post(keyDown, flags: [])
        }

        if let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) {
            post(keyUp, flags: [])
        }
    }

    private static func post(_ event: CGEvent, flags: CGEventFlags) {
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        event.post(tap: .cghidEventTap)
    }
}
