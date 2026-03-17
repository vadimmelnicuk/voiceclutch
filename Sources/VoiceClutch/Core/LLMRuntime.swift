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

enum LocalLLMGenerationResult: Sendable {
    case success(String)
    case timedOut
    case failed(Error)
}

actor LLMRuntime {
    typealias SessionLoader = @Sendable () async throws -> any LocalLLMGeneratingSession

    struct Metrics: Sendable {
        var modelLoadCount = 0
        var warmupCount = 0
        var requestCount = 0
        var timeoutCount = 0
        var generationFailureCount = 0
        var criticalReleaseCount = 0
    }

    private static let defaultModelIdentifier = "lmstudio-community/LFM2.5-1.2B-Instruct-MLX-4bit"
    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private static let deterministicGenerateParameters = GenerateParameters(
        temperature: 0.0,
        topP: 1.0
    )
    #endif

    private static var defaultModelDirectory: URL {
        defaultModelIdentifier
            .split(separator: "/")
            .reduce(ModelDownloadManager.modelsRootDirectory) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    nonisolated static let shared = LLMRuntime()

    private let logger: AppLogger
    private let sessionLoader: SessionLoader
    private var cachedSession: (any LocalLLMGeneratingSession)?
    private var loadingSessionTask: Task<any LocalLLMGeneratingSession, Error>?
    private var hasWarmedUp = false
    private var metrics = Metrics()

    init(
        sessionLoader: SessionLoader? = nil,
        loggerCategory: String = "LLMRuntime"
    ) {
        self.logger = AppLogger(category: loggerCategory)
        self.sessionLoader = sessionLoader ?? Self.makeDefaultSessionLoader()
    }

    func prepareIfPossible() async throws {
        _ = try await ensureSessionAvailable()
    }

    func warmupIfPossible() async {
        guard !hasWarmedUp else { return }

        do {
            let session = try await ensureSessionAvailable()
            _ = try await session.respond(to: #"{"final_text":"OK"}"#)
            hasWarmedUp = true
            metrics.warmupCount += 1
            logger.info("LLM runtime warmup completed")
        } catch {
            logger.debug("LLM runtime warmup failed: \(error.localizedDescription)")
        }
    }

    func generate(
        prompt: String,
        timeoutNanoseconds: UInt64
    ) async -> LocalLLMGenerationResult {
        metrics.requestCount += 1

        do {
            let session = try await ensureSessionAvailable()
            let result = await withTaskGroup(of: LocalLLMGenerationResult.self) { group in
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

                let first = await group.next() ?? .timedOut
                group.cancelAll()
                return first
            }

            switch result {
            case .timedOut:
                metrics.timeoutCount += 1
            case .failed:
                metrics.generationFailureCount += 1
            case .success:
                break
            }

            return result
        } catch {
            metrics.generationFailureCount += 1
            return .failed(error)
        }
    }

    func handleMemoryPressure(level: LocalLLMMemoryPressureLevel) {
        guard level == .critical else { return }
        if cachedSession != nil || loadingSessionTask != nil {
            logger.warning("Critical memory pressure received, releasing LLM runtime session")
        }
        cachedSession = nil
        loadingSessionTask?.cancel()
        loadingSessionTask = nil
        hasWarmedUp = false
        metrics.criticalReleaseCount += 1
    }

    func metricsSnapshot() -> Metrics {
        metrics
    }

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
            metrics.modelLoadCount += 1
            return loadedSession
        } catch {
            loadingSessionTask = nil
            throw error
        }
    }

    // MARK: - Shared model management

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

    nonisolated static func preloadInBackgroundIfEnabled() {
        let shouldPreload = LocalSmartFormattingPreference.shouldPreloadAtStartup()
        guard shouldPreload, LocalSmartFormattingPreference.load() else {
            return
        }

        Task.detached(priority: .utility) {
            let logger = AppLogger(category: "LLMRuntime")

            #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(Hub)
            do {
                _ = try await ensureDefaultModelAvailable()
                await shared.warmupIfPossible()
            } catch {
                logger.debug("LLM runtime preload failed: \(error.localizedDescription)")
            }
            #else
            logger.debug("LLM runtime preload skipped: MLX runtime unavailable")
            #endif
        }
    }

    private static func makeDefaultSessionLoader() -> SessionLoader {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return {
            let modelDirectory = try await ensureDefaultModelAvailable()
            let model = try await loadModel(directory: modelDirectory)
            return MLXChatSessionAdapter(
                session: ChatSession(
                    model,
                    generateParameters: deterministicGenerateParameters
                )
            )
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
