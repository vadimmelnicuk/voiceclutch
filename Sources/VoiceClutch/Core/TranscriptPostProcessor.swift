import Foundation

struct TranscriptPostProcessingResult: Sendable {
    let deterministicTranscript: String
    let llmResponse: LocalLLMResponse
    let preLockTranscript: String
    let finalTranscript: String
    let appliedEdits: [TranscriptEdit]
}

@MainActor
final class TranscriptPostProcessor {
    private let correctionEngine: FinalTranscriptCorrectionEngine
    private let llmService: any LocalLLMServing
    private let contextProvider: any TranscriptFormattingContextProviding
    private let isSmartFormattingEnabled: () -> Bool
    private let enhancedCoordinator: EnhancedLocalLLMCoordinator?

    init(
        correctionEngine: FinalTranscriptCorrectionEngine = FinalTranscriptCorrectionEngine(),
        llmService: any LocalLLMServing,
        contextProvider: any TranscriptFormattingContextProviding = FrontmostTranscriptFormattingContextProvider(),
        isSmartFormattingEnabled: @escaping () -> Bool = { LocalSmartFormattingPreference.load() },
        enhancedCoordinator: EnhancedLocalLLMCoordinator? = nil
    ) {
        self.correctionEngine = correctionEngine
        self.llmService = llmService
        self.contextProvider = contextProvider
        self.isSmartFormattingEnabled = isSmartFormattingEnabled
        self.enhancedCoordinator = enhancedCoordinator
    }

    convenience init(
        correctionEngine: FinalTranscriptCorrectionEngine = FinalTranscriptCorrectionEngine(),
        contextProvider: any TranscriptFormattingContextProviding = FrontmostTranscriptFormattingContextProvider(),
        isSmartFormattingEnabled: @escaping () -> Bool = { LocalSmartFormattingPreference.load() }
    ) {
        let enhanced = EnhancedLocalLLMCoordinator()
        self.init(
            correctionEngine: correctionEngine,
            llmService: enhanced,
            contextProvider: contextProvider,
            isSmartFormattingEnabled: isSmartFormattingEnabled,
            enhancedCoordinator: enhanced
        )
    }

    func prepareIfPossible() async {
        await llmService.prepareIfPossible()
    }

    func process(
        transcript: String,
        vocabularySnapshot: CustomVocabularySnapshot
    ) async -> TranscriptPostProcessingResult {
        let deterministicTranscript = correctionEngine.correctedTranscript(
            from: transcript,
            vocabulary: vocabularySnapshot
        )

        let request = LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: transcript,
            deterministicTranscript: deterministicTranscript,
            vocabulary: vocabularySnapshot,
            formattingContext: contextProvider.currentContext()
        )

        let llmResponse: LocalLLMResponse
        if let skipReason = LocalLLMRequestEvaluator.skipReason(
            for: request,
            isEnabled: isSmartFormattingEnabled()
        ) {
            llmResponse = .skipped(transcript: deterministicTranscript, reason: skipReason)
        } else {
            llmResponse = await llmService.process(request)
        }

        let preLockTranscript: String
        switch llmResponse.outcome {
        case .refined, .unchanged:
            preLockTranscript = llmResponse.transcript
        case .unavailable, .skipped, .timedOut, .failed, .rejected:
            preLockTranscript = deterministicTranscript
        }

        let finalTranscript = correctionEngine.correctedTranscript(
            from: preLockTranscript,
            vocabulary: vocabularySnapshot
        )

        // Extract applied edits if using enhanced coordinator
        let appliedEdits: [TranscriptEdit]
        if enhancedCoordinator != nil,
           case .refined = llmResponse.outcome,
           deterministicTranscript != finalTranscript {
            // We can derive edits by comparing deterministic and final
            appliedEdits = deriveEdits(from: deterministicTranscript, to: finalTranscript)
        } else {
            appliedEdits = []
        }

        // Track successful transcripts for context
        if case .refined = llmResponse.outcome {
            await enhancedCoordinator?.addSentenceToHistory(finalTranscript)
        }

        return TranscriptPostProcessingResult(
            deterministicTranscript: deterministicTranscript,
            llmResponse: llmResponse,
            preLockTranscript: preLockTranscript,
            finalTranscript: finalTranscript,
            appliedEdits: appliedEdits
        )
    }

    func recordCorrection(source: String, target: String) async {
        await enhancedCoordinator?.recordCorrection(source: source, target: target)
    }

    func getCorrectionHistory() async -> [LearnedCorrection] {
        await enhancedCoordinator?.getCorrectionHistory() ?? []
    }

    func clearHistory() async {
        await enhancedCoordinator?.clearHistory()
    }

    private func deriveEdits(from original: String, to modified: String) -> [TranscriptEdit] {
        // Simple character-level diff to extract edits
        var edits: [TranscriptEdit] = []

        // Find changed regions
        let originalChars = Array(original)
        let modifiedChars = Array(modified)
        let maxCommonPrefix = zip(originalChars, modifiedChars)
            .prefix(while: { $0 == $1 })
            .count

        let maxCommonSuffix = zip(originalChars.reversed(), modifiedChars.reversed())
            .prefix(while: { $0 == $1 })
            .count

        guard maxCommonPrefix + maxCommonSuffix < originalChars.count ||
              maxCommonPrefix + maxCommonSuffix < modifiedChars.count else {
            return edits
        }

        // Clamp suffix to available characters to avoid invalid ranges
        let originalRemaining = max(0, originalChars.count - maxCommonPrefix)
        let modifiedRemaining = max(0, modifiedChars.count - maxCommonPrefix)
        let clampedSuffix = min(maxCommonSuffix, originalRemaining, modifiedRemaining)

        let originalEditStart = originalChars.index(originalChars.startIndex, offsetBy: maxCommonPrefix)
        let originalEditEnd = originalChars.index(originalChars.endIndex, offsetBy: -clampedSuffix)
        let modifiedEditStart = modifiedChars.index(modifiedChars.startIndex, offsetBy: maxCommonPrefix)
        let modifiedEditEnd = modifiedChars.index(modifiedChars.endIndex, offsetBy: -clampedSuffix)

        // Ensure ranges are valid (start < end)
        guard originalEditStart < originalEditEnd,
              modifiedEditStart < modifiedEditEnd else {
            return edits
        }

        let fromText = String(originalChars[originalEditStart..<originalEditEnd])
        let toText = String(modifiedChars[modifiedEditStart..<modifiedEditEnd])

        // Determine edit type
        let editType: TranscriptEditType
        let fromLetters = fromText.filter { $0.isLetter || $0.isNumber }
        let toLetters = toText.filter { $0.isLetter || $0.isNumber }

        if fromLetters == toLetters {
            editType = .punctuation
        } else if fromText.lowercased() == toText.lowercased() {
            editType = .capitalization
        } else if fromText.filter({ !$0.isWhitespace }).isEmpty || toText.filter({ !$0.isWhitespace }).isEmpty {
            editType = .spacing
        } else {
            editType = .obviousAsrFix
        }

        edits.append(TranscriptEdit(from: fromText, to: toText, reason: editType))

        return edits
    }
}
