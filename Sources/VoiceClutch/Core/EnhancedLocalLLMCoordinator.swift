import Foundation

#if canImport(MLXLLM)
import MLXLLM
#endif
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif

/// Enhanced LLM coordinator with JSON-structured responses and edit tracking
actor EnhancedLocalLLMCoordinator: LocalLLMServing {
    typealias SessionLoader = @Sendable () async throws -> any LocalLLMGeneratingSession

    private static let defaultModelIdentifier = "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit"
    private static var defaultModelDirectory: URL {
        defaultModelIdentifier
            .split(separator: "/")
            .reduce(ModelDownloadManager.modelsRootDirectory) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    private let logger = AppLogger(category: "EnhancedLocalLLM")
    private let defaultTimeoutNanoseconds: UInt64 = 1_500_000_000
    private let fallbackCoordinator: LocalLLMCoordinator

    private let promptBuilder: ConstrainedFormattingPromptBuilder
    private let responseParser: StructuredResponseParser
    private let responseValidator: StructuredResponseValidator
    private let preferenceLoader: @Sendable () -> Bool
    private let sessionLoader: SessionLoader
    private var cachedSession: (any LocalLLMGeneratingSession)?
    private var loadingSessionTask: Task<any LocalLLMGeneratingSession, Error>?

    // Context stores
    private let correctionHistory = CorrectionHistoryStore()
    private let sentenceHistory = SentenceHistoryBuffer()

    init(
        promptBuilder: ConstrainedFormattingPromptBuilder = ConstrainedFormattingPromptBuilder(),
        responseParser: StructuredResponseParser = StructuredResponseParser(),
        responseValidator: StructuredResponseValidator = StructuredResponseValidator(),
        preferenceLoader: @escaping @Sendable () -> Bool = { LocalSmartFormattingPreference.load() },
        sessionLoader: SessionLoader? = nil
    ) {
        self.promptBuilder = promptBuilder
        self.responseParser = responseParser
        self.responseValidator = responseValidator
        self.preferenceLoader = preferenceLoader
        self.sessionLoader = sessionLoader ?? Self.makeDefaultSessionLoader()
        self.fallbackCoordinator = LocalLLMCoordinator()
    }

    // MARK: - Public API

    func prepareIfPossible() async {
        guard preferenceLoader() else { return }
        _ = try? await ensureSessionAvailable()
    }

    func process(_ request: LocalLLMRequest) async -> LocalLLMResponse {
        let startedAt = ContinuousClock.now
        let deterministicTranscript = request.deterministicTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEnabled = preferenceLoader()

        if let skipReason = LocalLLMRequestEvaluator.skipReason(
            for: request,
            isEnabled: isEnabled
        ) {
            return .skipped(transcript: deterministicTranscript, reason: skipReason)
        }

        // Build extended context
        let extendedContext = await buildExtendedContext(for: request)

        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        let prompt = promptBuilder.buildPrompt(for: request, extendedContext: extendedContext)
        let timeoutNanoseconds = request.timeoutNanoseconds ?? defaultTimeoutNanoseconds

        do {
            let session = try await ensureSessionAvailable()
            let generationResult = await generateResponse(
                prompt: prompt,
                session: session,
                timeoutNanoseconds: timeoutNanoseconds
            )

            switch generationResult {
            case .success(let rawResponse):
                let result = await handleSuccessfulResponse(
                    raw: rawResponse,
                    deterministic: deterministicTranscript,
                    request: request,
                    startedAt: startedAt
                )

                // Track successful sentence in history
                if case .refined = result.outcome {
                    await sentenceHistory.addSentence(result.transcript)
                }

                return result

            case .timedOut:
                logger.debug("Enhanced LLM timed out after \(elapsedMs(since: startedAt))ms")
                return makeResponse(
                    transcript: deterministicTranscript,
                    outcome: .timedOut,
                    startedAt: startedAt,
                    wasOutputAccepted: false
                )

            case .failed(let error):
                logger.debug("Enhanced LLM failed: \(error.localizedDescription)")

                // Fall back to original coordinator
                let fallbackResult = await fallbackCoordinator.process(request)
                logFallback(result: fallbackResult, startedAt: startedAt)
                return fallbackResult
            }
        } catch {
            logger.debug("Enhanced LLM unavailable: \(error.localizedDescription)")

            // Fall back to original coordinator
            let fallbackResult = await fallbackCoordinator.process(request)
            logFallback(result: fallbackResult, startedAt: startedAt)
            return fallbackResult
        }
        #else
        return await fallbackCoordinator.process(request)
        #endif
    }

    // MARK: - Context Management

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

    // MARK: - Private

    private func buildExtendedContext(for request: LocalLLMRequest) async -> ExtendedFormattingContext {
        let previousSentences = await sentenceHistory.recentSentences(count: 3)
        let recentCorrections = await correctionHistory.relevantCorrections(for: request.deterministicTranscript)
        let stylePreferences = FormattingStylePreferences.load()
        let protectedSpans = ProtectedSpanDetector().detectProtectedSpans(in: request.deterministicTranscript)

        return ExtendedFormattingContext(
            formattingContext: request.formattingContext,
            previousSentences: previousSentences,
            recentCorrections: recentCorrections,
            stylePreferences: stylePreferences,
            protectedSpans: protectedSpans
        )
    }

    private func handleSuccessfulResponse(
        raw: String,
        deterministic: String,
        request: LocalLLMRequest,
        startedAt: ContinuousClock.Instant
    ) async -> LocalLLMResponse {
        // Try to parse as structured JSON response
        if let structured = responseParser.parse(raw) {
            let decision = responseValidator.validate(
                response: structured,
                original: deterministic,
                vocabulary: request.vocabulary
            )

            switch decision {
            case .accepted(let acceptedText):
                let outcome: LocalLLMResponse.Outcome = acceptedText == deterministic
                    ? .unchanged
                    : .refined

                logger.debug(
                    "Structured LLM response accepted: \(structured.edits.count) edits, outcome=\(outcome.rawValue)"
                )

                return makeResponse(
                    transcript: acceptedText,
                    outcome: outcome,
                    startedAt: startedAt,
                    wasOutputAccepted: true
                )

            case .rejected(let reason):
                logger.debug(
                    "Structured LLM response rejected: \(reason.rawValue), edits=\(structured.edits.count)"
                )

                // Try to apply only safe edits (punctuation-only)
                if let safeResult = applySafeEdits(from: structured, to: deterministic) {
                    return makeResponse(
                        transcript: safeResult,
                        outcome: .refined,
                        startedAt: startedAt,
                        wasOutputAccepted: true
                    )
                }

                return makeResponse(
                    transcript: deterministic,
                    outcome: .rejected,
                    startedAt: startedAt,
                    validationFailure: reason,
                    wasOutputAccepted: false
                )
            }
        }

        // Fall back to treating raw response as plain text
        let sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return makeResponse(
                transcript: deterministic,
                outcome: .rejected,
                startedAt: startedAt,
                validationFailure: .emptyOutput,
                wasOutputAccepted: false
            )
        }

        // Validate as plain text response
        let plainDecision = responseValidator.validate(
            response: StructuredFormattingResponse(finalText: sanitized, edits: []),
            original: deterministic,
            vocabulary: request.vocabulary
        )

        switch plainDecision {
        case .accepted(let accepted):
            return makeResponse(
                transcript: accepted,
                outcome: accepted == deterministic ? .unchanged : .refined,
                startedAt: startedAt,
                wasOutputAccepted: true
            )
        case .rejected(let reason):
            return makeResponse(
                transcript: deterministic,
                outcome: .rejected,
                startedAt: startedAt,
                validationFailure: reason,
                wasOutputAccepted: false
            )
        }
    }

    private func applySafeEdits(from structured: StructuredFormattingResponse, to original: String) -> String? {
        // Extract only punctuation/capitalization/spacing edits
        let safeEdits = structured.edits.filter { edit in
            edit.reason == .punctuation ||
            edit.reason == .capitalization ||
            edit.reason == .spacing
        }

        guard !safeEdits.isEmpty else { return nil }

        // Apply edits
        let applier = TranscriptDiffApplier()
        let result = applier.applyEdits(safeEdits, to: original)

        // Verify the result is safe
        let resultTokens = normalizedWordTokens(from: result)
        let originalTokens = normalizedWordTokens(from: original)

        guard resultTokens == originalTokens else { return nil }

        return result
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private enum TimedGenerationResult {
        case success(String)
        case timedOut
        case failed(Error)
    }

    private func generateResponse(
        prompt: String,
        session: any LocalLLMGeneratingSession,
        timeoutNanoseconds: UInt64
    ) async -> TimedGenerationResult {
        await withTaskGroup(of: TimedGenerationResult.self) { group in
            group.addTask {
                do {
                    return .success(try await session.respond(to: prompt))
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }

            let firstResult = await group.next() ?? .timedOut
            group.cancelAll()
            return firstResult
        }
    }
    #endif

    private func ensureSessionAvailable() async throws -> any LocalLLMGeneratingSession {
        if let cachedSession {
            return cachedSession
        }

        if let loadingSessionTask {
            return try await loadingSessionTask.value
        }

        let sessionLoader = self.sessionLoader
        let loadTask = Task<any LocalLLMGeneratingSession, Error> {
            try await sessionLoader()
        }
        loadingSessionTask = loadTask

        do {
            let loadedSession = try await loadTask.value
            cachedSession = loadedSession
            loadingSessionTask = nil
            return loadedSession
        } catch {
            loadingSessionTask = nil
            throw error
        }
    }

    private func makeResponse(
        transcript: String,
        outcome: LocalLLMResponse.Outcome,
        startedAt: ContinuousClock.Instant,
        skipReason: LocalLLMSkipReason? = nil,
        failureReason: LocalLLMFailureReason? = nil,
        validationFailure: LocalLLMValidationFailureReason? = nil,
        wasOutputAccepted: Bool
    ) -> LocalLLMResponse {
        LocalLLMResponse(
            transcript: transcript,
            outcome: outcome,
            durationMs: elapsedMs(since: startedAt),
            skipReason: skipReason,
            failureReason: failureReason,
            validationFailure: validationFailure,
            wasOutputAccepted: wasOutputAccepted
        )
    }

    private func elapsedMs(since startedAt: ContinuousClock.Instant) -> Int {
        let duration = startedAt.duration(to: ContinuousClock.now).components
        return Int(duration.seconds * 1_000) + Int(duration.attoseconds / 1_000_000_000_000_000)
    }

    private func logFallback(result: LocalLLMResponse, startedAt: ContinuousClock.Instant) {
        logger.debug(
            "Using fallback LLM coordinator: outcome=\(result.outcome.rawValue), duration=\(elapsedMs(since: startedAt))ms"
        )
    }

    // MARK: - Static

    private static func makeDefaultSessionLoader() -> SessionLoader {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return {
            let modelDirectory = try await Self.ensureDefaultModelAvailable()
            let model = try await loadModel(directory: modelDirectory)
            return MLXChatSessionAdapter(session: ChatSession(model))
        }
        #else
        return {
            struct UnavailableError: LocalizedError {
                var errorDescription: String? {
                    "Local LLM runtime is unavailable."
                }
            }
            throw UnavailableError()
        }
        #endif
    }

    private static func modelArtifactsExist(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }

        let requiredFiles = [
            "config.json",
            "tokenizer.json",
        ]
        guard requiredFiles.allSatisfy({ fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
            return false
        }

        let denseWeights = directory.appendingPathComponent("model.safetensors")
        let shardedWeights = directory.appendingPathComponent("model.safetensors.index.json")
        return fileManager.fileExists(atPath: denseWeights.path) || fileManager.fileExists(atPath: shardedWeights.path)
    }

    nonisolated static func isDefaultModelInstalled() -> Bool {
        modelArtifactsExist(at: defaultModelDirectory)
    }

    nonisolated static func requiredDownloadSizeIfMissing() async -> Int64? {
        await LocalLLMCoordinator.requiredDownloadSizeIfMissing()
    }

    nonisolated static func ensureDefaultModelAvailable(
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try await LocalLLMCoordinator.ensureDefaultModelAvailable(progressHandler: progressHandler)
    }
}
