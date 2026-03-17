import Foundation

#if canImport(MLXLLM)
import MLXLLM
#endif
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif

protocol LocalLLMServing: Sendable {
    func prepareIfPossible() async
    func process(_ request: LocalLLMRequest) async -> LocalLLMResponse
    func handleMemoryPressure(level: LocalLLMMemoryPressureLevel) async
}

extension LocalLLMServing {
    func handleMemoryPressure(level _: LocalLLMMemoryPressureLevel) async {}
}

protocol LocalLLMGeneratingSession: Sendable {
    func respond(to prompt: String) async throws -> String
}

enum LocalLLMMemoryPressureLevel: String, Sendable {
    case warning
    case critical
}

#if canImport(MLXLLM) && canImport(MLXLMCommon)
/// Thread-safe adapter for MLX ChatSession.
/// Uses a serial queue to ensure only one call to ChatSession.respond is active at a time.
/// Clears session state before each request so formatting is strictly single-turn.
final class MLXChatSessionAdapter: @unchecked Sendable, LocalLLMGeneratingSession {
    private let session: ChatSession
    private let serialQueue: DispatchQueue

    init(session: ChatSession) {
        self.session = session
        self.serialQueue = DispatchQueue(label: "dev.vm.voiceclutch.mlx-chat-adapter", qos: .userInitiated)
    }

    func respond(to prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            serialQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                DispatchQueue.main.async {
                    Task.detached(priority: .userInitiated) { [session = self.session] in
                        do {
                            await session.clear()
                            continuation.resume(returning: try await session.respond(to: prompt))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
}
#endif

enum LocalLLMCapability: String, Sendable {
    case smartFormatting
    case commandTransform
    case snippetExpansion
    case contextAssist
}

enum LocalLLMSkipReason: String, Sendable {
    case disabled
    case unsupportedCapability
    case shortTranscript
    case singleToken
    case alreadyNormalized
    case codeLike
}

enum LocalLLMFailureReason: String, Sendable {
    case unavailable
    case modelLoadFailed
    case generationFailed
    case invalidOutput
}

enum LocalLLMValidationFailureReason: String, Sendable {
    case emptyOutput
    case droppedContent
    case protectedTermsChanged
    case excessiveRewrite
    case wordingChanged
}

struct LocalLLMRequest: Sendable {
    let capability: LocalLLMCapability
    let originalTranscript: String
    let deterministicTranscript: String
    let vocabulary: CustomVocabularySnapshot
    let formattingContext: TranscriptFormattingContext
    let listFormattingHint: ListFormattingHint
    let clipboardContextPreview: String?
    let timeoutNanoseconds: UInt64?

    init(
        capability: LocalLLMCapability,
        originalTranscript: String,
        deterministicTranscript: String,
        vocabulary: CustomVocabularySnapshot,
        formattingContext: TranscriptFormattingContext,
        listFormattingHint: ListFormattingHint = .none,
        clipboardContextPreview: String? = nil,
        timeoutNanoseconds: UInt64? = nil
    ) {
        self.capability = capability
        self.originalTranscript = originalTranscript
        self.deterministicTranscript = deterministicTranscript
        self.vocabulary = vocabulary
        self.formattingContext = formattingContext
        self.listFormattingHint = listFormattingHint
        self.clipboardContextPreview = clipboardContextPreview
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

struct LocalLLMResponse: Sendable {
    enum Outcome: String, Sendable {
        case unavailable
        case refined
        case unchanged
        case skipped
        case timedOut
        case failed
        case rejected
    }

    let transcript: String
    let proposedTranscript: String
    let outcome: Outcome
    let durationMs: Int
    let skipReason: LocalLLMSkipReason?
    let failureReason: LocalLLMFailureReason?
    let validationFailure: LocalLLMValidationFailureReason?
    let wasOutputAccepted: Bool
}

extension LocalLLMResponse {
    static func skipped(transcript: String, reason: LocalLLMSkipReason) -> LocalLLMResponse {
        LocalLLMResponse(
            transcript: transcript,
            proposedTranscript: transcript,
            outcome: .skipped,
            durationMs: 0,
            skipReason: reason,
            failureReason: nil,
            validationFailure: nil,
            wasOutputAccepted: false
        )
    }
}

enum LocalLLMValidationDecision: Equatable, Sendable {
    case accepted(String)
    case rejected(LocalLLMValidationFailureReason)
}

enum LocalLLMRequestEvaluator {
    static func skipReason(
        for request: LocalLLMRequest,
        isEnabled: Bool
    ) -> LocalLLMSkipReason? {
        guard isEnabled else {
            return .disabled
        }

        guard request.capability == .smartFormatting else {
            return .unsupportedCapability
        }

        let trimmedTranscript = request.deterministicTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return .shortTranscript
        }

        return nil
    }
}

/// Kept as a compatibility builder for tests and fallback tooling.
struct LocalLLMSmartFormattingPromptBuilder {
    let glossaryLimit: Int

    init(glossaryLimit: Int = 24) {
        self.glossaryLimit = glossaryLimit
    }

    func buildPrompt(for request: LocalLLMRequest) -> String {
        var sections: [String] = [
            "You are a deterministic local transcript smart-formatting assistant.",
            "Return only the final formatted transcript text. No labels and no commentary.",
            "Preserve meaning and keep the full textual content.",
            "Allowed changes: punctuation, capitalization, spacing, sentence boundaries, and casing of known terms.",
            "Do not replace, insert, delete, or reorder words from the deterministic corrected draft.",
            "Never paraphrase, summarize, reorder content, or invent words.",
            "Preserve file names, paths, URLs, code-like tokens, symbols, flags, and explicit identifiers exactly when they appear.",
            "If the draft already looks correct, return it unchanged.",
        ]

        sections.append("Formatting domain: \(request.formattingContext.domain.rawValue)")

        if !request.formattingContext.requiresCodeSyntaxPostEdit {
            switch request.listFormattingHint {
            case .none:
                break
            case .bulleted:
                sections.append("List formatting hint: convert clearly enumerated options into a vertical bulleted list using '- ' with one option per line.")
                sections.append("Preserve original option wording and order. Do not add, remove, or merge options.")
            case .numbered:
                sections.append("List formatting hint: convert clearly enumerated options into a vertical numbered list using '1. ', '2. ', etc., with one option per line.")
                sections.append("Preserve original option wording and order. Do not add, remove, or merge options.")
            }
        }

        if let clipboardContextPreview = request.clipboardContextPreview {
            sections.append("Clipboard context from before dictation (reference only; do not copy verbatim unless clearly relevant):")
            sections.append(clipboardContextPreview)
        }

        sections.append("")
        sections.append("Original ASR transcript:")
        sections.append(request.originalTranscript)
        sections.append("")
        sections.append("Deterministic corrected draft:")
        sections.append(request.deterministicTranscript)

        let glossaryEntries = CustomVocabularyManager.glossaryEntries(
            from: request.vocabulary,
            limit: glossaryLimit
        )
        if !glossaryEntries.isEmpty {
            sections.append("")
            sections.append("Preferred terms:")
            sections.append(contentsOf: glossaryEntries.map { entry in
                guard !entry.hints.isEmpty else {
                    return "- \(entry.preferred)"
                }
                return "- \(entry.preferred) <- \(entry.hints.joined(separator: ", "))"
            })
        }

        sections.append("")
        sections.append("Return only the formatted transcript text.")
        return sections.joined(separator: "\n")
    }
}

struct LocalLLMOutputValidator {
    private let engine = TranscriptValidationEngine()

    func validate(candidate: String, for request: LocalLLMRequest) -> LocalLLMValidationDecision {
        engine.validate(
            candidate: candidate,
            reference: request.deterministicTranscript,
            vocabulary: request.vocabulary,
            requiresCodeSyntaxPostEdit: request.formattingContext.requiresCodeSyntaxPostEdit,
            protectedSpans: []
        )
    }
}

actor LocalLLMCoordinator: LocalLLMServing {
    typealias SessionLoader = LLMRuntime.SessionLoader

    private struct ProcessingMetrics: Sendable {
        var requestCount = 0
        var refinedCount = 0
        var unchangedCount = 0
        var rejectedCount = 0
        var timeoutCount = 0
        var failedCount = 0

        mutating func observe(_ response: LocalLLMResponse) {
            requestCount += 1
            switch response.outcome {
            case .refined:
                refinedCount += 1
            case .unchanged:
                unchangedCount += 1
            case .rejected:
                rejectedCount += 1
            case .timedOut:
                timeoutCount += 1
            case .failed, .unavailable:
                failedCount += 1
            case .skipped:
                break
            }
        }
    }

    private let logger = AppLogger(category: "LocalLLMCoordinator")
    private let defaultTimeoutNanoseconds: UInt64 = 1_500_000_000
    private let preferenceLoader: @Sendable () -> Bool
    private let runtime: LLMRuntime
    private let constrainedPromptBuilder: ConstrainedFormattingPromptBuilder
    private let structuredResponseParser: StructuredResponseParser
    private let validationEngine: TranscriptValidationEngine

    private let correctionHistory = CorrectionHistoryStore()
    private let sentenceHistory = SentenceHistoryBuffer()
    private var metrics = ProcessingMetrics()

    init(
        promptBuilder _: LocalLLMSmartFormattingPromptBuilder = LocalLLMSmartFormattingPromptBuilder(),
        outputValidator _: LocalLLMOutputValidator = LocalLLMOutputValidator(),
        preferenceLoader: @escaping @Sendable () -> Bool = { LocalSmartFormattingPreference.load() },
        sessionLoader: SessionLoader? = nil,
        runtime: LLMRuntime? = nil,
        constrainedPromptBuilder: ConstrainedFormattingPromptBuilder = ConstrainedFormattingPromptBuilder(),
        structuredResponseParser: StructuredResponseParser = StructuredResponseParser(),
        validationEngine: TranscriptValidationEngine = TranscriptValidationEngine()
    ) {
        self.preferenceLoader = preferenceLoader
        if let runtime {
            self.runtime = runtime
        } else if let sessionLoader {
            self.runtime = LLMRuntime(sessionLoader: sessionLoader, loggerCategory: "LLMRuntime(Local)")
        } else {
            self.runtime = .shared
        }
        self.constrainedPromptBuilder = constrainedPromptBuilder
        self.structuredResponseParser = structuredResponseParser
        self.validationEngine = validationEngine
    }

    nonisolated static func isDefaultModelInstalled() -> Bool {
        LLMRuntime.isDefaultModelInstalled()
    }

    nonisolated static func requiredDownloadSizeIfMissing() async -> Int64? {
        await LLMRuntime.requiredDownloadSizeIfMissing()
    }

    nonisolated static func ensureDefaultModelAvailable(
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try await LLMRuntime.ensureDefaultModelAvailable(progressHandler: progressHandler)
    }

    nonisolated static func preloadModelInBackground() {
        LLMRuntime.preloadInBackgroundIfEnabled()
    }

    func prepareIfPossible() async {
        guard preferenceLoader() else {
            return
        }

        do {
            try await runtime.prepareIfPossible()
        } catch {
            logger.debug("LLM prepareIfPossible failed: \(error.localizedDescription)")
        }
    }

    func handleMemoryPressure(level: LocalLLMMemoryPressureLevel) async {
        await runtime.handleMemoryPressure(level: level)
    }

    func process(_ request: LocalLLMRequest) async -> LocalLLMResponse {
        let startedAt = ContinuousClock.now
        let deterministicTranscript = request.deterministicTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEnabled = preferenceLoader()

        if let skipReason = LocalLLMRequestEvaluator.skipReason(
            for: request,
            isEnabled: isEnabled
        ) {
            let response = LocalLLMResponse.skipped(transcript: deterministicTranscript, reason: skipReason)
            observe(response)
            return response
        }

        let timeoutNanoseconds = request.timeoutNanoseconds ?? defaultTimeoutNanoseconds
        let extendedContext = await buildExtendedContext(for: request)
        let prompt = constrainedPromptBuilder.buildPrompt(for: request, extendedContext: extendedContext)

        let generationResult = await runtime.generate(
            prompt: prompt,
            timeoutNanoseconds: timeoutNanoseconds
        )

        let response: LocalLLMResponse
        switch generationResult {
        case .success(let rawResponse):
            response = await handleGenerationSuccess(
                rawResponse: rawResponse,
                deterministicTranscript: deterministicTranscript,
                request: request,
                extendedContext: extendedContext,
                startedAt: startedAt
            )
        case .timedOut:
            logger.debug("Local smart-formatting timed out after \(elapsedMs(since: startedAt))ms")
            response = makeResponse(
                transcript: deterministicTranscript,
                outcome: .timedOut,
                startedAt: startedAt,
                wasOutputAccepted: false
            )
        case .failed(let error):
            logger.debug("Local smart-formatting failed: \(error.localizedDescription)")
            response = makeResponse(
                transcript: deterministicTranscript,
                outcome: .failed,
                startedAt: startedAt,
                failureReason: .generationFailed,
                wasOutputAccepted: false
            )
        }

        observe(response)
        return response
    }

    func recordCorrection(source: String, target: String) async {
        await correctionHistory.recordCorrection(source: source, target: target)
    }

    func addSentenceToHistory(_ sentence: String) async {
        await sentenceHistory.addSentence(sentence)
    }

    func clearHistory() async {
        await correctionHistory.clear()
        await sentenceHistory.clear()
    }

    func getCorrectionHistory() async -> [LearnedCorrection] {
        await correctionHistory.allCorrections()
    }

    private func handleGenerationSuccess(
        rawResponse: String,
        deterministicTranscript: String,
        request: LocalLLMRequest,
        extendedContext: ExtendedFormattingContext,
        startedAt: ContinuousClock.Instant
    ) async -> LocalLLMResponse {
        let sanitizedResponse = sanitize(rawResponse)
        if let structured = structuredResponseParser.parse(sanitizedResponse) {
            return await responseFromValidation(
                decision: validationEngine.validate(
                    candidate: structured.finalText,
                    reference: deterministicTranscript,
                    vocabulary: request.vocabulary,
                    requiresCodeSyntaxPostEdit: request.formattingContext.requiresCodeSyntaxPostEdit,
                    protectedSpans: extendedContext.protectedSpans
                ),
                proposed: structured.finalText,
                deterministicTranscript: deterministicTranscript,
                startedAt: startedAt
            )
        }

        logger.debug("Local smart-formatting produced invalid JSON output contract")
        return makeResponse(
            transcript: deterministicTranscript,
            proposedTranscript: deterministicTranscript,
            outcome: .failed,
            startedAt: startedAt,
            failureReason: .invalidOutput,
            wasOutputAccepted: false
        )
    }

    private func responseFromValidation(
        decision: LocalLLMValidationDecision,
        proposed: String,
        deterministicTranscript: String,
        startedAt: ContinuousClock.Instant
    ) async -> LocalLLMResponse {
        switch decision {
        case .accepted(let acceptedTranscript):
            let outcome: LocalLLMResponse.Outcome = acceptedTranscript == deterministicTranscript
                ? .unchanged
                : .refined
            if outcome == .refined {
                await sentenceHistory.addSentence(acceptedTranscript)
            }
            return makeResponse(
                transcript: acceptedTranscript,
                proposedTranscript: proposed,
                outcome: outcome,
                startedAt: startedAt,
                wasOutputAccepted: true
            )
        case .rejected(let reason):
            if looksLikePromptInstructionEcho(
                proposed: proposed,
                reference: deterministicTranscript
            ) {
                logger.debug("Local smart-formatting rejected prompt-instruction echo as invalid output")
                return makeResponse(
                    transcript: deterministicTranscript,
                    proposedTranscript: deterministicTranscript,
                    outcome: .failed,
                    startedAt: startedAt,
                    failureReason: .invalidOutput,
                    wasOutputAccepted: false
                )
            }

            return makeResponse(
                transcript: deterministicTranscript,
                proposedTranscript: proposed,
                outcome: .rejected,
                startedAt: startedAt,
                validationFailure: reason,
                wasOutputAccepted: false
            )
        }
    }

    private func buildExtendedContext(for request: LocalLLMRequest) async -> ExtendedFormattingContext {
        let previousSentences = await sentenceHistory.recentSentences(count: 2)
        let corrections = await correctionHistory.relevantCorrections(for: request.deterministicTranscript)
        let stylePreferences = FormattingStylePreferences.load()
        let protectedSpans = ProtectedSpanDetector().detectProtectedSpans(in: request.deterministicTranscript)

        return ExtendedFormattingContext(
            formattingContext: request.formattingContext,
            previousSentences: Array(previousSentences.prefix(2)),
            recentCorrections: Array(corrections.prefix(4)),
            stylePreferences: stylePreferences,
            protectedSpans: protectedSpans,
            clipboardPreview: cappedClipboardPreview(request.clipboardContextPreview)
        )
    }

    private func cappedClipboardPreview(_ preview: String?) -> String? {
        guard let preview else { return nil }
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let maxLength = 220
        guard trimmed.count > maxLength else { return trimmed }

        let end = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<end]) + " [truncated]"
    }

    private func makeResponse(
        transcript: String,
        proposedTranscript: String? = nil,
        outcome: LocalLLMResponse.Outcome,
        startedAt: ContinuousClock.Instant,
        skipReason: LocalLLMSkipReason? = nil,
        failureReason: LocalLLMFailureReason? = nil,
        validationFailure: LocalLLMValidationFailureReason? = nil,
        wasOutputAccepted: Bool
    ) -> LocalLLMResponse {
        LocalLLMResponse(
            transcript: transcript,
            proposedTranscript: proposedTranscript ?? transcript,
            outcome: outcome,
            durationMs: elapsedMs(since: startedAt),
            skipReason: skipReason,
            failureReason: failureReason,
            validationFailure: validationFailure,
            wasOutputAccepted: wasOutputAccepted
        )
    }

    private func looksLikePromptInstructionEcho(proposed: String, reference: String) -> Bool {
        let normalizedProposed = proposed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedProposed.isEmpty else { return false }

        let indicators = [
            "you may rewrite wording to improve clarity",
            "you may rephrase when needed to fix likely asr wording errors",
            "recover likely intended meaning from asr mistakes",
            "do not copy instruction text into final_text",
            "return one valid json object with exactly one key",
            "no markdown. no extra keys. no extra text",
            "{\"final_text\":\"...\"}"
        ]

        let hasPromptArtifact = indicators.contains { indicator in
            normalizedProposed.contains(indicator)
        }
        guard hasPromptArtifact else { return false }

        return !indicators.contains { indicator in
            normalizedReference.contains(indicator)
        }
    }

    private func observe(_ response: LocalLLMResponse) {
        metrics.observe(response)

        guard metrics.requestCount % 20 == 0 else {
            return
        }

        logger.info(
            "LLM final-pass metrics requests=\(metrics.requestCount) refined=\(metrics.refinedCount) unchanged=\(metrics.unchangedCount) rejected=\(metrics.rejectedCount) timedOut=\(metrics.timeoutCount) failed=\(metrics.failedCount)"
        )
    }

    private func elapsedMs(since startedAt: ContinuousClock.Instant) -> Int {
        let duration = startedAt.duration(to: ContinuousClock.now).components
        return Int(duration.seconds * 1_000) + Int(duration.attoseconds / 1_000_000_000_000_000)
    }

    private func sanitize(_ text: String) -> String {
        let normalizedLineBreaks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let collapsedHorizontalWhitespace = normalizedLineBreaks
            .replacingOccurrences(of: #"[^\S\n]+"#, with: " ", options: .regularExpression)
        let trimmedLineEdgeWhitespace = collapsedHorizontalWhitespace
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
        let collapsedBlankLines = trimmedLineEdgeWhitespace
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wrappingCharacters = CharacterSet(charactersIn: "\"'`")
        return collapsedBlankLines.trimmingCharacters(in: wrappingCharacters)
    }

}
