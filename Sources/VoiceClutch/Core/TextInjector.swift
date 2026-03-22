import AppKit
import Foundation

/// Injects text into the active application via clipboard + Cmd+V.
@MainActor
public class TextInjector {
    private static let clipboardRecoveryDelay: TimeInterval = 0.3
    private static let stateLock = NSLock()
    private static let rewriteDisplayInterval: TimeInterval = 0.35
    private static let duplicatePeriodWithSpacingRegex = try! NSRegularExpression(pattern: "\\.(?:\\s*\\.)+")
    private static let repeatedPeriodRegex = try! NSRegularExpression(pattern: "\\.{2,}")
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let trailingPunctuationClosers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
    private static let questionStarterWords: Set<String> = [
        "who", "what", "when", "where", "why", "how",
        "is", "are", "am", "was", "were",
        "do", "does", "did",
        "can", "could", "should", "would", "will",
        "have", "has", "had",
        "may", "might", "shall",
    ]
    nonisolated static let syntheticEventTag: Int64 = 0x56434C54 // "VCLT"

    private struct StreamingSessionState {
        var isActive: Bool = false
        var shouldRecoverClipboard: Bool = false
        var originalClipboard: ClipboardSnapshot?
        var lastInjectedText: String = ""
        var lastInjectedChangeCount: Int?
        var lastRewriteDisplayTime: TimeInterval = 0
    }

    private static var streamingState = StreamingSessionState()

    private struct ClipboardSnapshot {
        let items: [Item]

        static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot? {
            guard
                let pasteboardItems = pasteboard.pasteboardItems,
                !pasteboardItems.isEmpty
            else {
                return nil
            }

            let items = pasteboardItems.compactMap(Item.init)
            guard !items.isEmpty else { return nil }

            return ClipboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) {
            let restoredItems = items.map { $0.makePasteboardItem() }
            guard !restoredItems.isEmpty else { return }

            pasteboard.clearContents()
            pasteboard.writeObjects(restoredItems)
        }

        struct Item {
            let entries: [Entry]

            init?(pasteboardItem: NSPasteboardItem) {
                let entries = pasteboardItem.types.compactMap { type -> Entry? in
                    guard let data = pasteboardItem.data(forType: type) else { return nil }
                    return Entry(type: type, data: data)
                }

                guard !entries.isEmpty else { return nil }
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

    // MARK: - One-shot injection (legacy)

    /// Inject text by copying to clipboard and simulating Cmd+V.
    /// - Parameter text: The text string to inject.
    public static func inject(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let shouldRecoverClipboard = ClipboardRecoveryPreference.load()

        // Save current clipboard content only when restoration is enabled.
        let originalClipboard = shouldRecoverClipboard ? ClipboardSnapshot.capture(from: pasteboard) : nil

        // Copy text to clipboard with trailing space for natural typing.
        guard let injectedChangeCount = writeToPasteboard(text + " ") else {
            return
        }

        simulatePaste()

        guard shouldRecoverClipboard else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRecoveryDelay) {
            guard
                let originalClipboard,
                pasteboard.changeCount == injectedChangeCount
            else {
                return
            }

            originalClipboard.restore(to: pasteboard)
        }
    }

    // MARK: - Streaming injection

    public static func beginStreamingSession() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !streamingState.isActive else { return }

        let pasteboard = NSPasteboard.general
        let shouldRecoverClipboard = ClipboardRecoveryPreference.load()

        streamingState.isActive = true
        streamingState.shouldRecoverClipboard = shouldRecoverClipboard
        streamingState.originalClipboard = shouldRecoverClipboard ? ClipboardSnapshot.capture(from: pasteboard) : nil
        streamingState.lastInjectedText = ""
        streamingState.lastInjectedChangeCount = nil
        streamingState.lastRewriteDisplayTime = 0
    }

    public static func updateStreamingPartial(_ text: String) {
        guard !text.isEmpty else { return }

        let previousInjectedText: String
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        if !streamingState.isActive {
            stateLock.unlock()
            beginStreamingSession()
            stateLock.lock()
        }

        guard streamingState.lastInjectedText != text else {
            stateLock.unlock()
            return
        }

        previousInjectedText = streamingState.lastInjectedText
        let lastRewriteDisplayTime = streamingState.lastRewriteDisplayTime
        stateLock.unlock()

        if previousInjectedText.isEmpty {
            guard let changeCount = writeToPasteboard(text) else { return }
            simulatePaste()
            stateLock.lock()
            if streamingState.isActive {
                streamingState.lastInjectedText = text
                streamingState.lastInjectedChangeCount = changeCount
            }
            stateLock.unlock()
            return
        }

        if text.hasPrefix(previousInjectedText) {
            let suffix = String(text.dropFirst(previousInjectedText.count))
            guard !suffix.isEmpty else { return }
            guard let changeCount = writeToPasteboard(suffix) else { return }
            simulatePaste()

            stateLock.lock()
            if streamingState.isActive {
                streamingState.lastInjectedText = text
                streamingState.lastInjectedChangeCount = changeCount
            }
            stateLock.unlock()
            return
        }

        if previousInjectedText.hasPrefix(text) {
            return
        }

        guard now - lastRewriteDisplayTime >= rewriteDisplayInterval else {
            return
        }

        guard let changeCount = writeToPasteboard(text) else { return }
        deleteRecentlyInsertedText(characterCount: previousInjectedText.count)
        simulatePaste()

        stateLock.lock()
        if streamingState.isActive {
            streamingState.lastInjectedText = text
            streamingState.lastInjectedChangeCount = changeCount
            streamingState.lastRewriteDisplayTime = now
        }
        stateLock.unlock()
    }

    public static func commitStreamingFinal(_ text: String) {
        let normalizedFinalText = normalizedStreamingFinalText(text)
        let session = takeAndResetStreamingSessionIfActive()

        guard let session else {
            if !normalizedFinalText.isEmpty {
                inject(normalizedFinalText.trimmingCharacters(in: .whitespaces))
            }
            return
        }

        let expectedChangeCount: Int?
        if normalizedFinalText.isEmpty {
            if !session.lastInjectedText.isEmpty {
                deleteRecentlyInsertedText(characterCount: session.lastInjectedText.count)
            }
            expectedChangeCount = session.lastInjectedChangeCount
        } else if normalizedFinalText == session.lastInjectedText {
            expectedChangeCount = session.lastInjectedChangeCount
        } else if normalizedFinalText.hasPrefix(session.lastInjectedText) {
            let suffix = String(normalizedFinalText.dropFirst(session.lastInjectedText.count))
            guard let changeCount = writeToPasteboard(suffix) else {
                restoreClipboardIfNeeded(
                    originalClipboard: session.originalClipboard,
                    shouldRecoverClipboard: session.shouldRecoverClipboard,
                    expectedChangeCount: session.lastInjectedChangeCount
                )
                return
            }
            simulatePaste()
            expectedChangeCount = changeCount
        } else {
            guard let changeCount = writeToPasteboard(normalizedFinalText) else {
                restoreClipboardIfNeeded(
                    originalClipboard: session.originalClipboard,
                    shouldRecoverClipboard: session.shouldRecoverClipboard,
                    expectedChangeCount: session.lastInjectedChangeCount
                )
                return
            }

            if !session.lastInjectedText.isEmpty {
                deleteRecentlyInsertedText(characterCount: session.lastInjectedText.count)
            }
            simulatePaste()
            expectedChangeCount = changeCount
        }

        restoreClipboardIfNeeded(
            originalClipboard: session.originalClipboard,
            shouldRecoverClipboard: session.shouldRecoverClipboard,
            expectedChangeCount: expectedChangeCount
        )
    }

    private static func normalizedStreamingFinalText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let cleaned = collapsedDuplicatePeriods(in: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, containsSubstantiveContent(cleaned) else { return "" }

        if hasTerminalPunctuation(cleaned) {
            return "\(cleaned) "
        }

        let terminal = shouldEndAsQuestion(cleaned) ? "?" : "."
        return "\(cleaned)\(terminal) "
    }

    private static func collapsedDuplicatePeriods(in text: String) -> String {
        guard text.contains(".") else { return text }

        var normalized = text

        let firstPassRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        normalized = duplicatePeriodWithSpacingRegex.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: firstPassRange,
            withTemplate: "."
        )

        let secondPassRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        normalized = repeatedPeriodRegex.stringByReplacingMatches(
            in: normalized,
            options: [],
            range: secondPassRange,
            withTemplate: "."
        )

        return normalized
    }

    private static func containsSubstantiveContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        var probe = text[...]
        while let last = probe.last {
            if last.isWhitespace || trailingPunctuationClosers.contains(last) {
                probe = probe.dropLast()
                continue
            }

            return sentenceTerminators.contains(last)
        }

        return false
    }

    private static func shouldEndAsQuestion(_ text: String) -> Bool {
        guard let firstWord = text.split(whereSeparator: \.isWhitespace).first else { return false }
        return questionStarterWords.contains(String(firstWord).lowercased())
    }

    public static func cancelStreamingSession() {
        let session = takeAndResetStreamingSessionIfActive()

        guard let session else { return }

        restoreClipboardIfNeeded(
            originalClipboard: session.originalClipboard,
            shouldRecoverClipboard: session.shouldRecoverClipboard,
            expectedChangeCount: session.lastInjectedChangeCount
        )
    }

    private static func takeAndResetStreamingSessionIfActive() -> StreamingSessionState? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard streamingState.isActive else { return nil }

        let session = streamingState
        streamingState = StreamingSessionState()
        return session
    }

    // MARK: - Clipboard Helpers

    @discardableResult
    private static func writeToPasteboard(_ text: String) -> Int? {
        let pasteboard = NSPasteboard.general
        let maximumAttempts = 3

        for attempt in 1...maximumAttempts {
            pasteboard.clearContents()
            let didSet = pasteboard.setString(text, forType: .string)
            let confirmedText = pasteboard.string(forType: .string)

            if didSet, confirmedText == text {
                return pasteboard.changeCount
            }

            if attempt < maximumAttempts {
                Thread.sleep(forTimeInterval: 0.004)
            }
        }

        return nil
    }

    private static func restoreClipboardIfNeeded(
        originalClipboard: ClipboardSnapshot?,
        shouldRecoverClipboard: Bool,
        expectedChangeCount: Int?
    ) {
        guard shouldRecoverClipboard else { return }

        let pasteboard = NSPasteboard.general

        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRecoveryDelay) {
            guard let originalClipboard else { return }
            guard !isStreamingSessionActive() else { return }

            if let expectedChangeCount,
               pasteboard.changeCount != expectedChangeCount {
                return
            }

            originalClipboard.restore(to: pasteboard)
        }
    }

    private static func isStreamingSessionActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamingState.isActive
    }

    // MARK: - Keyboard Simulation

    /// Simulate Cmd+V keyboard shortcut.
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdFlag = CGEventFlags.maskCommand.rawValue

        // Cmd key down
        if let cmdDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 55, // kVK_Command
            keyDown: true
        ) {
            postSyntheticEvent(cmdDown, flags: CGEventFlags(rawValue: cmdFlag))
        }

        // V key down (with Cmd modifier)
        if let vDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9, // kVK_ANSI_V
            keyDown: true
        ) {
            postSyntheticEvent(vDown, flags: CGEventFlags(rawValue: cmdFlag))
        }

        // V key up
        if let vUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        ) {
            postSyntheticEvent(vUp, flags: CGEventFlags(rawValue: cmdFlag))
        }

        // Cmd key up
        if let cmdUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 55,
            keyDown: false
        ) {
            postSyntheticEvent(cmdUp, flags: CGEventFlags(rawValue: cmdFlag))
        }
    }

    /// Deletes the previously inserted partial by issuing Backspace events.
    private static func deleteRecentlyInsertedText(characterCount: Int) {
        guard characterCount > 0 else { return }

        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKeyCode: CGKeyCode = 51 // kVK_Delete

        for _ in 0..<characterCount {
            if let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: deleteKeyCode,
                keyDown: true
            ) {
                postSyntheticEvent(keyDown, flags: [])
            }

            if let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: deleteKeyCode,
                keyDown: false
            ) {
                postSyntheticEvent(keyUp, flags: [])
            }
        }
    }

    private static func postSyntheticEvent(_ event: CGEvent, flags: CGEventFlags) {
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        event.post(tap: .cghidEventTap)
    }
}
