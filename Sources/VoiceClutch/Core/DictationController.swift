import AppKit
import Combine
import Foundation

/// Coordinates dictation state, preparation, and text delivery for the app host.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: VoiceClutchState = .idle
    @Published public private(set) var downloadProgress: Double = 0.0
    @Published public private(set) var downloadModelLabel: String?

    private let bootstrapper: TranscriptionBootstrapper
    private let transcriptPostProcessor = TranscriptPostProcessor()
    private let logger = AppLogger(category: "DictationController")
    private var cancellables = Set<AnyCancellable>()
    private var processingTimeoutTask: Task<Void, Never>?
    private var finalProcessingTask: Task<Void, Never>?
    private var latestPartialText: String = ""
    private var lastInjectedPartialText: String = ""
    private var clipboardContextPreview: String?
    private var isAwaitingFinalResult = false

    public init(bootstrapper: TranscriptionBootstrapper = TranscriptionBootstrapper()) {
        self.bootstrapper = bootstrapper

        bootstrapper.onTranscriptionResult = { [weak self] text, isFinal in
            self?.handleTranscriptionResult(text, isFinal: isFinal)
        }

        bootstrapper.onStateChange = { [weak self] newState in
            self?.state = newState
        }

        bootstrapper.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.downloadProgress = progress
            }
            .store(in: &cancellables)
    }

    public var audioManager: AudioManager {
        bootstrapper.audioManager
    }

    public var isReady: Bool {
        bootstrapper.isReady
    }

    public func setState(_ nextState: VoiceClutchState) {
        state = nextState
    }

    public func areModelsInstalled() -> Bool {
        let asrInstalled = bootstrapper.areModelsInstalled()
        let llmReady = !isSmartFormattingEnabled() || LocalLLMCoordinator.isDefaultModelInstalled()
        return asrInstalled && llmReady
    }

    public func requiredDownloadSize() async -> Int64? {
        let asrNeedsDownload = !bootstrapper.areModelsInstalled()
        let asrBytes: Int64
        if asrNeedsDownload {
            guard let requiredASRBytes = await bootstrapper.requiredDownloadSize() else {
                return nil
            }
            asrBytes = requiredASRBytes
        } else {
            asrBytes = 0
        }

        let llmNeedsDownload = isSmartFormattingEnabled() && !LocalLLMCoordinator.isDefaultModelInstalled()
        let llmBytes: Int64
        if llmNeedsDownload {
            guard let requiredLLMBytes = await LocalLLMCoordinator.requiredDownloadSizeIfMissing() else {
                return nil
            }
            llmBytes = requiredLLMBytes
        } else {
            llmBytes = 0
        }

        return asrBytes + llmBytes
    }

    @discardableResult
    public func prepareForUse() async throws -> TranscriptionBootstrapper.PreparationOutcome {
        defer {
            downloadModelLabel = nil
        }

        let shouldDownloadASR = !bootstrapper.areModelsInstalled()
        let shouldDownloadLLM = isSmartFormattingEnabled() && !LocalLLMCoordinator.isDefaultModelInstalled()

        if shouldDownloadASR {
            state = .downloading
            downloadModelLabel = "ASR model"
            downloadProgress = 0.0
        }

        let didDownloadASR = try await bootstrapper.downloadAsrModelsIfNeeded()

        if shouldDownloadLLM {
            state = .downloading
            downloadModelLabel = "LLM model"
            downloadProgress = 0.0
        } else {
            state = .loadingModel
        }

        async let asrPrepare: Void = bootstrapper.prepareSession()
        async let didDownloadLLM: Bool = downloadLlmModelIfNeeded(shouldDownloadLLM)

        try await asrPrepare
        let llmDownloaded = try await didDownloadLLM
        state = .loadingModel
        await transcriptPostProcessor.prepareIfPossible()
        state = .idle

        if llmDownloaded || didDownloadASR {
            return .downloadedModels
        }
        return .usedExistingModels
    }

    public func startRecording(onCaptureReady: (@MainActor @Sendable () -> Void)? = nil) throws {
        guard state == .idle else { return }
        // A new transcription cycle starts now; stop any prior correction-learning timer/session.
        CorrectionLearningMonitor.shared.cancel()
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        finalProcessingTask?.cancel()
        finalProcessingTask = nil
        resetPartialState()
        isAwaitingFinalResult = false

        guard isReady else {
            throw TranscriptionSession.SessionError.notReady
        }

        state = .recording

        do {
            captureClipboardContextPreviewIfNeeded()
            try bootstrapper.startRecording(onCaptureReady: onCaptureReady)
            TextInjector.beginStreamingSession()
        } catch {
            state = .idle
            resetPartialState()
            isAwaitingFinalResult = false
            TextInjector.cancelStreamingSession()
            throw error
        }
    }

    public func stopRecording() {
        guard state == .recording else { return }
        state = .processing
        isAwaitingFinalResult = true
        bootstrapper.stopRecording()

        processingTimeoutTask?.cancel()
        processingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000_000)
            await MainActor.run {
                guard let self, self.state == .processing, self.isAwaitingFinalResult else { return }
                self.isAwaitingFinalResult = false
                let fallbackText = self.latestPartialText
                TextInjector.commitStreamingFinalNormalized(fallbackText)
                self.resetPartialState()
                self.state = .idle
            }
        }
    }

    @discardableResult
    public func playStartChime() -> Bool {
        bootstrapper.playStartChime()
    }

    @discardableResult
    public func playStopChime() -> Bool {
        bootstrapper.playStopChime()
    }

    public func shutdown() {
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        finalProcessingTask?.cancel()
        finalProcessingTask = nil
        resetPartialState()
        isAwaitingFinalResult = false
        TextInjector.cancelStreamingSession()
        bootstrapper.shutdown()
        state = .idle
    }

    @discardableResult
    func compactMemoryIfIdle() -> Bool {
        guard state == .idle, !isAwaitingFinalResult else {
            return false
        }

        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        finalProcessingTask?.cancel()
        finalProcessingTask = nil
        resetPartialState()
        TextInjector.cancelStreamingSession()
        return bootstrapper.compactMemoryIfIdle()
    }

    func handleMemoryPressure(level: LocalLLMMemoryPressureLevel) {
        Task {
            await transcriptPostProcessor.handleMemoryPressure(level: level)
        }
    }

    private func handleTranscriptionResult(_ text: String, isFinal: Bool) {
        if isFinal {
            guard isAwaitingFinalResult else { return }
            isAwaitingFinalResult = false
            processingTimeoutTask?.cancel()
            processingTimeoutTask = nil
            let normalizedFinalText = TextInjector.normalizedStreamingTranscript(text)
            let stabilizedFinalText = stabilizedTranscript(normalizedFinalText, previous: latestPartialText)
            let fallbackText = !stabilizedFinalText.isEmpty ? stabilizedFinalText : latestPartialText
            emitProvisionalFinalPreviewIfNeeded(fallbackText)
            let vocabularySnapshot = CustomVocabularyManager.shared.snapshot()

            finalProcessingTask?.cancel()
            finalProcessingTask = Task { [weak self] in
                guard let self else { return }
                await self.finalizeTranscript(
                    fallbackText,
                    vocabularySnapshot: vocabularySnapshot
                )
            }
            return
        }

        // Ignore post-release partials while processing final ASR output.
        // This avoids release-tail punctuation churn from rewriting already
        // injected text; only the final transcript should apply in this phase.
        guard state == .recording, !text.isEmpty else {
            return
        }

        let normalizedPartialText = TextInjector.normalizedStreamingTranscript(text)
        guard !normalizedPartialText.isEmpty else {
            return
        }

        let stabilizedPartialText = stabilizedTranscript(normalizedPartialText, previous: latestPartialText)
        latestPartialText = stabilizedPartialText
        guard shouldInjectPartial(stabilizedPartialText) else { return }
        TextInjector.updateStreamingPartialNormalized(stabilizedPartialText)
    }

    private func emitProvisionalFinalPreviewIfNeeded(_ normalizedTranscript: String) {
        TextInjector.updateStreamingProvisionalFinalNormalized(normalizedTranscript)
    }

    private func finalizeTranscript(
        _ transcript: String,
        vocabularySnapshot: CustomVocabularySnapshot
    ) async {
        let processedTranscript = await transcriptPostProcessor.process(
            transcript: transcript,
            vocabularySnapshot: vocabularySnapshot,
            clipboardContextPreview: clipboardContextPreview
        )
        logTranscriptChange(
            stage: "det",
            before: transcript,
            after: processedTranscript.deterministicTranscript
        )

        let llmResponse = processedTranscript.llmResponse
        logger.info(
            localSmartFormattingLogLine(
                for: llmResponse,
                deterministic: processedTranscript.deterministicTranscript,
                preLock: processedTranscript.preLockTranscript
            )
        )

        logTranscriptChange(
            stage: "lock",
            before: processedTranscript.preLockTranscript,
            after: processedTranscript.finalTranscript
        )

        guard !Task.isCancelled else { return }
        finalProcessingTask = nil
        let normalizedProcessedFinal = TextInjector.normalizedStreamingTranscript(
            processedTranscript.finalTranscript
        )
        let stabilizedProcessedFinal = stabilizedTranscript(
            normalizedProcessedFinal,
            previous: transcript
        )
        TextInjector.commitStreamingFinalNormalized(stabilizedProcessedFinal)
        resetPartialState()
        state = .idle
    }

    @discardableResult
    private func logTranscriptChange(stage: String, before: String, after: String) -> Bool {
        guard before != after else {
            return false
        }

        logger.debug(
            "stage=\(stage) changes: \(transcriptDiffSummary(before: before, after: after))"
        )
        return true
    }

    private func localSmartFormattingLogLine(
        for response: LocalLLMResponse,
        deterministic: String,
        preLock: String
    ) -> String {
        let asrPrompt = redactedTranscriptPreview(deterministic)
        let usedSource = response.wasOutputAccepted ? "llmFinalPass" : "asrPrompt"
        var fields = [
            "outcome=\(response.outcome.rawValue)",
            "dur=\(response.durationMs)ms",
            "used=\(usedSource)"
        ]
        if let skipReason = response.skipReason {
            fields.append("skip=\(skipReason.rawValue)")
        }
        if let failureReason = response.failureReason {
            fields.append("fail=\(failureReason.rawValue)")
        }
        if let validationFailure = response.validationFailure {
            fields.append("val=\(validationFailure.rawValue)")
        }
        if response.wasOutputAccepted {
            fields.append("accept=validated")
        }
        let proposed = response.proposedTranscript
        guard !proposed.isEmpty else {
            fields.append("llm=empty")
            return """
            \(fields.joined(separator: " "))
              asr="\(asrPrompt)"
            """
        }

        let overlapRatio = proposalTokenOverlapRatio(proposed: proposed, deterministic: deterministic)
        fields.append("overlap=\(String(format: "%.2f", overlapRatio))")
        if deterministic != preLock {
            fields.append(transcriptDiffSummary(before: deterministic, after: preLock))
        }
        let llmFinalPass = redactedTranscriptPreview(proposed)
        return """
        \(fields.joined(separator: " "))
          asr="\(asrPrompt)"
          llm="\(llmFinalPass)"
        """
    }

    private func proposalTokenOverlapRatio(proposed: String, deterministic: String) -> Double {
        let proposedTokens = Set(
            proposed
                .lowercased()
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        )
        let deterministicTokens = Set(
            deterministic
                .lowercased()
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        )

        let unionCount = proposedTokens.union(deterministicTokens).count
        guard unionCount > 0 else { return 1 }
        let overlapCount = proposedTokens.intersection(deterministicTokens).count
        return Double(overlapCount) / Double(unionCount)
    }

    private func redactedTranscriptPreview(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
    }

    private func transcriptDiffSummary(before: String, after: String) -> String {
        let replacementPairs = Self.transcriptDiffPairs(before: before, after: after)
        guard !replacementPairs.isEmpty else {
            return "\(redactedTranscriptPreview(before)) -> \(redactedTranscriptPreview(after))"
        }
        return replacementPairs.joined(separator: ", ")
    }

    nonisolated static func transcriptDiffPairs(
        before: String,
        after: String,
        maxPairs: Int = 5
    ) -> [String] {
        let beforeTokens = normalizedTokens(from: before)
        let afterTokens = normalizedTokens(from: after)

        guard beforeTokens != afterTokens else {
            return []
        }

        let operations = tokenDiffOperations(beforeTokens: beforeTokens, afterTokens: afterTokens)

        var replacements: [String] = []
        var removedTokens: [String] = []
        var addedTokens: [String] = []

        func flushReplacement() {
            guard !removedTokens.isEmpty || !addedTokens.isEmpty else {
                return
            }
            let removed = removedTokens.isEmpty ? "<empty>" : removedTokens.joined(separator: " ")
            let added = addedTokens.isEmpty ? "<empty>" : addedTokens.joined(separator: " ")
            replacements.append("\(removed) -> \(added)")
            removedTokens.removeAll(keepingCapacity: true)
            addedTokens.removeAll(keepingCapacity: true)
        }

        for operation in operations {
            switch operation {
            case .equal:
                flushReplacement()
            case .delete(let token):
                removedTokens.append(token)
            case .insert(let token):
                addedTokens.append(token)
            }
        }
        flushReplacement()

        guard replacements.count > maxPairs else {
            return replacements
        }

        let visibleReplacements = replacements.prefix(maxPairs)
        return Array(visibleReplacements) + ["... +\(replacements.count - maxPairs) more"]
    }

    private nonisolated static func normalizedTokens(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private nonisolated static func tokenDiffOperations(
        beforeTokens: [String],
        afterTokens: [String]
    ) -> [TokenDiffOperation] {
        let beforeCount = beforeTokens.count
        let afterCount = afterTokens.count
        var lcs = Array(
            repeating: Array(repeating: 0, count: afterCount + 1),
            count: beforeCount + 1
        )

        for beforeIndex in 0..<beforeCount {
            for afterIndex in 0..<afterCount {
                if beforeTokens[beforeIndex] == afterTokens[afterIndex] {
                    lcs[beforeIndex + 1][afterIndex + 1] = lcs[beforeIndex][afterIndex] + 1
                } else {
                    lcs[beforeIndex + 1][afterIndex + 1] = max(
                        lcs[beforeIndex][afterIndex + 1],
                        lcs[beforeIndex + 1][afterIndex]
                    )
                }
            }
        }

        var reversedOperations: [TokenDiffOperation] = []
        var beforeIndex = beforeCount
        var afterIndex = afterCount

        while beforeIndex > 0 || afterIndex > 0 {
            if beforeIndex > 0,
               afterIndex > 0,
               beforeTokens[beforeIndex - 1] == afterTokens[afterIndex - 1] {
                reversedOperations.append(.equal(beforeTokens[beforeIndex - 1]))
                beforeIndex -= 1
                afterIndex -= 1
            } else if afterIndex > 0,
                      (beforeIndex == 0 || lcs[beforeIndex][afterIndex - 1] >= lcs[beforeIndex - 1][afterIndex]) {
                reversedOperations.append(.insert(afterTokens[afterIndex - 1]))
                afterIndex -= 1
            } else if beforeIndex > 0 {
                reversedOperations.append(.delete(beforeTokens[beforeIndex - 1]))
                beforeIndex -= 1
            }
        }

        return reversedOperations.reversed()
    }

    private nonisolated enum TokenDiffOperation {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    private func resetPartialState() {
        latestPartialText = ""
        lastInjectedPartialText = ""
        clipboardContextPreview = nil
    }

    private func captureClipboardContextPreviewIfNeeded() {
        guard isSmartFormattingEnabled(), ClipboardContextFormattingPreference.load() else {
            clipboardContextPreview = nil
            return
        }

        clipboardContextPreview = Self.makeClipboardContextPreview(
            from: NSPasteboard.general.string(forType: .string)
        )
    }

    static func makeClipboardContextPreview(from rawText: String?, maxLength: Int = 300) -> String? {
        guard maxLength > 0 else { return nil }
        guard let rawText else { return nil }

        let normalized = rawText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maxLength else { return normalized }

        let truncationMarker = " [truncated]"
        guard maxLength > truncationMarker.count else {
            let end = normalized.index(normalized.startIndex, offsetBy: maxLength)
            return String(normalized[..<end])
        }

        let prefixLength = maxLength - truncationMarker.count
        let endIndex = normalized.index(normalized.startIndex, offsetBy: prefixLength)
        return String(normalized[..<endIndex]) + truncationMarker
    }

    private func downloadLlmModelIfNeeded(_ shouldDownloadLLM: Bool) async throws -> Bool {
        guard shouldDownloadLLM else {
            return false
        }

        _ = try await LocalLLMCoordinator.ensureDefaultModelAvailable { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }
        state = .loadingModel
        return true
    }

    private func isSmartFormattingEnabled() -> Bool {
        LocalSmartFormattingPreference.load()
    }

    private func shouldInjectPartial(_ text: String) -> Bool {
        guard text != lastInjectedPartialText else { return false }
        lastInjectedPartialText = text
        return true
    }

    private func stabilizedTranscript(_ candidate: String, previous: String) -> String {
        guard !candidate.isEmpty, !previous.isEmpty else {
            return candidate
        }

        guard candidate.hasPrefix(previous) else {
            return candidate
        }

        let suffixStart = candidate.index(candidate.startIndex, offsetBy: previous.count)
        let suffix = String(candidate[suffixStart...])
        if let overlapLength = duplicatedJoinOverlapLength(previous: previous, suffix: suffix) {
            let trimmedSuffixStart = suffix.index(suffix.startIndex, offsetBy: overlapLength)
            let stabilized = previous + suffix[trimmedSuffixStart...]
            return stabilized.count < candidate.count ? stabilized : candidate
        }

        guard let trimmedRestartSuffix = trimmedRestartedDuplicateSuffix(previous: previous, suffix: suffix) else {
            return candidate
        }

        let stabilized = previous + trimmedRestartSuffix
        return stabilized.count < candidate.count ? stabilized : candidate
    }

    private func duplicatedJoinOverlapLength(previous: String, suffix: String) -> Int? {
        guard !suffix.isEmpty else { return nil }

        let maxOverlap = min(previous.count, suffix.count)
        guard maxOverlap >= 3 else { return nil }

        for overlapLength in stride(from: maxOverlap, through: 3, by: -1) {
            let previousStart = previous.index(previous.endIndex, offsetBy: -overlapLength)
            let previousOverlap = previous[previousStart...]
            let suffixEnd = suffix.index(suffix.startIndex, offsetBy: overlapLength)
            let suffixOverlap = suffix[..<suffixEnd]

            guard previousOverlap.caseInsensitiveCompare(String(suffixOverlap)) == .orderedSame else {
                continue
            }

            guard hasWordBoundary(before: previousStart, in: previous) else {
                continue
            }

            guard hasWordBoundary(after: suffixEnd, in: suffix) else {
                continue
            }

            return overlapLength
        }

        return nil
    }

    private struct TranscriptTokenComponent {
        let normalizedValue: String
        let endIndex: String.Index
    }

    private func trimmedRestartedDuplicateSuffix(previous: String, suffix: String) -> String? {
        guard let suffixContentStart = firstAlphaNumericIndex(in: suffix) else {
            return nil
        }

        let previousComponents = normalizedTokenComponents(in: previous)
        let suffixComponents = normalizedTokenComponents(in: suffix, startingAt: suffixContentStart)

        guard previousComponents.count >= 8, suffixComponents.count >= 8 else {
            return nil
        }

        let maxOverlap = min(previousComponents.count, suffixComponents.count)
        var overlapCount = 0
        while overlapCount < maxOverlap {
            guard previousComponents[overlapCount].normalizedValue == suffixComponents[overlapCount].normalizedValue else {
                break
            }
            overlapCount += 1
        }

        guard overlapCount >= 8 else {
            return nil
        }

        let shorterSideCount = min(previousComponents.count, suffixComponents.count)
        guard overlapCount * 100 >= shorterSideCount * 80 else {
            return nil
        }

        let overlapEndIndex = suffixComponents[overlapCount - 1].endIndex
        return String(suffix[overlapEndIndex...])
    }

    private func normalizedTokenComponents(
        in text: String,
        startingAt start: String.Index? = nil
    ) -> [TranscriptTokenComponent] {
        var components: [TranscriptTokenComponent] = []
        var index = start ?? text.startIndex

        while index < text.endIndex {
            guard isAlphaNumeric(text[index]) else {
                index = text.index(after: index)
                continue
            }

            let tokenStart = index
            while index < text.endIndex, isAlphaNumeric(text[index]) {
                index = text.index(after: index)
            }
            let tokenEnd = index
            let token = text[tokenStart..<tokenEnd]
            let normalizedSubtokens = splitTokenIntoComparisonSubtokens(token)

            if normalizedSubtokens.isEmpty {
                continue
            }

            for normalizedSubtoken in normalizedSubtokens {
                components.append(
                    TranscriptTokenComponent(
                        normalizedValue: normalizedSubtoken,
                        endIndex: tokenEnd
                    )
                )
            }
        }

        return components
    }

    private func splitTokenIntoComparisonSubtokens(_ token: Substring) -> [String] {
        let tokenString = String(token)
        guard !tokenString.isEmpty else {
            return []
        }

        var subtokens: [String] = []
        var subtokenStart = tokenString.startIndex
        var index = tokenString.index(after: subtokenStart)

        while index < tokenString.endIndex {
            let previousIndex = tokenString.index(before: index)
            let previousCharacter = tokenString[previousIndex]
            let currentCharacter = tokenString[index]

            if shouldSplitToken(previous: previousCharacter, current: currentCharacter) {
                let nextSubtoken = tokenString[subtokenStart..<index].lowercased()
                if !nextSubtoken.isEmpty {
                    subtokens.append(nextSubtoken)
                }
                subtokenStart = index
            }

            index = tokenString.index(after: index)
        }

        let trailingSubtoken = tokenString[subtokenStart..<tokenString.endIndex].lowercased()
        if !trailingSubtoken.isEmpty {
            subtokens.append(trailingSubtoken)
        }

        return subtokens
    }

    private func shouldSplitToken(previous: Character, current: Character) -> Bool {
        let previousIsNumeric = isNumeric(previous)
        let currentIsNumeric = isNumeric(current)
        if previousIsNumeric != currentIsNumeric {
            return true
        }

        return isLowercase(previous) && isUppercase(current)
    }

    private func firstAlphaNumericIndex(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            if isAlphaNumeric(text[index]) {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func isNumeric(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    private func isLowercase(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
    }

    private func isUppercase(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
    }

    private func hasWordBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let precedingIndex = text.index(before: index)
        return !isAlphaNumeric(text[precedingIndex])
    }

    private func hasWordBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return !isAlphaNumeric(text[index])
    }

    private func isAlphaNumeric(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
