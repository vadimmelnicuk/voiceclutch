import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class CorrectionLearningMonitor {
    static let shared = CorrectionLearningMonitor()

    private enum FocusedDiffOutcome {
        case unavailable
        case noLearnable
        case learned(source: String, target: String)
    }

    private struct Session {
        let originalText: String
        var currentText: String
        let focusedElement: AXUIElement?
        var focusedTextAtStart: String?
        let startedAt: Date
        var hasMeaningfulEdit: Bool
        var hasConfirmedFocusedEdit: Bool
    }

    private let logger = AppLogger(category: "CorrectionLearning")
    // Allow ample time to start editing, then capture shortly after edits settle.
    private let preEditInactivityTimeout: TimeInterval = 30.0
    private let postEditInactivityTimeout: TimeInterval = 2.0
    private let baselineSnapshotDelay: TimeInterval = 0.25
    private let maximumCaptureWindow: TimeInterval = 30.0
    private var session: Session?
    private var timeoutTask: Task<Void, Never>?
    private var baselineSnapshotTask: Task<Void, Never>?
    private var focusedEditConfirmationTask: Task<Void, Never>?
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

        if session != nil {
            finishMonitoring()
        }

        let now = Date()
        let focusedElementAtStart = focusedElement()
        session = Session(
            originalText: insertedText,
            currentText: insertedText,
            focusedElement: focusedElementAtStart,
            focusedTextAtStart: focusedTextSnapshot(preferredElement: focusedElementAtStart),
            startedAt: now,
            hasMeaningfulEdit: false,
            hasConfirmedFocusedEdit: false
        )
        logger.debug("STARTED")
        scheduleBaselineSnapshotRefresh()
        scheduleTimeout()
    }

    func cancel() {
        baselineSnapshotTask?.cancel()
        baselineSnapshotTask = nil
        focusedEditConfirmationTask?.cancel()
        focusedEditConfirmationTask = nil
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
            handleCommandShortcut(event, in: &session)
            self.session = session
            scheduleTimeout()
            return
        }

        if modifierFlags.contains(.maskControl) {
            self.session = session
            scheduleTimeout()
            return
        }

        if isNavigationKey(event.keyCode) {
            self.session = session
            scheduleTimeout()
            return
        }

        switch event.keyCode {
        case UInt32(kVK_Delete):
            guard !session.currentText.isEmpty else { return }
            session.currentText.removeLast()
            markMeaningfulEdit(in: &session)
        case UInt32(kVK_ForwardDelete):
            // Forward delete mutates text at the cursor; we cannot model cursor-aware
            // edits here, so rely on focused-text diff capture at finalize time.
            markMeaningfulEdit(in: &session)
            return
        default:
            guard let characters = event.characters, !characters.isEmpty else { return }
            guard !characters.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else {
                return
            }

            session.currentText.append(characters)
            markMeaningfulEdit(in: &session)
        }

        self.session = session
        scheduleTimeout()
    }

    private func handleEvent(_ event: NSEvent) {
        let characters = event.characters ?? event.charactersIgnoringModifiers
        handleKeyEvent(
            ObservedKeyEvent(
                kind: .keyDown,
                keyCode: UInt32(event.keyCode),
                modifierFlagsRawValue: UInt64(event.modifierFlags.rawValue),
                characters: characters
            )
        )
    }

    private func handleCommandShortcut(
        _ event: ObservedKeyEvent,
        in session: inout Session
    ) {
        switch event.keyCode {
        case UInt32(kVK_ANSI_V):
            guard let pastedText = NSPasteboard.general.string(forType: .string), !pastedText.isEmpty else {
                return
            }
            session.currentText.append(pastedText)
            markMeaningfulEdit(in: &session)
        case UInt32(kVK_ANSI_X), UInt32(kVK_ANSI_Z):
            // Cut/undo can mutate text without direct character payload.
            markMeaningfulEdit(in: &session)
        default:
            break
        }
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        guard let session else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(session.startedAt)
        let remainingCaptureWindow = maximumCaptureWindow - elapsed
        if remainingCaptureWindow <= 0 {
            finishMonitoring()
            return
        }

        let inactivityTimeout = session.hasConfirmedFocusedEdit
            ? postEditInactivityTimeout
            : preEditInactivityTimeout
        let delay = min(inactivityTimeout, remainingCaptureWindow)

        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.finishMonitoring(allowContinuationOnNoLearnable: true)
            }
        }
    }

    private func scheduleBaselineSnapshotRefresh() {
        baselineSnapshotTask?.cancel()
        baselineSnapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(baselineSnapshotDelay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard var session = self.session else { return }
                // If a baseline was already captured and edits started, keep it.
                // If baseline is still missing, keep trying once after settle.
                guard !session.hasMeaningfulEdit || session.focusedTextAtStart == nil else { return }
                guard let refreshedBaseline = self.focusedTextSnapshot(
                    preferredElement: session.focusedElement
                ) else {
                    return
                }
                session.focusedTextAtStart = refreshedBaseline
                self.session = session
                self.logger.debug("Refreshed focused-text baseline after settle")
            }
        }
    }

    private func markMeaningfulEdit(in session: inout Session) {
        session.hasMeaningfulEdit = true

        if !session.hasConfirmedFocusedEdit,
           focusedTextHasChanged(from: session.focusedTextAtStart, preferredElement: session.focusedElement) {
            session.hasConfirmedFocusedEdit = true
        } else if !session.hasConfirmedFocusedEdit {
            scheduleFocusedEditConfirmationCheck()
        }
    }

    private func scheduleFocusedEditConfirmationCheck() {
        focusedEditConfirmationTask?.cancel()
        focusedEditConfirmationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard var session = self.session else { return }
                guard session.hasMeaningfulEdit, !session.hasConfirmedFocusedEdit else { return }
                guard self.focusedTextHasChanged(
                    from: session.focusedTextAtStart,
                    preferredElement: session.focusedElement
                ) else {
                    return
                }
                session.hasConfirmedFocusedEdit = true
                self.session = session
                self.scheduleTimeout()
            }
        }
    }

    private func finishMonitoring(allowContinuationOnNoLearnable: Bool = false) {
        baselineSnapshotTask?.cancel()
        baselineSnapshotTask = nil
        focusedEditConfirmationTask?.cancel()
        focusedEditConfirmationTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        guard var finishedSession = session else { return }

        let elapsed = Date().timeIntervalSince(finishedSession.startedAt)
        let canContinueCapture = allowContinuationOnNoLearnable && elapsed < maximumCaptureWindow

        guard finishedSession.hasMeaningfulEdit else {
            session = nil
            logger.debug("ENDED")
            return
        }
        guard finishedSession.currentText != finishedSession.originalText else {
            session = nil
            logger.debug("ENDED")
            return
        }
        guard AutoAddCorrectionsPreference.load() else {
            session = nil
            logger.debug("SKIPPED")
            return
        }
        let learnedCorrection: (source: String, target: String)?
        switch deriveCorrectionFromFocusedTextDiff(session: finishedSession) {
        case .learned(let source, let target):
            learnedCorrection = (source: source, target: target)
        case .noLearnable:
            if canContinueCapture {
                continueMonitoringAfterNoLearnableResult(from: &finishedSession)
                return
            }
            session = nil
            logger.debug("No learnable correction derived from focused-text diff")
            return
        case .unavailable:
            learnedCorrection = deriveCorrection(
                from: finishedSession.originalText,
                to: finishedSession.currentText
            )
        }

        guard let learnedCorrection else {
            if canContinueCapture {
                continueMonitoringAfterNoLearnableResult(from: &finishedSession)
                return
            }
            session = nil
            logger.debug("No learnable correction derived from captured edit")
            return
        }

        if isExistingLearnedReplacement(
            source: learnedCorrection.source,
            target: learnedCorrection.target
        ) {
            if canContinueCapture {
                continueMonitoringAfterNoLearnableResult(from: &finishedSession)
            } else {
                session = nil
            }
            logger.debug("IGNORED")
            return
        }

        session = nil
        logger.debug("CAPTURED '\(learnedCorrection.source)' -> '\(learnedCorrection.target)'")
        let learnedSource = learnedCorrection.source
        let learnedTarget = learnedCorrection.target
        let editedTranscript = finishedSession.currentText

        Task.detached(priority: .utility) {
            await VocabularySuggestionOrchestrator.shared.processUserEditSignal(
                source: learnedSource,
                target: learnedTarget,
                editedTranscript: editedTranscript
            )
        }
    }

    private func continueMonitoringAfterNoLearnableResult(from session: inout Session) {
        if let focusedTextAtEnd = focusedTextSnapshot(preferredElement: session.focusedElement) {
            session.focusedTextAtStart = focusedTextAtEnd
            session.currentText = focusedTextAtEnd
        }
        session.hasMeaningfulEdit = false
        session.hasConfirmedFocusedEdit = false
        self.session = session
        scheduleTimeout()
    }

    private func focusedTextHasChanged(
        from baseline: String?,
        preferredElement: AXUIElement?
    ) -> Bool {
        guard let baseline else { return false }
        guard let current = focusedTextSnapshot(preferredElement: preferredElement) else { return false }
        return current != baseline
    }

    private func isExistingLearnedReplacement(source: String, target: String) -> Bool {
        let normalizedSource = CustomVocabularyManager.normalizedLookupKey(source)
        let normalizedTarget = CustomVocabularyManager.normalizedLookupKey(target)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty else {
            return false
        }

        let snapshot = CustomVocabularyManager.shared.snapshot()
        return snapshot.learnedRules.contains { rule in
            rule.isPromoted &&
                CustomVocabularyManager.normalizedLookupKey(rule.source) == normalizedSource &&
                CustomVocabularyManager.normalizedLookupKey(rule.target) == normalizedTarget
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

        let expandedOriginalRange = expandedTokenRange(
            in: original,
            start: originalPrefixIndex,
            end: originalSuffixIndex
        )
        let expandedCurrentRange = expandedTokenRange(
            in: current,
            start: currentPrefixIndex,
            end: currentSuffixIndex
        )
        let sourceFragment = normalizeLearnedFragment(String(original[expandedOriginalRange]))
        let targetFragment = normalizeLearnedFragment(String(current[expandedCurrentRange]))
        guard let narrowedCorrection = singleWordCorrection(source: sourceFragment, target: targetFragment) else {
            return nil
        }

        let narrowedSource = normalizeLearnedFragment(narrowedCorrection.source)
        let narrowedTarget = normalizeLearnedFragment(narrowedCorrection.target)
        guard
            !narrowedSource.isEmpty,
            !narrowedTarget.isEmpty,
            CustomVocabularyManager.normalizedLookupKey(narrowedSource)
                != CustomVocabularyManager.normalizedLookupKey(narrowedTarget),
            containsSubstantiveContent(narrowedSource),
            containsSubstantiveContent(narrowedTarget),
            !isLikelyAppendOnlyExpansion(source: narrowedSource, target: narrowedTarget),
            !isLikelyDuplicationArtifact(source: narrowedSource, target: narrowedTarget)
        else {
            return nil
        }

        return (narrowedSource, narrowedTarget)
    }

    private func deriveCorrectionFromFocusedTextDiff(session: Session) -> FocusedDiffOutcome {
        guard let focusedTextAtStart = session.focusedTextAtStart else {
            logger.debug("Focused-text baseline snapshot unavailable")
            return .unavailable
        }
        guard let focusedTextAtEnd = focusedTextSnapshot(preferredElement: session.focusedElement) else {
            logger.debug("Focused-text end snapshot unavailable")
            return .unavailable
        }
        guard focusedTextAtEnd != focusedTextAtStart else {
            logger.debug("Focused-text snapshot unchanged")
            return .noLearnable
        }

        if let correction = deriveCorrection(from: focusedTextAtStart, to: focusedTextAtEnd) {
            return .learned(source: correction.source, target: correction.target)
        }
        return .noLearnable
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

    private func singleWordCorrection(source: String, target: String) -> (source: String, target: String)? {
        let sourceWords = source
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let targetWords = target
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !sourceWords.isEmpty, !targetWords.isEmpty else {
            return nil
        }

        if sourceWords.count == 1, targetWords.count == 1 {
            return (sourceWords[0], targetWords[0])
        }

        // Allow one-term whitespace merge/split, e.g. "voice clutch" <-> "voiceclutch".
        if isSingleTermWhitespaceVariant(source: source, target: target) {
            return (source, target)
        }

        if let mergeOrSplitCorrection = singleMergeSplitCorrection(
            sourceWords: sourceWords,
            targetWords: targetWords
        ) {
            return mergeOrSplitCorrection
        }

        guard sourceWords.count == targetWords.count else {
            return nil
        }

        var differingPairs: [(source: String, target: String)] = []
        for index in sourceWords.indices {
            let sourceWord = sourceWords[index]
            let targetWord = targetWords[index]
            if CustomVocabularyManager.normalizedLookupKey(sourceWord)
                != CustomVocabularyManager.normalizedLookupKey(targetWord) {
                differingPairs.append((source: sourceWord, target: targetWord))
            }
        }

        guard differingPairs.count == 1, let onlyPair = differingPairs.first else {
            return nil
        }
        return onlyPair
    }

    private func singleMergeSplitCorrection(
        sourceWords: [String],
        targetWords: [String]
    ) -> (source: String, target: String)? {
        func normalizedWordsEqual(_ lhs: String, _ rhs: String) -> Bool {
            CustomVocabularyManager.normalizedLookupKey(lhs) == CustomVocabularyManager.normalizedLookupKey(rhs)
        }

        func collapsed(_ text: String) -> String {
            CustomVocabularyManager.normalizedCollapsedKey(text)
        }

        if sourceWords.count == targetWords.count + 1 {
            var candidate: (source: String, target: String)?

            for mergeIndex in 0..<targetWords.count {
                let prefixMatches = zip(sourceWords.prefix(mergeIndex), targetWords.prefix(mergeIndex))
                    .allSatisfy { normalizedWordsEqual($0, $1) }
                guard prefixMatches else { continue }

                let mergedSource = sourceWords[mergeIndex] + sourceWords[mergeIndex + 1]
                guard collapsed(mergedSource) == collapsed(targetWords[mergeIndex]) else { continue }

                let sourceTail = sourceWords.suffix(from: mergeIndex + 2)
                let targetTail = targetWords.suffix(from: mergeIndex + 1)
                guard sourceTail.count == targetTail.count else { continue }
                let suffixMatches = zip(sourceTail, targetTail).allSatisfy { normalizedWordsEqual($0, $1) }
                guard suffixMatches else { continue }

                let correction = (
                    source: "\(sourceWords[mergeIndex]) \(sourceWords[mergeIndex + 1])",
                    target: targetWords[mergeIndex]
                )
                if candidate != nil {
                    return nil
                }
                candidate = correction
            }

            return candidate
        }

        if targetWords.count == sourceWords.count + 1 {
            var candidate: (source: String, target: String)?

            for splitIndex in 0..<sourceWords.count {
                let prefixMatches = zip(sourceWords.prefix(splitIndex), targetWords.prefix(splitIndex))
                    .allSatisfy { normalizedWordsEqual($0, $1) }
                guard prefixMatches else { continue }

                let mergedTarget = targetWords[splitIndex] + targetWords[splitIndex + 1]
                guard collapsed(sourceWords[splitIndex]) == collapsed(mergedTarget) else { continue }

                let sourceTail = sourceWords.suffix(from: splitIndex + 1)
                let targetTail = targetWords.suffix(from: splitIndex + 2)
                guard sourceTail.count == targetTail.count else { continue }
                let suffixMatches = zip(sourceTail, targetTail).allSatisfy { normalizedWordsEqual($0, $1) }
                guard suffixMatches else { continue }

                let correction = (
                    source: sourceWords[splitIndex],
                    target: "\(targetWords[splitIndex]) \(targetWords[splitIndex + 1])"
                )
                if candidate != nil {
                    return nil
                }
                candidate = correction
            }

            return candidate
        }

        return nil
    }

    private func isSingleTermWhitespaceVariant(source: String, target: String) -> Bool {
        let sourceCollapsed = CustomVocabularyManager.normalizedCollapsedKey(source)
        let targetCollapsed = CustomVocabularyManager.normalizedCollapsedKey(target)
        guard !sourceCollapsed.isEmpty, !targetCollapsed.isEmpty else {
            return false
        }
        guard sourceCollapsed == targetCollapsed else {
            return false
        }

        let sourceWords = source.split(whereSeparator: \.isWhitespace).count
        let targetWords = target.split(whereSeparator: \.isWhitespace).count
        return (sourceWords == 1 && targetWords > 1) || (targetWords == 1 && sourceWords > 1)
    }

    private func focusedTextSnapshot(preferredElement: AXUIElement? = nil) -> String? {
        if let preferredElement {
            for element in candidateElements(startingAt: preferredElement) {
                if let preferredText = snapshotText(from: element) {
                    return preferredText
                }
            }
        }

        guard let focusedElement = focusedElement() else {
            return nil
        }

        for element in candidateElements(startingAt: focusedElement) {
            if let text = snapshotText(from: element) {
                return text
            }
        }
        return nil
    }

    private func snapshotText(from element: AXUIElement) -> String? {
        if let value = stringAttributeValue(on: element, attribute: kAXValueAttribute as CFString) {
            return normalizedSnapshotText(value)
        }
        if let attributedValue = attributedStringAttributeValue(on: element, attribute: kAXValueAttribute as CFString) {
            return normalizedSnapshotText(attributedValue)
        }
        if let selectedText = stringAttributeValue(on: element, attribute: kAXSelectedTextAttribute as CFString),
           !selectedText.isEmpty {
            return normalizedSnapshotText(selectedText)
        }
        if let visibleRangeValue = visibleRangeStringValue(on: element) {
            return normalizedSnapshotText(visibleRangeValue)
        }

        guard let value = fullRangeStringValue(on: element) else { return nil }
        return normalizedSnapshotText(value)
    }

    private func candidateElements(startingAt element: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        var current: AXUIElement? = element
        var visited: Set<String> = []
        let maxDepth = 4

        for _ in 0..<maxDepth {
            guard let node = current else { break }
            let key = String(describing: node)
            guard visited.insert(key).inserted else { break }
            results.append(node)
            current = parentElement(of: node)
        }

        return results
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()

        var focusedElementValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedStatus == .success,
              let focusedElementValue,
              CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedElement: AXUIElement = focusedElementValue as! AXUIElement
        return focusedElement
    }

    private func stringAttributeValue(on element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private func attributedStringAttributeValue(on element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success, let value else {
            return nil
        }

        if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
            let attributed = value as! NSAttributedString
            return attributed.string
        }
        return nil
    }

    private func visibleRangeStringValue(on element: AXUIElement) -> String? {
        guard let visibleRange = rangeAttributeValue(on: element, attribute: kAXVisibleCharacterRangeAttribute as CFString),
              visibleRange.length > 0 else {
            return nil
        }
        return stringForRange(on: element, range: visibleRange)
    }

    private func rangeAttributeValue(on element: AXUIElement, attribute: CFString) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func stringForRange(on element: AXUIElement, range: CFRange) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var rangeStringValue: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rangeStringValue
        )
        guard status == .success,
              let rangeStringValue,
              CFGetTypeID(rangeStringValue) == CFStringGetTypeID() else {
            return nil
        }

        return rangeStringValue as? String
    }

    private func fullRangeStringValue(on element: AXUIElement) -> String? {
        var countValue: CFTypeRef?
        let countStatus = AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &countValue
        )
        guard countStatus == .success,
              let countValue,
              CFGetTypeID(countValue) == CFNumberGetTypeID() else {
            return nil
        }

        var characterCount: Int64 = 0
        let didReadCount = CFNumberGetValue(
            (countValue as! CFNumber),
            .sInt64Type,
            &characterCount
        )
        guard didReadCount, characterCount > 0 else {
            return nil
        }

        let maxSnapshotLength: Int64 = 50_000
        let range = CFRange(location: 0, length: Int(min(characterCount, maxSnapshotLength)))
        return stringForRange(on: element, range: range)
    }

    private func normalizedSnapshotText(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty, normalized.count <= 50_000 else {
            return nil
        }
        return normalized
    }

    private func containsSubstantiveContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private func isLikelyAppendOnlyExpansion(source: String, target: String) -> Bool {
        let normalizedSource = CustomVocabularyManager.normalizedLookupKey(source)
        let normalizedTarget = CustomVocabularyManager.normalizedLookupKey(target)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty else {
            return false
        }

        guard normalizedTarget.count > normalizedSource.count else {
            return false
        }

        guard normalizedTarget.hasPrefix(normalizedSource) else {
            return false
        }

        let suffixIndex = normalizedTarget.index(normalizedTarget.startIndex, offsetBy: normalizedSource.count)
        let suffix = normalizedTarget[suffixIndex...]
        guard !suffix.isEmpty else { return false }

        let sourceWordCount = normalizedSource.split(whereSeparator: \.isWhitespace).count
        let targetWordCount = normalizedTarget.split(whereSeparator: \.isWhitespace).count
        return targetWordCount > sourceWordCount
    }

    private func isLikelyDuplicationArtifact(source: String, target: String) -> Bool {
        let sourceCollapsed = CustomVocabularyManager.normalizedCollapsedKey(source)
        let targetCollapsed = CustomVocabularyManager.normalizedCollapsedKey(target)
        guard !sourceCollapsed.isEmpty, !targetCollapsed.isEmpty else {
            return false
        }

        if targetCollapsed == sourceCollapsed + sourceCollapsed {
            return true
        }
        if sourceCollapsed == targetCollapsed + targetCollapsed {
            return true
        }

        if targetCollapsed.count >= sourceCollapsed.count * 2,
           targetCollapsed.replacingOccurrences(of: sourceCollapsed, with: "").isEmpty {
            return true
        }

        return false
    }

    private func expandedTokenRange(
        in text: String,
        start: String.Index,
        end: String.Index
    ) -> Range<String.Index> {
        var lowerBound = start
        var upperBound = end

        while lowerBound > text.startIndex {
            let previousIndex = text.index(before: lowerBound)
            guard isTokenCharacter(text[previousIndex]) else {
                break
            }
            lowerBound = previousIndex
        }

        while upperBound < text.endIndex {
            guard isTokenCharacter(text[upperBound]) else {
                break
            }
            upperBound = text.index(after: upperBound)
        }

        return lowerBound..<upperBound
    }

    private func isTokenCharacter(_ character: Character) -> Bool {
        if character == "'" || character == "’" || character == "-" {
            return true
        }
        return character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
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
