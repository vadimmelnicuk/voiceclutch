import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class CorrectionLearningMonitor {
    static let shared = CorrectionLearningMonitor()

    private enum CorrectionCaptureStrategy {
        case focusedTextDiff
        case editTracker
    }

    private enum FocusedDiffOutcome {
        case unavailable
        case noLearnable
        case learned(source: String, target: String)
    }

    private struct Session {
        let originalText: String
        var editTracker: CursorAwareEditTracker
        let focusedElement: CorrectionLearningAccessibilityElement?
        var snapshotElement: CorrectionLearningAccessibilityElement?
        let manualAccessibilitySession: CorrectionLearningAccessibilityBridge.ManualAccessibilitySession?
        var focusedTextAtStart: String?
        var insertionStartInField: Int?
        var isAwaitingMouseRecovery: Bool
        var startedAt: Date
        var hasMeaningfulEdit: Bool
    }

    private let logger = AppLogger(category: "CorrectionLearning")
    private let accessibilityBridge: CorrectionLearningAccessibilityBridge
    // Allow ample time to start editing, then capture shortly after edits settle.
    private let preEditInactivityTimeout: TimeInterval = 30.0
    private let postEditInactivityTimeout: TimeInterval = 2.0
    private let baselineSnapshotDelay: TimeInterval = 0.25
    private let baselineSnapshotSearchWindow: TimeInterval = 3.0
    private let mouseRecoveryPollDelay: TimeInterval = 0.08
    private let mouseRecoveryPollWindow: TimeInterval = 1.0
    private let maximumCaptureWindow: TimeInterval = 30.0
    private var session: Session?
    private var timeoutTask: Task<Void, Never>?
    private var baselineSnapshotTask: Task<Void, Never>?
    private var mouseRecoveryTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var preparedManualAccessibilitySession: CorrectionLearningAccessibilityBridge.ManualAccessibilitySession?

    init(
        accessibilityBridge: CorrectionLearningAccessibilityBridge = CorrectionLearningAccessibilityBridge()
    ) {
        self.accessibilityBridge = accessibilityBridge
    }

    func installEventMonitors() {
        guard
            globalKeyMonitor == nil,
            localKeyMonitor == nil,
            globalMouseMonitor == nil,
            localMouseMonitor == nil
        else { return }

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

        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseActivity()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseActivity()
            }
            return event
        }
    }

    func prepareForUpcomingCapture() {
        guard session == nil, preparedManualAccessibilitySession == nil else { return }
        preparedManualAccessibilitySession = accessibilityBridge.prepareFocusedApplicationAccessibility()
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
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
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
        let manualAccessibilitySession = preparedManualAccessibilitySession ?? accessibilityBridge.prepareFocusedApplicationAccessibility()
        preparedManualAccessibilitySession = nil
        let focusedElementAtStart = accessibilityBridge.focusedElement()
        let baselineSelection = accessibilityBridge.focusedTextSelection(
            preferredElement: focusedElementAtStart,
            anchorText: insertedText,
            reusePreferredElementSnapshot: false
        )
        let acceptedBaselineSelection: (text: String, element: CorrectionLearningAccessibilityElement)?
        if let baselineSelection,
           isPlausibleFocusedTextBaseline(baselineSelection.text, for: insertedText) {
            acceptedBaselineSelection = baselineSelection
        } else {
            acceptedBaselineSelection = nil
        }
        let focusedTextAtStart = acceptedBaselineSelection?.text
        let insertionStartInField = accessibilityBridge.inferredInsertionStartInFocusedField(
            insertedText: insertedText,
            focusedTextAtStart: focusedTextAtStart,
            preferredElement: focusedElementAtStart
        )
        session = Session(
            originalText: insertedText,
            editTracker: CursorAwareEditTracker(initialText: insertedText),
            focusedElement: focusedElementAtStart,
            snapshotElement: acceptedBaselineSelection?.element,
            manualAccessibilitySession: manualAccessibilitySession,
            focusedTextAtStart: focusedTextAtStart,
            insertionStartInField: insertionStartInField,
            isAwaitingMouseRecovery: false,
            startedAt: now,
            hasMeaningfulEdit: false
        )
        scheduleBaselineSnapshotRefresh()
        scheduleTimeout()
    }

    func cancel() {
        baselineSnapshotTask?.cancel()
        baselineSnapshotTask = nil
        mouseRecoveryTask?.cancel()
        mouseRecoveryTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        accessibilityBridge.restoreManualAccessibilityIfNeeded(session?.manualAccessibilitySession)
        accessibilityBridge.restoreManualAccessibilityIfNeeded(preparedManualAccessibilitySession)
        preparedManualAccessibilitySession = nil
        session = nil
    }

    func handleKeyEvent(_ event: ObservedKeyEvent) {
        guard !Self.shouldIgnoreEventForLearning(eventSourceUserData: event.eventSourceUserData) else {
            return
        }
        guard var session else { return }
        guard event.kind == .keyDown else { return }

        let now = Date()
        if now.timeIntervalSince(session.startedAt) > maximumCaptureWindow {
            finishMonitoring()
            return
        }

        resolveMouseRecoveryIfNeeded(in: &session)

        let didApplyMeaningfulEdit = session.editTracker.applyKeyEvent(event) {
            NSPasteboard.general.string(forType: .string)
        }
        if didApplyMeaningfulEdit {
            session.hasMeaningfulEdit = true
        }

        self.session = session
        scheduleTimeout()
    }

    private func handleEvent(_ event: NSEvent) {
        let characters = event.characters ?? event.charactersIgnoringModifiers
        let eventSourceUserData = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        handleKeyEvent(
            ObservedKeyEvent(
                kind: .keyDown,
                keyCode: UInt32(event.keyCode),
                modifierFlagsRawValue: UInt64(event.modifierFlags.rawValue),
                characters: characters,
                eventSourceUserData: eventSourceUserData
            )
        )
    }

    private func handleMouseActivity() {
        guard var session else { return }
        session.isAwaitingMouseRecovery = true
        self.session = session
        if attemptMouseRecoveryIfPossible() {
            scheduleTimeout()
            return
        }
        scheduleMouseRecoveryPolling()
        scheduleTimeout()
    }

    @discardableResult
    private func attemptMouseRecoveryIfPossible() -> Bool {
        guard var session else { return false }
        guard session.isAwaitingMouseRecovery else { return false }

        guard let recoveredSelectionState = accessibilityBridge.recoverSelectionState(
            modeledText: session.editTracker.modeledText,
            insertionStartInField: session.insertionStartInField,
            preferredElement: session.snapshotElement ?? session.focusedElement
        ) else {
            return false
        }

        session.editTracker.noteMouseInteraction(
            recoveredCaretOffsetFromEnd: recoveredSelectionState.caretOffsetFromEnd,
            recoveredSelectionLength: recoveredSelectionState.selectedRangeLength
        )
        session.isAwaitingMouseRecovery = false
        self.session = session
        mouseRecoveryTask?.cancel()
        mouseRecoveryTask = nil
        return true
    }

    private func resolveMouseRecoveryIfNeeded(in session: inout Session) {
        guard session.isAwaitingMouseRecovery else { return }
        session.isAwaitingMouseRecovery = false
        mouseRecoveryTask?.cancel()
        mouseRecoveryTask = nil

        let recoveredSelectionState = accessibilityBridge.recoverSelectionState(
            modeledText: session.editTracker.modeledText,
            insertionStartInField: session.insertionStartInField,
            preferredElement: session.snapshotElement ?? session.focusedElement
        )
        session.editTracker.noteMouseInteraction(
            recoveredCaretOffsetFromEnd: recoveredSelectionState?.caretOffsetFromEnd,
            recoveredSelectionLength: recoveredSelectionState?.selectedRangeLength ?? 0
        )
    }

    private func scheduleMouseRecoveryPolling() {
        mouseRecoveryTask?.cancel()
        guard session?.isAwaitingMouseRecovery == true else { return }

        mouseRecoveryTask = Task { [weak self] in
            guard let self else { return }
            let searchDeadline = Date().addingTimeInterval(self.mouseRecoveryPollWindow)

            while !Task.isCancelled, Date() < searchDeadline {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.mouseRecoveryPollDelay * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                let recovered = await MainActor.run { () -> Bool in
                    self.attemptMouseRecoveryIfPossible()
                }

                if recovered {
                    return
                }
            }
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

        let inactivityTimeout = session.hasMeaningfulEdit
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
            let searchDeadline = Date().addingTimeInterval(self.baselineSnapshotSearchWindow)

            while !Task.isCancelled, Date() < searchDeadline {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.baselineSnapshotDelay * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                let capturedBaseline = await MainActor.run { () -> Bool in
                    guard var session = self.session else { return true }
                    guard !session.hasMeaningfulEdit else { return true }
                    guard !self.isPlausibleFocusedTextBaseline(
                        session.focusedTextAtStart,
                        for: session.originalText
                    ) else {
                        return true
                    }

                    let preferredElement = self.accessibilityBridge.focusedElement() ?? session.focusedElement
                    guard let preferredElement,
                          let refreshedSelection = self.accessibilityBridge.focusedTextSelection(
                            preferredElement: preferredElement,
                            anchorText: session.originalText,
                            reusePreferredElementSnapshot: false
                          ),
                          self.isPlausibleFocusedTextBaseline(
                            refreshedSelection.text,
                            for: session.originalText
                          ) else {
                        return false
                    }

                    let refreshedBaseline = refreshedSelection.text
                    session.focusedTextAtStart = refreshedBaseline
                    session.snapshotElement = refreshedSelection.element
                    if session.insertionStartInField == nil {
                        session.insertionStartInField = self.accessibilityBridge.inferredInsertionStartInFocusedField(
                            insertedText: session.editTracker.modeledText,
                            focusedTextAtStart: refreshedBaseline,
                            preferredElement: preferredElement
                        )
                    }
                    self.session = session
                    return true
                }

                if capturedBaseline {
                    return
                }
            }
        }
    }

    private func finishMonitoring(allowContinuationOnNoLearnable: Bool = false) {
        baselineSnapshotTask?.cancel()
        baselineSnapshotTask = nil
        mouseRecoveryTask?.cancel()
        mouseRecoveryTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        guard var finishedSession = session else { return }

        let elapsed = Date().timeIntervalSince(finishedSession.startedAt)
        let canContinueCapture = allowContinuationOnNoLearnable && elapsed < maximumCaptureWindow

        guard finishedSession.hasMeaningfulEdit else {
            accessibilityBridge.restoreManualAccessibilityIfNeeded(finishedSession.manualAccessibilitySession)
            session = nil
            return
        }
        guard AutoAddCorrectionsPreference.load() else {
            accessibilityBridge.restoreManualAccessibilityIfNeeded(finishedSession.manualAccessibilitySession)
            session = nil
            return
        }

        let focusedCandidate: (source: String, target: String)?
        switch deriveCorrectionFromFocusedTextDiff(session: finishedSession) {
        case .learned(let source, let target):
            focusedCandidate = (source: source, target: target)
        case .noLearnable, .unavailable:
            focusedCandidate = nil
        }

        let trackerCandidate: (source: String, target: String)?
        if let correction = deriveCorrection(
            from: finishedSession.originalText,
            to: finishedSession.editTracker.modeledText
        ) {
            trackerCandidate = (source: correction.source, target: correction.target)
        } else {
            trackerCandidate = nil
        }
        let selectedCorrection: (
            strategy: CorrectionCaptureStrategy,
            candidate: (source: String, target: String)
        )?
        if let focusedCandidate {
            selectedCorrection = (.focusedTextDiff, focusedCandidate)
        } else if finishedSession.editTracker.isDeterministic, let trackerCandidate {
            selectedCorrection = (.editTracker, trackerCandidate)
        } else {
            selectedCorrection = nil
        }

        guard let selectedCorrection else {
            if canContinueCapture {
                continueMonitoringAfterNoLearnableResult(from: &finishedSession)
                return
            }
            accessibilityBridge.restoreManualAccessibilityIfNeeded(finishedSession.manualAccessibilitySession)
            session = nil
            return
        }

        if isExistingLearnedReplacement(
            source: selectedCorrection.candidate.source,
            target: selectedCorrection.candidate.target
        ) {
            if canContinueCapture {
                continueMonitoringAfterNoLearnableResult(from: &finishedSession)
            } else {
                accessibilityBridge.restoreManualAccessibilityIfNeeded(finishedSession.manualAccessibilitySession)
                session = nil
            }
            return
        }

        let learnedSource = selectedCorrection.candidate.source
        let learnedTarget = selectedCorrection.candidate.target
        logger.info(
            "detected strategy=\(strategyLabel(selectedCorrection.strategy)) source=\"\(compactLogValue(learnedSource))\" target=\"\(compactLogValue(learnedTarget))\""
        )

        Task.detached(priority: .utility) {
            _ = CustomVocabularyManager.shared.recordUserEditSuggestion(
                source: learnedSource,
                target: learnedTarget
            )
        }
        continueMonitoringAfterNoLearnableResult(from: &finishedSession, restartCaptureWindow: true)
    }

    private func continueMonitoringAfterNoLearnableResult(
        from session: inout Session,
        restartCaptureWindow: Bool = false
    ) {
        mouseRecoveryTask?.cancel()
        mouseRecoveryTask = nil
        let nextBaselineText: String
        if let latestSelection = accessibilityBridge.focusedTextSelection(
            preferredElement: session.snapshotElement ?? session.focusedElement,
            reusePreferredElementSnapshot: session.snapshotElement != nil
        ) {
            session.focusedTextAtStart = latestSelection.text
            session.snapshotElement = latestSelection.element
            nextBaselineText = latestSelection.text
        } else {
            nextBaselineText = session.editTracker.modeledText
        }
        session.editTracker.resetBaseline(to: nextBaselineText)
        if session.insertionStartInField == nil {
            session.insertionStartInField = accessibilityBridge.inferredInsertionStartInFocusedField(
                insertedText: nextBaselineText,
                focusedTextAtStart: session.focusedTextAtStart,
                preferredElement: session.focusedElement
            )
        }
        session.isAwaitingMouseRecovery = false
        session.hasMeaningfulEdit = false
        if restartCaptureWindow {
            session.startedAt = Date()
        }
        self.session = session
        scheduleTimeout()
    }

    private func strategyLabel(_ strategy: CorrectionCaptureStrategy) -> String {
        switch strategy {
        case .focusedTextDiff:
            return "focused_text_diff"
        case .editTracker:
            return "edit_tracker"
        }
    }

    private func isExistingLearnedReplacement(source: String, target: String) -> Bool {
        CustomVocabularyManager.shared.hasLearnedRule(source: source, target: target)
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

    nonisolated private static func shouldIgnoreEventForLearning(eventSourceUserData: Int64) -> Bool {
        eventSourceUserData == SyntheticInputEvent.syntheticEventTag
    }

    nonisolated static func shouldIgnoreEventForTesting(_ event: ObservedKeyEvent) -> Bool {
        shouldIgnoreEventForLearning(eventSourceUserData: event.eventSourceUserData)
    }

    nonisolated static func deriveCorrectionForTesting(
        from original: String,
        to current: String
    ) async -> (source: String, target: String)? {
        await MainActor.run {
            CorrectionLearningMonitor.shared.deriveCorrection(from: original, to: current)
        }
    }

    nonisolated static func focusedTextBaselinePlausibilityForTesting(
        snapshot: String?,
        anchorText: String
    ) async -> Bool {
        await MainActor.run {
            CorrectionLearningMonitor.shared.isPlausibleFocusedTextBaseline(snapshot, for: anchorText)
        }
    }

    private func deriveCorrectionFromFocusedTextDiff(session: Session) -> FocusedDiffOutcome {
        let baselineText = session.focusedTextAtStart ?? session.originalText
        let preferredElement: CorrectionLearningAccessibilityElement? = if session.focusedTextAtStart == nil {
            accessibilityBridge.focusedElement() ?? session.snapshotElement ?? session.focusedElement
        } else {
            session.snapshotElement ?? session.focusedElement
        }
        let shouldReusePreferredSnapshot = session.focusedTextAtStart != nil && session.snapshotElement != nil

        guard let focusedTextAtEnd = accessibilityBridge.focusedTextSelection(
            preferredElement: preferredElement,
            anchorText: baselineText,
            reusePreferredElementSnapshot: shouldReusePreferredSnapshot
        )?.text else {
            return .unavailable
        }
        guard focusedTextAtEnd != baselineText else {
            return .noLearnable
        }

        if let correction = deriveCorrection(from: baselineText, to: focusedTextAtEnd) {
            return .learned(source: correction.source, target: correction.target)
        }
        return .noLearnable
    }

    private func isPlausibleFocusedTextBaseline(_ snapshot: String?, for anchorText: String) -> Bool {
        guard let snapshot else { return false }

        let normalizedSnapshot = CustomVocabularyManager.normalizedLookupKey(snapshot)
        let normalizedAnchor = CustomVocabularyManager.normalizedLookupKey(anchorText)
        guard !normalizedSnapshot.isEmpty, !normalizedAnchor.isEmpty else {
            return false
        }

        let collapsedSnapshot = CustomVocabularyManager.normalizedCollapsedKey(snapshot)
        let collapsedAnchor = CustomVocabularyManager.normalizedCollapsedKey(anchorText)
        if normalizedSnapshot == normalizedAnchor || (!collapsedAnchor.isEmpty && collapsedSnapshot == collapsedAnchor) {
            return true
        }
        if !collapsedAnchor.isEmpty && collapsedSnapshot.contains(collapsedAnchor) {
            return true
        }

        let anchorTokens = Set(normalizedAnchor.split(whereSeparator: \.isWhitespace).map(String.init))
        let snapshotTokens = normalizedSnapshot.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !anchorTokens.isEmpty, !snapshotTokens.isEmpty else {
            return false
        }

        let overlapCount = anchorTokens.reduce(0) { partialResult, token in
            partialResult + (snapshotTokens.contains(token) ? 1 : 0)
        }
        let recall = Double(overlapCount) / Double(anchorTokens.count)
        let precision = Double(overlapCount) / Double(snapshotTokens.count)
        let lengthRatio = Double(snapshot.count) / Double(max(anchorText.count, 1))

        return recall >= 0.75 && precision >= 0.60 && lengthRatio >= 0.80 && lengthRatio <= 1.75
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

    private func compactLogValue(_ value: String, limit: Int = 48) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= limit {
            return singleLine
        }
        return String(singleLine.prefix(limit - 3)) + "..."
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

    private func uniqueRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }

        var searchStart = haystack.startIndex
        var uniqueMatch: Range<String.Index>?
        while searchStart <= haystack.endIndex,
              let match = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if uniqueMatch != nil {
                return nil
            }
            uniqueMatch = match

            if match.lowerBound < haystack.endIndex {
                searchStart = haystack.index(after: match.lowerBound)
            } else {
                break
            }
        }
        return uniqueMatch
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

}
