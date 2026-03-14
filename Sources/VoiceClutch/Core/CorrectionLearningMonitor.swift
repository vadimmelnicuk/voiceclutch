import AppKit
import Carbon
import Foundation

@MainActor
final class CorrectionLearningMonitor {
    static let shared = CorrectionLearningMonitor()

    private struct Session {
        let originalText: String
        var currentText: String
        let startedAt: Date
        var lastActivityAt: Date
        var hasMeaningfulEdit: Bool
    }

    private let logger = AppLogger(category: "CorrectionLearning")
    private let inactivityTimeout: TimeInterval = 2.5
    private let maximumCaptureWindow: TimeInterval = 8.0
    private var session: Session?
    private var timeoutTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private init() {}

    func installEventMonitors() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
            return event
        }
    }

    func uninstallEventMonitors() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    func beginMonitoring(insertedText: String) {
        let trimmedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            cancel()
            return
        }

        let now = Date()
        session = Session(
            originalText: insertedText,
            currentText: insertedText,
            startedAt: now,
            lastActivityAt: now,
            hasMeaningfulEdit: false
        )
        scheduleTimeout()
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        session = nil
    }

    func handleKeyEvent(_ event: ObservedKeyEvent) {
        guard var session else { return }
        guard event.kind == .keyDown else { return }

        let now = Date()
        if now.timeIntervalSince(session.startedAt) > maximumCaptureWindow {
            finishMonitoring()
            return
        }

        let modifierFlags = CGEventFlags(rawValue: event.modifierFlagsRawValue)
        if modifierFlags.contains(.maskCommand) {
            guard handleCommandShortcut(event, in: &session, at: now) else {
                abortMonitoring()
                return
            }
            self.session = session
            scheduleTimeout()
            return
        }

        if modifierFlags.contains(.maskControl) {
            abortMonitoring()
            return
        }

        if isNavigationKey(event.keyCode) {
            abortMonitoring()
            return
        }

        switch event.keyCode {
        case UInt32(kVK_Delete):
            guard !session.currentText.isEmpty else { return }
            session.currentText.removeLast()
            session.lastActivityAt = now
            session.hasMeaningfulEdit = true
        case UInt32(kVK_ForwardDelete):
            abortMonitoring()
            return
        default:
            guard let characters = event.characters, !characters.isEmpty else { return }
            guard !characters.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else {
                return
            }

            session.currentText.append(characters)
            session.lastActivityAt = now
            session.hasMeaningfulEdit = true
        }

        self.session = session
        scheduleTimeout()
    }

    private func handleEvent(_ event: NSEvent) {
        handleKeyEvent(
            ObservedKeyEvent(
                kind: .keyDown,
                keyCode: UInt32(event.keyCode),
                modifierFlagsRawValue: UInt64(event.modifierFlags.rawValue),
                characters: event.characters
            )
        )
    }

    private func handleCommandShortcut(
        _ event: ObservedKeyEvent,
        in session: inout Session,
        at date: Date
    ) -> Bool {
        switch event.keyCode {
        case UInt32(kVK_ANSI_V):
            guard let pastedText = NSPasteboard.general.string(forType: .string), !pastedText.isEmpty else {
                return false
            }
            session.currentText.append(pastedText)
            session.lastActivityAt = date
            session.hasMeaningfulEdit = true
            return true
        default:
            return false
        }
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.inactivityTimeout * 1_000_000_000))
            await MainActor.run {
                self.finishMonitoring()
            }
        }
    }

    private func abortMonitoring() {
        logger.debug("Aborted correction capture because the edit pattern became ambiguous")
        cancel()
    }

    private func finishMonitoring() {
        timeoutTask?.cancel()
        timeoutTask = nil

        guard let finishedSession = session else { return }
        session = nil

        guard finishedSession.hasMeaningfulEdit else { return }
        guard finishedSession.currentText != finishedSession.originalText else { return }
        guard AutoAddCorrectionsPreference.load() else { return }
        guard let learnedCorrection = deriveCorrection(
            from: finishedSession.originalText,
            to: finishedSession.currentText
        ) else {
            return
        }

        do {
            _ = try CustomVocabularyManager.shared.recordLearnedRule(
                from: learnedCorrection.source,
                to: learnedCorrection.target
            )
        } catch {
            logger.warning("Failed to persist learned correction: \(error.localizedDescription)")
        }
    }

    private func deriveCorrection(from original: String, to current: String) -> (source: String, target: String)? {
        guard original != current else { return nil }

        var originalPrefixIndex = original.startIndex
        var currentPrefixIndex = current.startIndex
        while originalPrefixIndex < original.endIndex,
              currentPrefixIndex < current.endIndex,
              original[originalPrefixIndex] == current[currentPrefixIndex] {
            originalPrefixIndex = original.index(after: originalPrefixIndex)
            currentPrefixIndex = current.index(after: currentPrefixIndex)
        }

        var originalSuffixIndex = original.endIndex
        var currentSuffixIndex = current.endIndex
        while originalSuffixIndex > originalPrefixIndex,
              currentSuffixIndex > currentPrefixIndex {
            let originalCandidate = original.index(before: originalSuffixIndex)
            let currentCandidate = current.index(before: currentSuffixIndex)
            guard original[originalCandidate] == current[currentCandidate] else { break }
            originalSuffixIndex = originalCandidate
            currentSuffixIndex = currentCandidate
        }

        let sourceFragment = normalizeLearnedFragment(String(original[originalPrefixIndex..<originalSuffixIndex]))
        let targetFragment = normalizeLearnedFragment(String(current[currentPrefixIndex..<currentSuffixIndex]))
        guard
            !sourceFragment.isEmpty,
            !targetFragment.isEmpty,
            CustomVocabularyManager.normalizedLookupKey(sourceFragment)
                != CustomVocabularyManager.normalizedLookupKey(targetFragment),
            containsSubstantiveContent(sourceFragment),
            containsSubstantiveContent(targetFragment)
        else {
            return nil
        }

        return (sourceFragment, targetFragment)
    }

    private func normalizeLearnedFragment(_ fragment: String) -> String {
        let whitespaceCollapsed = fragment
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")

        let trimmableCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ".,!?;:\"“”‘’()[]{}")
        )
        return whitespaceCollapsed.trimmingCharacters(in: trimmableCharacters)
    }

    private func containsSubstantiveContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private func isNavigationKey(_ keyCode: UInt32) -> Bool {
        switch keyCode {
        case UInt32(kVK_LeftArrow),
            UInt32(kVK_RightArrow),
            UInt32(kVK_UpArrow),
            UInt32(kVK_DownArrow),
            UInt32(kVK_Home),
            UInt32(kVK_End),
            UInt32(kVK_PageUp),
            UInt32(kVK_PageDown),
            UInt32(kVK_Tab):
            return true
        default:
            return false
        }
    }
}
