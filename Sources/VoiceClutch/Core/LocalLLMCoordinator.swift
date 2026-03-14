import Foundation

#if canImport(MLXLLM)
import MLXLLM
#endif
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif
#if canImport(Hub)
import Hub
#endif

protocol LocalLLMServing: Sendable {
    func prepareIfPossible() async
    func process(_ request: LocalLLMRequest) async -> LocalLLMResponse
}

protocol LocalLLMGeneratingSession: Sendable {
    func respond(to prompt: String) async throws -> String
}

#if canImport(MLXLLM) && canImport(MLXLMCommon)
/// Thread-safe adapter for MLX ChatSession.
/// Uses a serial queue to ensure only one call to ChatSession.respond is active at a time.
/// MLX's ChatSession is not thread-safe and requires serialized access.
final class MLXChatSessionAdapter: @unchecked Sendable, LocalLLMGeneratingSession {
    private let session: ChatSession
    private let serialQueue: DispatchQueue

    init(session: ChatSession) {
        self.session = session
        // Use a serial queue to serialize all access to the session
        self.serialQueue = DispatchQueue(label: "dev.vm.voiceclutch.mlx-chat-adapter", qos: .userInitiated)
    }

    func respond(to prompt: String) async throws -> String {
        // Run the MLX call on the main thread to avoid CPU/SIMD detection issues
        // MLX may need to execute on the main thread for proper Metal/CPU feature detection
        try await withCheckedThrowingContinuation { continuation in
            serialQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // Hop to main thread for the actual MLX call
                DispatchQueue.main.async {
                    Task.detached(priority: .userInitiated) { [session = self.session] in
                        do {
                            let result = try await session.respond(to: prompt)
                            continuation.resume(returning: result)
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
    let timeoutNanoseconds: UInt64?

    init(
        capability: LocalLLMCapability,
        originalTranscript: String,
        deterministicTranscript: String,
        vocabulary: CustomVocabularySnapshot,
        formattingContext: TranscriptFormattingContext,
        timeoutNanoseconds: UInt64? = nil
    ) {
        self.capability = capability
        self.originalTranscript = originalTranscript
        self.deterministicTranscript = deterministicTranscript
        self.vocabulary = vocabulary
        self.formattingContext = formattingContext
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

struct LocalLLMSmartFormattingPromptBuilder {
    let glossaryLimit: Int

    init(glossaryLimit: Int = 24) {
        self.glossaryLimit = glossaryLimit
    }

    func buildPrompt(for request: LocalLLMRequest) -> String {
        var sections: [String] = [
            "You are a deterministic local transcript smart-formatting assistant.",
            "Return only the final formatted transcript text. No markdown, no labels, and no commentary.",
            "Preserve meaning and keep the full textual content.",
            "Allowed changes: punctuation, capitalization, spacing, sentence boundaries, and casing of known terms.",
            "Do not replace, insert, delete, or reorder words from the deterministic corrected draft.",
            "Never paraphrase, summarize, reorder content, or invent words.",
            "Preserve file names, paths, URLs, code-like tokens, symbols, flags, and explicit identifiers exactly when they appear.",
            "If the draft already looks correct, return it unchanged.",
        ]

        if let appName = request.formattingContext.appName {
            sections.append("Frontmost app: \(appName)")
        }
        if let bundleIdentifier = request.formattingContext.bundleIdentifier {
            sections.append("Frontmost bundle id: \(bundleIdentifier)")
        }
        sections.append("Formatting domain: \(request.formattingContext.domain.rawValue)")

        switch request.formattingContext.domain {
        case .code, .terminal:
            sections.append("Be extra conservative. Prefer leaving text untouched over risking corruption of literals or commands.")
        case .messaging:
            sections.append("Keep the result lightweight and natural for chat-style writing.")
        case .documents, .email:
            sections.append("Favor clean sentence boundaries and standard prose punctuation.")
        case .general:
            break
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
    func validate(candidate: String, for request: LocalLLMRequest) -> LocalLLMValidationDecision {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let deterministicTranscript = request.deterministicTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTokens = normalizedWordTokens(from: trimmedCandidate)
        let referenceTokens = normalizedWordTokens(from: deterministicTranscript)

        guard !trimmedCandidate.isEmpty else {
            return .rejected(.emptyOutput)
        }

        if candidateTokens == referenceTokens {
            return .accepted(trimmedCandidate)
        }

        if dropsTooMuchContent(candidate: trimmedCandidate, reference: deterministicTranscript) {
            return .rejected(.droppedContent)
        }

        if changesProtectedTerms(candidate: trimmedCandidate, request: request) {
            return .rejected(.protectedTermsChanged)
        }

        if isExcessiveRewrite(candidate: trimmedCandidate, reference: deterministicTranscript) {
            return .rejected(.excessiveRewrite)
        }

        return .rejected(.wordingChanged)
    }

    private func dropsTooMuchContent(candidate: String, reference: String) -> Bool {
        let candidateTokens = normalizedWordTokens(from: candidate)
        let referenceTokens = normalizedWordTokens(from: reference)
        guard !referenceTokens.isEmpty else { return false }

        var candidateIndex = 0
        var matchedCount = 0

        for referenceToken in referenceTokens {
            while candidateIndex < candidateTokens.count {
                if candidateTokens[candidateIndex] == referenceToken {
                    matchedCount += 1
                    candidateIndex += 1
                    break
                }
                candidateIndex += 1
            }
        }

        let missingCount = referenceTokens.count - matchedCount
        let allowedMissingCount = max(0, referenceTokens.count / 12)
        return missingCount > allowedMissingCount
    }

    private func changesProtectedTerms(candidate: String, request: LocalLLMRequest) -> Bool {
        let candidateTokens = normalizedWordTokens(from: candidate)
        let referenceTokens = normalizedWordTokens(from: request.deterministicTranscript)

        for entry in CustomVocabularyManager.glossaryEntries(from: request.vocabulary, limit: 24) {
            let preferredTokens = normalizedWordTokens(from: entry.preferred)
            guard !preferredTokens.isEmpty else { continue }
            guard containsPhrase(preferredTokens, in: referenceTokens) else { continue }
            guard containsPhrase(preferredTokens, in: candidateTokens) else {
                return true
            }
        }

        return false
    }

    private func isExcessiveRewrite(candidate: String, reference: String) -> Bool {
        if normalizedLookupKey(candidate) == normalizedLookupKey(reference) {
            return false
        }

        let candidateCollapsed = collapsedTokenKey(candidate)
        let referenceCollapsed = collapsedTokenKey(reference)
        guard !candidateCollapsed.isEmpty, !referenceCollapsed.isEmpty else {
            return true
        }

        let distance = editDistance(candidateCollapsed, referenceCollapsed)
        let maxLength = max(candidateCollapsed.count, referenceCollapsed.count)
        let allowedDistance = max(2, maxLength / 10)
        return distance > allowedDistance
    }

    private func containsPhrase(_ phraseTokens: [String], in tokens: [String]) -> Bool {
        guard !phraseTokens.isEmpty, phraseTokens.count <= tokens.count else {
            return false
        }

        for index in 0...(tokens.count - phraseTokens.count) where Array(tokens[index..<(index + phraseTokens.count)]) == phraseTokens {
            return true
        }

        return false
    }

    private func normalizedLookupKey(_ text: String) -> String {
        CustomVocabularyManager.normalizedLookupKey(text)
    }

    private func collapsedTokenKey(_ text: String) -> String {
        text.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs {
            return 0
        }
        if lhs.isEmpty {
            return rhs.count
        }
        if rhs.isEmpty {
            return lhs.count
        }

        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        var previousRow = Array(0...rhsCharacters.count)
        var currentRow = Array(repeating: 0, count: rhsCharacters.count + 1)

        for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
            currentRow[0] = lhsIndex + 1

            for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
                let substitutionCost = lhsCharacter == rhsCharacter ? 0 : 1
                currentRow[rhsIndex + 1] = min(
                    previousRow[rhsIndex + 1] + 1,
                    currentRow[rhsIndex] + 1,
                    previousRow[rhsIndex] + substitutionCost
                )
            }

            swap(&previousRow, &currentRow)
        }

        return previousRow[rhsCharacters.count]
    }
}

actor LocalLLMCoordinator: LocalLLMServing {
    typealias SessionLoader = @Sendable () async throws -> any LocalLLMGeneratingSession

    private static let defaultModelIdentifier = "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit"
    private static var defaultModelDirectory: URL {
        defaultModelIdentifier
            .split(separator: "/")
            .reduce(ModelDownloadManager.modelsRootDirectory) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    private let logger = AppLogger(category: "LocalLLMCoordinator")
    private let defaultTimeoutNanoseconds: UInt64 = 1_500_000_000
    private let promptBuilder: LocalLLMSmartFormattingPromptBuilder
    private let outputValidator: LocalLLMOutputValidator
    private let preferenceLoader: @Sendable () -> Bool
    private let sessionLoader: SessionLoader
    private var cachedSession: (any LocalLLMGeneratingSession)?
    private var loadingSessionTask: Task<any LocalLLMGeneratingSession, Error>?

    init(
        promptBuilder: LocalLLMSmartFormattingPromptBuilder = LocalLLMSmartFormattingPromptBuilder(),
        outputValidator: LocalLLMOutputValidator = LocalLLMOutputValidator(),
        preferenceLoader: @escaping @Sendable () -> Bool = { LocalSmartFormattingPreference.load() },
        sessionLoader: SessionLoader? = nil
    ) {
        self.promptBuilder = promptBuilder
        self.outputValidator = outputValidator
        self.preferenceLoader = preferenceLoader
        self.sessionLoader = sessionLoader ?? Self.makeDefaultSessionLoader()
    }

    nonisolated static func isDefaultModelInstalled() -> Bool {
        modelArtifactsExist(at: defaultModelDirectory)
    }

    nonisolated static func requiredDownloadSizeIfMissing() async -> Int64? {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Hub)
        if isDefaultModelInstalled() {
            return 0
        }

        do {
            let metadata = try await HubApi(downloadBase: ModelDownloadManager.appSupportDirectory)
                .getFileMetadata(from: defaultModelIdentifier)
            return metadata.reduce(0) { partial, entry in
                partial + Int64(max(entry.size ?? 0, 0))
            }
        } catch {
            return nil
        }
        #else
        return 0
        #endif
    }

    nonisolated static func ensureDefaultModelAvailable(
        progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Hub)
        try FileManager.default.createDirectory(
            at: ModelDownloadManager.modelsRootDirectory,
            withIntermediateDirectories: true
        )

        if modelArtifactsExist(at: defaultModelDirectory) {
            progressHandler(1.0)
            return defaultModelDirectory
        }

        progressHandler(0.0)
        let hub = HubApi(downloadBase: ModelDownloadManager.appSupportDirectory)
        let downloadedRepoDirectory = try await hub.snapshot(from: defaultModelIdentifier) { progress in
            progressHandler(clampedProgress(progress.fractionCompleted))
        }
        progressHandler(1.0)
        return downloadedRepoDirectory
        #else
        struct UnavailableError: LocalizedError {
            var errorDescription: String? {
                "Local LLM runtime is unavailable."
            }
        }
        throw UnavailableError()
        #endif
    }

    /// Preloads the LLM model in the background for faster first use.
    /// Does not fail if the model cannot be loaded - it will be retried on demand.
    nonisolated static func preloadModelInBackground() {
        let shouldPreload = LocalSmartFormattingPreference.shouldPreloadAtStartup()

        guard shouldPreload else {
            return
        }

        guard LocalSmartFormattingPreference.load() else {
            // Smart formatting is disabled, no need to preload
            return
        }

        // Start preload in background without blocking
        Task.detached(priority: .utility) {
            let logger = AppLogger(category: "LocalLLMCoordinator")
            let startTime = ContinuousClock.now

            #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Hub)
            do {
                // Ensure model is downloaded
                _ = try await Self.ensureDefaultModelAvailable { _ in }

                // Load the model
                let modelDirectory = Self.defaultModelDirectory
                logger.info("Loading LLM model from \(modelDirectory.path)")
                let model = try await loadModel(directory: modelDirectory)
                let loadDuration = startTime.duration(to: ContinuousClock.now).components.seconds
                logger.info("LLM model loaded successfully in \(loadDuration)s")

                // Warmup: run a dummy inference to initialize computation graph
                logger.info("Warming up LLM model...")
                let warmupStart = ContinuousClock.now
                let session = ChatSession(model)
                _ = try await session.respond(to: "OK")
                let warmupDuration = warmupStart.duration(to: ContinuousClock.now).components.seconds
                logger.info("LLM model warmup completed in \(warmupDuration)s")
            } catch {
                logger.debug("LLM model preload failed: \(error.localizedDescription)")
                // Don't fail - model will load on-demand when needed
            }
            #else
            logger.debug("LLM model preload skipped: MLX runtime unavailable")
            #endif
        }
    }

    func prepareIfPossible() async {
        guard preferenceLoader() else {
            return
        }

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

        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        let prompt = promptBuilder.buildPrompt(for: request)
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
                let sanitizedResponse = sanitize(rawResponse)
                let promptLeakageStripped = stripPromptLeakageArtifacts(from: sanitizedResponse)
                let nonEmptyCandidate = promptLeakageStripped.isEmpty
                    ? deterministicTranscript
                    : promptLeakageStripped
                let candidateResponse = recoverTruncatedSuffix(
                    from: nonEmptyCandidate,
                    reference: deterministicTranscript
                )
                switch outputValidator.validate(candidate: candidateResponse, for: request) {
                case .accepted(let acceptedTranscript):
                    let outcome: LocalLLMResponse.Outcome = acceptedTranscript == deterministicTranscript
                        ? .unchanged
                        : .refined
                    return makeResponse(
                        transcript: acceptedTranscript,
                        outcome: outcome,
                        startedAt: startedAt,
                        wasOutputAccepted: true
                    )
                case .rejected(let reason):
                    logger.debug(
                        "Local smart-formatting output rejected: \(reason.rawValue) after \(elapsedMs(since: startedAt))ms"
                    )
                    return makeResponse(
                        transcript: deterministicTranscript,
                        outcome: .rejected,
                        startedAt: startedAt,
                        validationFailure: reason,
                        wasOutputAccepted: false
                    )
                }
            case .timedOut:
                logger.debug("Local smart-formatting timed out after \(elapsedMs(since: startedAt))ms")
                return makeResponse(
                    transcript: deterministicTranscript,
                    outcome: .timedOut,
                    startedAt: startedAt,
                    wasOutputAccepted: false
                )
            case .failed(let error):
                logger.debug("Local smart-formatting failed: \(error.localizedDescription)")
                return makeResponse(
                    transcript: deterministicTranscript,
                    outcome: .failed,
                    startedAt: startedAt,
                    failureReason: .generationFailed,
                    wasOutputAccepted: false
                )
            }
        } catch {
            logger.debug("Local smart-formatting model unavailable: \(error.localizedDescription)")
            return makeResponse(
                transcript: deterministicTranscript,
                outcome: .unavailable,
                startedAt: startedAt,
                failureReason: .modelLoadFailed,
                wasOutputAccepted: false
            )
        }
        #else
        return makeResponse(
            transcript: deterministicTranscript,
            outcome: .unavailable,
            startedAt: startedAt,
            failureReason: .unavailable,
            wasOutputAccepted: false
        )
        #endif
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
        // TEMPORARY: Disable timeout to isolate crash issue
        // The timeout mechanism with TaskGroup may be causing issues with MLX's internal state
        do {
            let response = try await session.respond(to: prompt)
            return .success(response)
        } catch {
            return .failed(error)
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

    private func sanitize(_ text: String) -> String {
        let collapsedWhitespace = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let wrappingCharacters = CharacterSet(charactersIn: "\"'`")
        return collapsedWhitespace.trimmingCharacters(in: wrappingCharacters)
    }

    private func stripPromptLeakageArtifacts(from text: String) -> String {
        let markers = [
            "Preferred terms:",
            "Original ASR transcript:",
            "Deterministic corrected draft:",
            "Return only the formatted transcript text.",
            "Frontmost app:",
            "Frontmost bundle id:",
            "Formatting domain:",
        ]

        var stripped = text
        for marker in markers {
            if let markerRange = stripped.range(of: marker, options: [.caseInsensitive]) {
                stripped = String(stripped[..<markerRange.lowerBound])
            }
        }

        // Remove accidental glossary bullet tails if they survived marker trimming.
        let filteredLines = stripped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return true }
                return trimmed.range(
                    of: #"^-\s+.+\s+<-\s+.+"#,
                    options: .regularExpression
                ) == nil
            }

        return filteredLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recoverTruncatedSuffix(from response: String, reference: String) -> String {
        let responseWords = normalizedWordTokens(from: response)
        guard !responseWords.isEmpty else { return response }

        let referenceWords = normalizedWordTokens(from: reference)
        guard referenceWords.count > responseWords.count else { return response }
        guard referenceWords.starts(with: responseWords) else { return response }

        let referenceRawWords = reference
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard referenceRawWords.count > responseWords.count else { return response }

        let missingSuffix = referenceRawWords
            .dropFirst(responseWords.count)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !missingSuffix.isEmpty else { return response }
        return "\(response.trimmingCharacters(in: .whitespacesAndNewlines)) \(missingSuffix)"
    }

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

    private static func clampedProgress(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}

private let normalizedTokenCharacterSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

func normalizedWordTokens(from text: String) -> [String] {
    text
        .split(whereSeparator: \.isWhitespace)
        .map { token in
            String(token)
                .trimmingCharacters(in: normalizedTokenCharacterSet)
                .lowercased()
        }
        .filter { !$0.isEmpty }
}
