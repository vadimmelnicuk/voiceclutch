import AVFoundation
import Foundation
import FluidAudio

/// ASR-related errors.
public enum ASRError: Error, LocalizedError {
    case modelLoadFailed(Error)
    case transcriptionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let error):
            return "Failed to load ASR model: \(error.localizedDescription)"
        case .transcriptionFailed(let error):
            return "Failed to transcribe audio: \(error.localizedDescription)"
        }
    }
}

/// ASR Processor - handles speech recognition using FluidAudio Nemotron streaming manager.
public actor ASRProcessor {
    private static let streamSampleRate: Double = 16_000
    private static let streamChannels: AVAudioChannelCount = 1
    private static let streamFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamSampleRate,
            channels: streamChannels,
            interleaved: false
        ) else {
            fatalError("Failed to initialize ASR stream format")
        }
        return format
    }()

    /// FluidAudio Nemotron streaming manager.
    private var nemotronManager: NemotronStreamingAsrManager?

    /// Whether the model is loaded and ready.
    private var isModelLoaded: Bool = false

    /// Whether streaming is currently active for this recording session.
    private var isStreaming: Bool = false
    /// Whether a warm-up streaming pass has completed.
    private var hasWarmedUp: Bool = false

    /// Partial callback throttling interval.
    /// Keep low to improve perceived streaming responsiveness while still
    /// coalescing callback bursts from the ASR engine.
    private let partialThrottleInterval: TimeInterval = 0.08

    private var partialHandler: (@Sendable (String) -> Void)?
    private var lastPartialEmitTime: TimeInterval = 0
    private var pendingPartial: String?
    private var throttleTask: Task<Void, Never>?
    private var lastEmittedPartial: String = ""

    // MARK: - Initialization

    public init() async throws {}

    /// Preload Nemotron 560ms models from local cache.
    public func preload() async throws {
        guard !isModelLoaded else {
            return
        }

        do {
            let modelDir = ModelDownloadManager.asrModelDirectory
            let manager = NemotronStreamingAsrManager()
            try await manager.loadModels(modelDir: modelDir)

            nemotronManager = manager
            isModelLoaded = true
            hasWarmedUp = false
        } catch {
            throw ASRError.modelLoadFailed(error)
        }
    }

    /// Run a one-time warm-up pass so first user dictation avoids model cold-start latency.
    public func warmUpIfNeeded() async throws {
        guard isModelLoaded, nemotronManager != nil else {
            throw ASRError.modelLoadFailed(NSError(domain: "ASRProcessor", code: -1))
        }

        guard !hasWarmedUp else { return }

        let warmupSampleCount = Int(Self.streamSampleRate * 1.2)
        let warmupSamples = Array(repeating: Float.zero, count: warmupSampleCount)

        do {
            try await startStreaming(onPartialTranscription: nil)
            try await ingest(samples: warmupSamples)
            _ = try await finishStreaming()
            hasWarmedUp = true
        } catch {
            await resetStreaming()
            throw ASRError.transcriptionFailed(error)
        }
    }

    /// Starts a streaming session and sets a partial callback.
    public func startStreaming(onPartialTranscription: (@Sendable (String) -> Void)? = nil) async throws {
        guard isModelLoaded, let manager = nemotronManager else {
            throw ASRError.modelLoadFailed(NSError(domain: "ASRProcessor", code: -1))
        }

        await manager.reset()

        resetPartialState(handler: onPartialTranscription)

        await manager.setPartialCallback { [weak self] text in
            Task { await self?.handlePartial(text) }
        }

        isStreaming = true
    }

    /// Ingest a 16kHz mono Float32 sample block into the active streaming session.
    public func ingest(samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard isStreaming, let manager = nemotronManager else { return }

        do {
            let buffer = try Self.makePCMBuffer(samples: samples)
            _ = try await manager.process(audioBuffer: buffer)
        } catch {
            throw ASRError.transcriptionFailed(error)
        }
    }

    /// Completes streaming and returns final transcript.
    public func finishStreaming() async throws -> String {
        guard isStreaming, let manager = nemotronManager else {
            clearPartialState()
            return ""
        }

        do {
            await flushPendingPartial(force: true)
            let finalText = try await manager.finish()
            await manager.reset()
            endStreamingState()
            return finalText
        } catch {
            endStreamingState()
            throw ASRError.transcriptionFailed(error)
        }
    }

    /// Resets an active streaming session without returning a final transcript.
    public func resetStreaming() async {
        if let manager = nemotronManager {
            await manager.reset()
        }
        endStreamingState()
    }

    /// Check if model is ready.
    public func isReady() -> Bool {
        isModelLoaded
    }

    /// Release the model to free memory.
    public func releaseModel() async {
        if let manager = nemotronManager {
            await manager.reset()
        }

        clearPartialState()
        nemotronManager = nil
        isModelLoaded = false
        hasWarmedUp = false
        isStreaming = false
    }

    // MARK: - Partial Throttling

    private func resetPartialState(handler: (@Sendable (String) -> Void)?) {
        partialHandler = handler
        lastPartialEmitTime = 0
        pendingPartial = nil
        throttleTask?.cancel()
        throttleTask = nil
        lastEmittedPartial = ""
    }

    private func clearPartialState() {
        partialHandler = nil
        pendingPartial = nil
        throttleTask?.cancel()
        throttleTask = nil
        lastEmittedPartial = ""
        lastPartialEmitTime = 0
    }

    private func endStreamingState() {
        clearPartialState()
        isStreaming = false
    }

    private func handlePartial(_ text: String) async {
        guard !text.isEmpty, text != lastEmittedPartial else {
            return
        }

        let now = Date().timeIntervalSince1970
        let elapsed = now - lastPartialEmitTime

        if elapsed >= partialThrottleInterval {
            throttleTask?.cancel()
            throttleTask = nil
            pendingPartial = nil
            lastPartialEmitTime = now
            lastEmittedPartial = text
            partialHandler?(text)
            return
        }

        pendingPartial = text

        guard throttleTask == nil else {
            return
        }

        let delay = max(0, partialThrottleInterval - elapsed)
        throttleTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.flushPendingPartial(force: false)
        }
    }

    private func flushPendingPartial(force: Bool) async {
        throttleTask?.cancel()
        throttleTask = nil

        guard let text = pendingPartial else {
            return
        }
        pendingPartial = nil

        guard force || text != lastEmittedPartial else {
            return
        }

        lastEmittedPartial = text
        lastPartialEmitTime = Date().timeIntervalSince1970
        partialHandler?(text)
    }

    // MARK: - Audio Helpers

    private static func makePCMBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: streamFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw ASRError.transcriptionFailed(NSError(domain: "ASRProcessor", code: -2))
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw ASRError.transcriptionFailed(NSError(domain: "ASRProcessor", code: -3))
        }

        samples.withUnsafeBufferPointer { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }
        return buffer
    }
}
