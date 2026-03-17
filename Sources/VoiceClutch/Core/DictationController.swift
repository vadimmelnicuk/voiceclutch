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

    private func handleTranscriptionResult(_ text: String, isFinal: Bool) {
        if isFinal {
            guard isAwaitingFinalResult else { return }
            isAwaitingFinalResult = false
            processingTimeoutTask?.cancel()
            processingTimeoutTask = nil
            let normalizedFinalText = TextInjector.normalizedStreamingTranscript(text)
            let stabilizedFinalText = stabilizedTranscript(normalizedFinalText, previous: latestPartialText)
            let fallbackText = !stabilizedFinalText.isEmpty ? stabilizedFinalText : latestPartialText
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

    private func finalizeTranscript(
        _ transcript: String,
        vocabularySnapshot: CustomVocabularySnapshot
    ) async {
        let startedAt = ContinuousClock.now

        let processedTranscript = await transcriptPostProcessor.process(
            transcript: transcript,
            vocabularySnapshot: vocabularySnapshot
        )
        let deterministicChanged = logTranscriptChange(
            stage: "deterministic",
            before: transcript,
            after: processedTranscript.deterministicTranscript
        )

        let llmResponse = processedTranscript.llmResponse
        logger.info(localSmartFormattingLogLine(for: llmResponse))

        // Always log smart formatting with proposed vs actual
        logSmartFormattingStage(
            llmResponse: llmResponse,
            deterministic: processedTranscript.deterministicTranscript,
            preLock: processedTranscript.preLockTranscript
        )

        let smartFormattingChanged = logTranscriptChange(
            stage: "smartFormatting",
            before: processedTranscript.deterministicTranscript,
            after: processedTranscript.preLockTranscript
        )

        let lockChanged = logTranscriptChange(
            stage: "lock",
            before: processedTranscript.preLockTranscript,
            after: processedTranscript.finalTranscript
        )

        guard !Task.isCancelled else { return }
        finalProcessingTask = nil
        let changedStages = changedStagesSummary(
            deterministicChanged: deterministicChanged,
            smartFormattingChanged: smartFormattingChanged,
            lockChanged: lockChanged
        )
        logger.info(
            "Final transcript processing completed duration=\(elapsedMs(since: startedAt))ms finalChanged=\(processedTranscript.finalTranscript != transcript) changedStages=\(changedStages)"
        )
        TextInjector.commitStreamingFinalNormalized(processedTranscript.finalTranscript)
        resetPartialState()
        state = .idle
    }

    @discardableResult
    private func logTranscriptChange(stage: String, before: String, after: String) -> Bool {
        guard before != after else {
            return false
        }

        logger.debug(
            """
            Transcript stage=\(stage) changed=true \(transcriptDiffSummary(before: before, after: after))
              before="\(redactedTranscriptPreview(before))"
              after="\(redactedTranscriptPreview(after))"
            """
        )
        return true
    }

    private func localSmartFormattingLogLine(for response: LocalLLMResponse) -> String {
        var fields = [
            "Local smart-formatting outcome=\(response.outcome.rawValue)",
            "duration=\(response.durationMs)ms"
        ]
        if let skipReason = response.skipReason {
            fields.append("skip=\(skipReason.rawValue)")
        }
        if let failureReason = response.failureReason {
            fields.append("failure=\(failureReason.rawValue)")
        }
        if let validationFailure = response.validationFailure {
            fields.append("validation=\(validationFailure.rawValue)")
        }
        if response.wasOutputAccepted {
            fields.append("acceptance=sameWordTokens")
        }
        return fields.joined(separator: " ")
    }

    private func logSmartFormattingStage(
        llmResponse: LocalLLMResponse,
        deterministic: String,
        preLock: String
    ) {
        // Always log smart formatting stage, showing what LLM proposed vs what was actually used
        let proposed = llmResponse.proposedTranscript
        let used = preLock

        // Only log if there's something interesting to show
        guard !proposed.isEmpty else { return }

        // If proposed differs from deterministic, show the comparison
        if proposed != deterministic {
            logger.debug(
                """
                Transcript stage=smartFormatting outcome=\(llmResponse.outcome.rawValue)
                  proposed="\(redactedTranscriptPreview(proposed))"
                  used="\(redactedTranscriptPreview(used))"
                """
            )
        }
    }

    private func changedStagesSummary(
        deterministicChanged: Bool,
        smartFormattingChanged: Bool,
        lockChanged: Bool
    ) -> String {
        let changedStages = [
            deterministicChanged ? "deterministic" : nil,
            smartFormattingChanged ? "smartFormatting" : nil,
            lockChanged ? "lock" : nil
        ].compactMap { $0 }
        return changedStages.isEmpty ? "none" : changedStages.joined(separator: ",")
    }

    private func redactedTranscriptPreview(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
        let maxPreviewLength = 160
        guard collapsed.count > maxPreviewLength else { return collapsed }

        let headLength = 96
        let tailLength = 56
        let head = String(collapsed.prefix(headLength))
        let tail = String(collapsed.suffix(tailLength))
        return "\(head)...\(tail)"
    }

    private func transcriptDiffSummary(before: String, after: String) -> String {
        let beforeCharacters = Array(before)
        let afterCharacters = Array(after)
        let sharedLength = min(beforeCharacters.count, afterCharacters.count)

        var firstDifferenceIndex = 0
        while firstDifferenceIndex < sharedLength,
              beforeCharacters[firstDifferenceIndex] == afterCharacters[firstDifferenceIndex] {
            firstDifferenceIndex += 1
        }

        if firstDifferenceIndex == sharedLength, beforeCharacters.count == afterCharacters.count {
            return "beforeLen=\(before.count) afterLen=\(after.count) firstDiffChar=none"
        }

        return "beforeLen=\(before.count) afterLen=\(after.count) firstDiffChar=\(firstDifferenceIndex)"
    }

    private func elapsedMs(since startedAt: ContinuousClock.Instant) -> Int {
        let duration = startedAt.duration(to: ContinuousClock.now).components
        return Int(duration.seconds * 1_000) + Int(duration.attoseconds / 1_000_000_000_000_000)
    }

    private func resetPartialState() {
        latestPartialText = ""
        lastInjectedPartialText = ""
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
        guard let overlapLength = duplicatedJoinOverlapLength(previous: previous, suffix: suffix) else {
            return candidate
        }

        let trimmedSuffixStart = suffix.index(suffix.startIndex, offsetBy: overlapLength)
        let stabilized = previous + suffix[trimmedSuffixStart...]
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
