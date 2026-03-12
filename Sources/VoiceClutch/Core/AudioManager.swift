import Foundation
import CoreAudio
@preconcurrency import AVFoundation

private final class AsyncResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

/// Manages audio capture via AVAudioEngine and integrates with ASR.
public class AudioManager: @unchecked Sendable {
    private let maxRecordingDuration: Double = 30.0
    private let fallbackMinimumSpeechDuration: Double = 0.35
    private let fallbackWindowThresholdMultiplier: Float = 0.35
    private let microphoneChimeResources = MicrophoneChimePlayer.loadResources()
    private let bluetoothStartChimeDelay: TimeInterval = 0.25
    private let startChimeRetryWindow: TimeInterval = 1.0
    private let startChimeRetryDelayAfterConfigurationChange: TimeInterval = 0.25

    /// Keep recording briefly after key release so fast utterances do not lose their tail.
    static let postReleaseCaptureDuration: TimeInterval = 0.50

    private var audioEngine: AVAudioEngine?
    private var chimePlayerNode: AVAudioPlayerNode?
    private var audioEngineConfigurationObserver: NSObjectProtocol?
    private var onTranscription: (@Sendable (String, Bool) -> Void)?
    private var onCaptureReady: (@MainActor @Sendable () -> Void)?
    private let stateLock = NSLock()
    private var isRecording = false
    private var isStreamingSessionReady = false
    private var hasReportedCaptureReady = false
    private var pendingStartChimeWorkItem: DispatchWorkItem?
    private var pendingStartChimeRetryWorkItem: DispatchWorkItem?
    private var lastStartChimeRequestUptime: TimeInterval?
    private var hasRetriedStartChimeForCurrentSession = false
    private var hasPlayedStartChimeForCurrentSession = false

    /// Serial chain for async ASR operations (ingest/finish/reset).
    private let streamingOperationLock = NSLock()
    private var streamingOperationTail: Task<Void, Never>?
    private var streamingOperationGeneration: UInt64 = 0
    /// Samples waiting to be sent to the ASR stream.
    private var pendingStreamingSamples: [Float] = []

    /// Audio buffer accumulator for final speech detection + padding.
    private var audioBuffer: [Float] = []

    /// Target sample rate for ASR model.
    private let targetSampleRate: Double = 16_000.0

    /// ASR Processor for transcription.
    private var asrProcessor: ASRProcessor?

    /// Base microphone gain multiplier.
    private let microphoneGain: Float = 2.0
    /// Adaptive gain compensation targets quiet headset mics without over-amplifying noise.
    private let targetInputRMS: Float = 0.055
    private let inputNoiseFloorRMS: Float = 0.002
    private let maximumAdaptiveGainMultiplier: Float = 3.0
    private let adaptiveGainRiseSmoothing: Float = 0.20
    private let adaptiveGainFallSmoothing: Float = 0.35
    private let adaptiveGainSilentDecay: Float = 0.08
    private var adaptiveGainMultiplier: Float = 1.0

    /// Silence detection threshold (RMS energy level 0.0-1.0).
    private var silenceThreshold: Float = 0.01

    /// Add trailing context to help short phrases decode cleanly.
    private let trailingContextPaddingDuration: Double = 0.18
    /// Add leading context to protect first-word decoding on headset startup.
    private let leadingStreamingContextPaddingDuration: Double = 0.12

    /// Minimum duration for reliable final decode.
    private let minimumTranscriptionDuration: Double = 1.0

    /// Moderate tap buffers reduce per-chunk ingest overhead while keeping latency low.
    private let inputTapBufferSize: AVAudioFrameCount = 128
    /// Minimum sample count before dispatching a streaming ingest operation.
    private let streamingIngestChunkSize = 256

    /// Speech detection requires sustained windows above a permissive energy floor.
    private let windowThresholdMultiplier: Float = 0.7
    private let requiredConsecutiveSpeechWindows = 18

    private var isFinalizingRecording = false

    public init() {}

    /// Set the silence detection threshold.
    public func setSilenceThreshold(_ threshold: Float) {
        withStateLock {
            silenceThreshold = max(0.0, min(1.0, threshold))
        }
    }

    /// Get the current silence detection threshold.
    public func getSilenceThreshold() -> Float {
        withStateLock { silenceThreshold }
    }

    /// Set the ASR processor for transcription.
    public func setASRProcessor(_ processor: ASRProcessor) {
        self.asrProcessor = processor
    }

    /// Start recording audio.
    /// - Parameter callback: Function called with transcribed text and isFinal flag.
    public func startRecording(
        callback: @escaping @Sendable (String, Bool) -> Void,
        onCaptureReady: (@MainActor @Sendable () -> Void)? = nil
    ) throws {
        let alreadyRecording = withStateLock { isRecording }
        guard !alreadyRecording else {
            throw AudioError.alreadyRecording
        }

        StreamingMetrics.shared.beginSession()
        StreamingMetrics.shared.markRecordingStart()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let chimePlayerNode = attachChimePlayerNode(to: engine)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.formatError("Failed to create target audio format")
        }

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw AudioError.formatError("Failed to create audio converter")
        }

        withStateLock {
            audioBuffer.removeAll(keepingCapacity: true)
            let maxBufferSize = Int(targetSampleRate * maxRecordingDuration)
            if audioBuffer.capacity < maxBufferSize {
                audioBuffer.reserveCapacity(maxBufferSize)
            }
            pendingStreamingSamples.removeAll(keepingCapacity: true)
            if pendingStreamingSamples.capacity < (streamingIngestChunkSize * 4) {
                pendingStreamingSamples.reserveCapacity(streamingIngestChunkSize * 4)
            }
            isRecording = true
            isStreamingSessionReady = false
            isFinalizingRecording = false
            hasReportedCaptureReady = false
            resetStartChimePlaybackStateLocked()
            adaptiveGainMultiplier = 1.0
            onTranscription = callback
            self.onCaptureReady = onCaptureReady
        }

        inputNode.installTap(onBus: 0, bufferSize: inputTapBufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            self.processAudioTap(
                buffer: buffer,
                converter: converter,
                targetFormat: targetFormat
            )
        }

        // Pre-allocate graph resources to reduce start-time overhead.
        engine.prepare()

        do {
            try engine.start()
            audioEngine = engine
            self.chimePlayerNode = chimePlayerNode
            audioEngineConfigurationObserver = installAudioEngineConfigurationObserver(for: engine)
            StreamingMetrics.shared.markAudioEngineStarted()
        } catch {
            withStateLock {
                isRecording = false
                isStreamingSessionReady = false
                audioBuffer.removeAll(keepingCapacity: true)
                pendingStreamingSamples.removeAll(keepingCapacity: true)
                onTranscription = nil
                self.onCaptureReady = nil
                hasReportedCaptureReady = false
                adaptiveGainMultiplier = 1.0
            }
            self.chimePlayerNode = nil
            audioEngineConfigurationObserver = nil
            inputNode.removeTap(onBus: 0)
            resetStreamingSession()
            throw AudioError.engineStartFailed(error.localizedDescription)
        }

        do {
            try beginStreamingSession(callback: callback)
        } catch {
            withStateLock {
                isRecording = false
                isStreamingSessionReady = false
                isFinalizingRecording = false
                audioBuffer.removeAll(keepingCapacity: true)
                pendingStreamingSamples.removeAll(keepingCapacity: true)
                onTranscription = nil
                self.onCaptureReady = nil
                hasReportedCaptureReady = false
                adaptiveGainMultiplier = 1.0
            }
            self.chimePlayerNode = nil
            stopAudioEngine()
            resetStreamingSession()
            throw error
        }
    }

    @discardableResult
    public func playStartChime() -> Bool {
        let startDelay = currentStartChimeDelay()
        guard startDelay > 0 else {
            let didPlay = playChime(.press)
            withStateLock {
                recordStartChimePlaybackLocked(didPlay)
            }
            return didPlay
        }

        return scheduleStartChime(after: startDelay)
    }

    @discardableResult
    public func playStopChime() -> Bool {
        let shouldPlayStopChime = withStateLock { () -> Bool in
            let didPlayStartChime = hasPlayedStartChimeForCurrentSession
            resetStartChimePlaybackStateLocked()
            return didPlayStartChime
        }

        guard shouldPlayStopChime else {
            return false
        }

        return playChime(.release)
    }

    private func playScheduledStartChimeIfNeeded() {
        let shouldPlay = withStateLock { () -> Bool in
            guard isRecording, !isFinalizingRecording else {
                pendingStartChimeWorkItem = nil
                return false
            }

            guard pendingStartChimeWorkItem != nil, !hasPlayedStartChimeForCurrentSession else {
                pendingStartChimeWorkItem = nil
                return false
            }

            pendingStartChimeWorkItem = nil
            return true
        }

        guard shouldPlay else {
            return
        }

        let didPlay = playChime(.press)
        withStateLock {
            recordStartChimePlaybackLocked(didPlay)
        }
    }

    /// Stop recording audio and process final transcription.
    public func stopRecording() {
        let shouldFinalize = withStateLock { () -> Bool in
            let shouldFinalize = isRecording && !isFinalizingRecording
            if shouldFinalize {
                isFinalizingRecording = true
            }
            return shouldFinalize
        }

        guard shouldFinalize else { return }

        StreamingMetrics.shared.markStopRequested()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postReleaseCaptureDuration) { [weak self] in
            self?.finalizeRecording()
        }
    }

    /// Stop recording immediately without sending audio to ASR.
    public func cancelRecording() {
        let shouldCancel = withStateLock { () -> Bool in
            let shouldCancel = isRecording || isFinalizingRecording
            guard shouldCancel else { return false }

            isFinalizingRecording = false
            isRecording = false
            isStreamingSessionReady = false
            audioBuffer.removeAll(keepingCapacity: true)
            pendingStreamingSamples.removeAll(keepingCapacity: true)
            onTranscription = nil
            onCaptureReady = nil
            hasReportedCaptureReady = false
            adaptiveGainMultiplier = 1.0
            return true
        }

        guard shouldCancel else { return }

        stopAudioEngine()
        resetStreamingSession()
    }

    private func finalizeRecording() {
        let finalizationState = withStateLock {
            () -> (bufferedAudio: [Float], callback: (@Sendable (String, Bool) -> Void)?)? in
            guard isRecording else {
                isFinalizingRecording = false
                return nil
            }

            let bufferedAudio = audioBuffer
            let callback = onTranscription
            isRecording = false
            isStreamingSessionReady = false
            isFinalizingRecording = false
            audioBuffer.removeAll(keepingCapacity: true)
            onTranscription = nil
            onCaptureReady = nil
            hasReportedCaptureReady = false
            adaptiveGainMultiplier = 1.0
            return (bufferedAudio, callback)
        }

        guard let finalizationState else {
            return
        }

        stopAudioEngine()

        let detection = detectSpeech(finalizationState.bufferedAudio, threshold: silenceThreshold)
        let preparation = prepareTranscription(
            finalizationState.bufferedAudio,
            detection: detection,
            threshold: silenceThreshold
        )

        debugLogFinalizationDecisionIfNeeded(
            detection: detection,
            preparation: preparation,
            threshold: silenceThreshold,
            capturedSampleCount: finalizationState.bufferedAudio.count
        )

        // If silence, clear streaming session and emit empty final so injected partials are removed.
        if !preparation.shouldTranscribe {
            resetStreamingSession()
            StreamingMetrics.shared.markFinalDelivered()
            debugLogStreamingMetricsIfNeeded()
            finalizationState.callback?("", true)
            return
        }

        guard let asrProcessor else {
            StreamingMetrics.shared.markFinalDelivered()
            debugLogStreamingMetricsIfNeeded()
            finalizationState.callback?("", true)
            return
        }

        let additionalSamples = preparation.additionalSampleCount > 0
            ? Array(repeating: Float.zero, count: preparation.additionalSampleCount)
            : []

        enqueueStreamingOperation { [weak self] in
            guard let self else { return }

            let pendingSamples = self.consumePendingStreamingSamples()
            if !pendingSamples.isEmpty {
                StreamingMetrics.shared.incrementIngestChunks()
                do {
                    try await asrProcessor.ingest(samples: pendingSamples)
                } catch {
                    print("❌ ASR final ingest failed: \(error)")
                }
            }

            if !additionalSamples.isEmpty {
                StreamingMetrics.shared.incrementIngestChunks()
                do {
                    try await asrProcessor.ingest(samples: additionalSamples)
                } catch {
                    print("❌ ASR trailing ingest failed: \(error)")
                }
            }

            let transcription: String
            do {
                transcription = try await asrProcessor.finishStreaming()
            } catch {
                print("❌ ASR finish failed: \(error)")
                transcription = ""
            }

            await MainActor.run {
                StreamingMetrics.shared.markFinalDelivered()
                self.debugLogStreamingMetricsIfNeeded()
                finalizationState.callback?(transcription, true)
            }
        }
    }

    /// Process audio from the tap callback.
    private func processAudioTap(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let tapCallbackStartUptime = ProcessInfo.processInfo.systemUptime

        guard buffer.frameLength > 0 else {
            return
        }

        StreamingMetrics.shared.markFirstTapReceived()
        reportCaptureReadyIfNeeded()

        // Calculate required frame capacity.
        let inputFrameLength = Double(buffer.frameLength)
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(inputFrameLength * ratio)) + 10

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error else {
            return
        }

        // Extract converted audio data.
        guard let data = convertedBuffer.floatChannelData?[0] else {
            return
        }

        let frameLength = Int(convertedBuffer.frameLength)
        let inputRMS = calculateInputRMS(samples: data, count: frameLength)
        let effectiveGain = microphoneGain * adaptiveGainMultiplier(forInputRMS: inputRMS)
        let samples = Array<Float>(unsafeUninitializedCapacity: frameLength) { initializedBuffer, initializedCount in
            for sampleIndex in 0..<frameLength {
                let amplifiedSample = data[sampleIndex] * effectiveGain
                initializedBuffer[sampleIndex] = max(-1.0, min(1.0, amplifiedSample))
            }
            initializedCount = frameLength
        }

        var shouldStream = false
        withStateLock {
            if isRecording {
                audioBuffer.append(contentsOf: samples)
                shouldStream = true

                // Limit buffer size to prevent memory issues.
                let maxBufferSize = Int(targetSampleRate * maxRecordingDuration)
                if audioBuffer.count > maxBufferSize {
                    audioBuffer.removeFirst(audioBuffer.count - maxBufferSize)
                }
            }
        }

        if shouldStream {
            enqueueStreamingSamples(samples)
            let durationMs = max(
                0,
                (ProcessInfo.processInfo.systemUptime - tapCallbackStartUptime) * 1_000
            )
            StreamingMetrics.shared.recordTapToIngestEnqueue(durationMs: durationMs)
        }
    }

    private func beginStreamingSession(callback: @escaping @Sendable (String, Bool) -> Void) throws {
        guard let asrProcessor else {
            throw AudioError.processingError("ASR processor is not configured")
        }

        try runAsyncOperation {
            try await asrProcessor.startStreaming { partialText in
                callback(partialText, false)
            }
        }

        activateStreamingSession(asrProcessor: asrProcessor)
    }

    private func reportCaptureReadyIfNeeded() {
        let readyEvent = withStateLock { () -> (callback: (@MainActor @Sendable () -> Void)?, shouldMark: Bool) in
            guard isRecording, !hasReportedCaptureReady else {
                return (nil, false)
            }

            hasReportedCaptureReady = true
            return (onCaptureReady, true)
        }

        guard readyEvent.shouldMark else { return }

        StreamingMetrics.shared.markCaptureReady()
        guard let callback = readyEvent.callback else { return }

        Task { @MainActor in
            callback()
        }
    }

    private func enqueueStreamingSamples(_ samples: [Float]) {
        guard !samples.isEmpty, let asrProcessor else { return }

        let chunk = withStateLock { () -> [Float]? in
            guard isRecording || isFinalizingRecording else {
                return nil
            }

            pendingStreamingSamples.append(contentsOf: samples)
            guard isStreamingSessionReady else {
                return nil
            }
            guard pendingStreamingSamples.count >= streamingIngestChunkSize else {
                return nil
            }

            var readySamples: [Float] = []
            readySamples.reserveCapacity(pendingStreamingSamples.count)
            swap(&readySamples, &pendingStreamingSamples)
            return readySamples
        }

        guard let chunk else { return }

        enqueueIngestOperation(samples: chunk, asrProcessor: asrProcessor, errorLabel: "ASR ingest failed")
    }

    private func resetStreamingSession() {
        withStateLock {
            isStreamingSessionReady = false
            pendingStreamingSamples.removeAll(keepingCapacity: true)
        }

        guard let asrProcessor else { return }

        enqueueStreamingOperation {
            await asrProcessor.resetStreaming()
        }
    }

    private func consumePendingStreamingSamples() -> [Float] {
        withStateLock {
            guard !pendingStreamingSamples.isEmpty else {
                return []
            }

            var pending: [Float] = []
            pending.reserveCapacity(pendingStreamingSamples.count)
            swap(&pending, &pendingStreamingSamples)
            return pending
        }
    }

    private func activateStreamingSession(asrProcessor: ASRProcessor) {
        let leadingContextSampleCount = Int(targetSampleRate * leadingStreamingContextPaddingDuration)
        if leadingContextSampleCount > 0 {
            let leadingContextSamples = Array(repeating: Float.zero, count: leadingContextSampleCount)
            enqueueIngestOperation(
                samples: leadingContextSamples,
                asrProcessor: asrProcessor,
                errorLabel: "ASR startup leading ingest failed"
            )
        }

        let startupBufferedSamples = consumePendingStreamingSamples()
        if !startupBufferedSamples.isEmpty {
            enqueueIngestOperation(
                samples: startupBufferedSamples,
                asrProcessor: asrProcessor,
                errorLabel: "ASR startup ingest failed"
            )
        }

        withStateLock {
            isStreamingSessionReady = true
        }

        StreamingMetrics.shared.markASRStreamReady(
            bufferedSamplesFlushed: startupBufferedSamples.count
        )

        let postReadySamples = consumePendingStreamingSamples()
        if !postReadySamples.isEmpty {
            enqueueIngestOperation(
                samples: postReadySamples,
                asrProcessor: asrProcessor,
                errorLabel: "ASR post-ready ingest failed"
            )
        }
    }

    private func enqueueIngestOperation(
        samples: [Float],
        asrProcessor: ASRProcessor,
        errorLabel: String
    ) {
        guard !samples.isEmpty else { return }

        StreamingMetrics.shared.incrementIngestChunks()
        enqueueStreamingOperation {
            do {
                try await asrProcessor.ingest(samples: samples)
            } catch {
                print("❌ \(errorLabel): \(error)")
            }
        }
    }

    private func enqueueStreamingOperation(_ operation: @escaping @Sendable () async -> Void) {
        streamingOperationLock.lock()
        let previousTask = streamingOperationTail
        streamingOperationGeneration &+= 1
        let generation = streamingOperationGeneration
        let nextTask = Task {
            if let previousTask {
                _ = await previousTask.result
            }
            await operation()
            self.withStreamingOperationLock {
                if self.streamingOperationGeneration == generation {
                    self.streamingOperationTail = nil
                }
            }
        }
        streamingOperationTail = nextTask
        streamingOperationLock.unlock()
    }

    private func withStreamingOperationLock<T>(_ operation: () -> T) -> T {
        streamingOperationLock.lock()
        defer { streamingOperationLock.unlock() }
        return operation()
    }

    private func runAsyncOperation<T>(
        timeout: TimeInterval = 30,
        operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = AsyncResultBox<T>()

        Task {
            let result: Result<T, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }

            resultBox.value = result
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            throw AudioError.processingError("ASR operation timed out")
        }

        guard let operationResult = resultBox.value else {
            throw AudioError.processingError("ASR operation failed")
        }

        return try operationResult.get()
    }

    private func debugLogStreamingMetricsIfNeeded() {
        #if DEBUG
        let snapshot = StreamingMetrics.shared.snapshot()
        print(
            "⏱️ startup record=\(formatMetricMs(snapshot.triggerToRecordingStartMs)) " +
            "engine=\(formatMetricMs(snapshot.triggerToAudioEngineStartMs)) " +
            "tap=\(formatMetricMs(snapshot.triggerToFirstTapMs)) " +
            "captureReady=\(formatMetricMs(snapshot.triggerToCaptureReadyMs)) " +
            "stream=\(formatMetricMs(snapshot.triggerToASRStreamReadyMs)) " +
            "partial=\(formatMetricMs(snapshot.triggerToFirstPartialMs)) " +
            "flush=\(snapshot.bufferedSamplesFlushedOnStreamReady) samples " +
            "stopToFinal=\(formatMetricMs(snapshot.lastStopToFinalMs))"
        )
        #endif
    }

    private func formatMetricMs(_ value: Double) -> String {
        "\(Int(value.rounded()))ms"
    }

    /// Get current audio buffer (for debugging).
    public func getCurrentBuffer() -> [Float] {
        withStateLock { audioBuffer }
    }

    /// Get current buffer duration in seconds.
    public func getCurrentBufferDuration() -> Double {
        withStateLock {
            Double(audioBuffer.count) / targetSampleRate
        }
    }

    /// Clear the audio buffer.
    public func clearBuffer() {
        withStateLock {
            audioBuffer.removeAll()
        }
    }

    @discardableResult
    public func compactMemoryIfIdle() -> Bool {
        let canCompact = withStateLock { () -> Bool in
            guard !isRecording, !isFinalizingRecording else {
                return false
            }

            audioBuffer.removeAll(keepingCapacity: false)
            isStreamingSessionReady = false
            pendingStreamingSamples.removeAll(keepingCapacity: false)
            adaptiveGainMultiplier = 1.0
            return true
        }

        guard canCompact else {
            return false
        }

        resetStreamingSession()
        return true
    }

    /// Check if currently recording.
    public func isCurrentlyRecording() -> Bool {
        withStateLock { isRecording }
    }

    public func getStreamingMetricsSnapshot() -> StreamingMetricsSnapshot {
        StreamingMetrics.shared.snapshot()
    }

    // MARK: - Silence Detection

    private struct TranscriptionPreparation {
        let shouldTranscribe: Bool
        let additionalSampleCount: Int
        let transcriptionDurationSeconds: Double
        let decisionLabel: String
        let usedFallback: Bool
    }

    private func prepareTranscription(
        _ buffer: [Float],
        detection: SpeechDetectionResult,
        threshold: Float
    ) -> TranscriptionPreparation {
        let usedFallback = shouldUseFallbackTranscription(
            detection: detection,
            threshold: threshold,
            sampleCount: buffer.count
        )

        guard detection.containsSpeech || usedFallback else {
            return TranscriptionPreparation(
                shouldTranscribe: false,
                additionalSampleCount: 0,
                transcriptionDurationSeconds: 0,
                decisionLabel: "silence_gate",
                usedFallback: false
            )
        }

        let baseSampleCount = buffer.count
        let trailingPaddingSampleCount = Int(targetSampleRate * trailingContextPaddingDuration)
        var totalSampleCount = baseSampleCount + trailingPaddingSampleCount

        let minimumSampleCount = Int(targetSampleRate * minimumTranscriptionDuration)
        if totalSampleCount < minimumSampleCount {
            totalSampleCount = minimumSampleCount
        }

        return TranscriptionPreparation(
            shouldTranscribe: true,
            additionalSampleCount: max(0, totalSampleCount - baseSampleCount),
            transcriptionDurationSeconds: Double(totalSampleCount) / targetSampleRate,
            decisionLabel: usedFallback ? "fallback_cautious" : "window_rms",
            usedFallback: usedFallback
        )
    }

    private func shouldUseFallbackTranscription(
        detection: SpeechDetectionResult,
        threshold: Float,
        sampleCount: Int
    ) -> Bool {
        guard !detection.containsSpeech else {
            return false
        }

        let captureDuration = Double(sampleCount) / targetSampleRate
        guard captureDuration >= fallbackMinimumSpeechDuration else {
            return false
        }

        let fallbackWindowThreshold = threshold * fallbackWindowThresholdMultiplier
        return detection.maxWindowRms >= fallbackWindowThreshold
    }

    private func detectSpeech(_ buffer: [Float], threshold: Float) -> SpeechDetectionResult {
        SpeechDetector.detect(
            buffer,
            configuration: SpeechDetectionConfiguration(
                threshold: threshold,
                targetSampleRate: targetSampleRate,
                windowThresholdMultiplier: windowThresholdMultiplier,
                requiredConsecutiveSpeechWindows: requiredConsecutiveSpeechWindows
            )
        )
    }

    private func debugDescription(
        for detection: SpeechDetectionResult,
        threshold: Float,
        label: String
    ) -> String {
        let windowThreshold = threshold * windowThresholdMultiplier

        return
            "🎤 \(label) via \(detection.trigger) " +
            "rms=\(String(format: "%.4f", detection.rmsEnergy))/\(String(format: "%.4f", threshold)) " +
            "peak=\(String(format: "%.4f", detection.peakAmplitude)) " +
            "maxWindowRMS=\(String(format: "%.4f", detection.maxWindowRms))/\(String(format: "%.4f", windowThreshold)) " +
            "windowRun=\(detection.longestWindowRun)/\(requiredConsecutiveSpeechWindows)"
    }

    private func calculateInputRMS(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }

        var sumOfSquares = Double.zero
        for index in 0..<count {
            let sample = Double(samples[index])
            sumOfSquares += sample * sample
        }

        return Float(sqrt(sumOfSquares / Double(count)))
    }

    private func adaptiveGainMultiplier(forInputRMS inputRMS: Float) -> Float {
        withStateLock {
            guard inputRMS > inputNoiseFloorRMS else {
                adaptiveGainMultiplier = max(1.0, adaptiveGainMultiplier - adaptiveGainSilentDecay)
                return adaptiveGainMultiplier
            }

            let desiredMultiplier = min(
                maximumAdaptiveGainMultiplier,
                max(1.0, targetInputRMS / inputRMS)
            )

            let smoothing = desiredMultiplier > adaptiveGainMultiplier
                ? adaptiveGainRiseSmoothing
                : adaptiveGainFallSmoothing

            adaptiveGainMultiplier += (desiredMultiplier - adaptiveGainMultiplier) * smoothing
            return adaptiveGainMultiplier
        }
    }

    private func debugLogFinalizationDecisionIfNeeded(
        detection: SpeechDetectionResult,
        preparation: TranscriptionPreparation,
        threshold: Float,
        capturedSampleCount: Int
    ) {
        #if DEBUG
        let captureDuration = Double(capturedSampleCount) / targetSampleRate
        let asrDuration = preparation.shouldTranscribe ? preparation.transcriptionDurationSeconds : 0
        let fallbackThreshold = threshold * fallbackWindowThresholdMultiplier
        let speechLabel = preparation.shouldTranscribe ? "SPEECH" : "NO_SPEECH"

        print(
            "\(debugDescription(for: detection, threshold: threshold, label: speechLabel)) " +
            "decision=\(preparation.decisionLabel) " +
            "fallback=\(preparation.usedFallback ? "yes" : "no") " +
            "capture=\(String(format: "%.2f", captureDuration))s " +
            "asr=\(String(format: "%.2f", asrDuration))s " +
            "fallbackWindowThreshold=\(String(format: "%.4f", fallbackThreshold)) " +
            "fallbackMinDuration=\(String(format: "%.2f", fallbackMinimumSpeechDuration))s"
        )
        #endif
    }

    private func attachChimePlayerNode(to engine: AVAudioEngine) -> AVAudioPlayerNode? {
        guard let microphoneChimeResources else {
            return nil
        }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: microphoneChimeResources.format)
        return playerNode
    }

    private func playChime(_ sound: MicrophoneChimePlayer.Sound) -> Bool {
        let playback = withStateLock {
            () -> (playerNode: AVAudioPlayerNode, buffer: AVAudioPCMBuffer)? in
            guard let audioEngine, audioEngine.isRunning else {
                return nil
            }

            guard let chimePlayerNode, let microphoneChimeResources else {
                return nil
            }

            guard isRecording || isFinalizingRecording else {
                return nil
            }

            return (chimePlayerNode, microphoneChimeResources.buffer(for: sound))
        }

        guard let playback else {
            return false
        }

        playback.playerNode.stop()
        playback.playerNode.scheduleBuffer(playback.buffer, completionHandler: nil)
        playback.playerNode.play()
        return true
    }

    private func installAudioEngineConfigurationObserver(for engine: AVAudioEngine) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleAudioEngineConfigurationChange()
        }
    }

    private func handleAudioEngineConfigurationChange() {
        if reschedulePendingStartChimeAfterConfigurationChange() {
            return
        }

        let shouldScheduleRetry = withStateLock { () -> Bool in
            guard isRecording, !isFinalizingRecording else {
                return false
            }

            guard let lastStartChimeRequestUptime else {
                return false
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - lastStartChimeRequestUptime
            guard elapsed <= startChimeRetryWindow, !hasRetriedStartChimeForCurrentSession else {
                return false
            }

            pendingStartChimeRetryWorkItem?.cancel()
            hasRetriedStartChimeForCurrentSession = true
            return true
        }

        guard shouldScheduleRetry else {
            return
        }

        let retryWorkItem = DispatchWorkItem { [weak self] in
            self?.playRetriedStartChimeIfNeeded()
        }

        withStateLock {
            pendingStartChimeRetryWorkItem = retryWorkItem
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + startChimeRetryDelayAfterConfigurationChange,
            execute: retryWorkItem
        )
    }

    private func scheduleStartChime(after delay: TimeInterval) -> Bool {
        let workItem = DispatchWorkItem { [weak self] in
            self?.playScheduledStartChimeIfNeeded()
        }

        let didSchedule = withStateLock { () -> Bool in
            guard isRecording, !isFinalizingRecording else {
                return false
            }

            prepareScheduledStartChimeLocked(workItem)
            return true
        }

        guard didSchedule else {
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return true
    }

    private func reschedulePendingStartChimeAfterConfigurationChange() -> Bool {
        let shouldReschedule = withStateLock { () -> Bool in
            guard isRecording, !isFinalizingRecording else {
                return false
            }

            guard pendingStartChimeWorkItem != nil, !hasPlayedStartChimeForCurrentSession else {
                return false
            }

            return true
        }

        guard shouldReschedule else {
            return false
        }

        return scheduleStartChime(after: startChimeRetryDelayAfterConfigurationChange)
    }

    private func playRetriedStartChimeIfNeeded() {
        let shouldRetry = withStateLock { () -> Bool in
            pendingStartChimeRetryWorkItem = nil

            guard isRecording, !isFinalizingRecording else {
                return false
            }

            guard let lastStartChimeRequestUptime else {
                return false
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - lastStartChimeRequestUptime
            guard elapsed <= (startChimeRetryWindow + startChimeRetryDelayAfterConfigurationChange) else {
                self.lastStartChimeRequestUptime = nil
                return false
            }

            self.lastStartChimeRequestUptime = nil
            return true
        }

        guard shouldRetry else {
            return
        }

        _ = playChime(.press)
    }

    private func currentStartChimeDelay() -> TimeInterval {
        currentInputUsesBluetoothTransport() ? bluetoothStartChimeDelay : 0
    }

    private func currentInputUsesBluetoothTransport() -> Bool {
        guard let transportType = currentDefaultInputTransportType() else {
            return false
        }

        return transportType == kAudioDeviceTransportTypeBluetooth ||
            transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private func currentDefaultInputTransportType() -> UInt32? {
        var deviceID = AudioDeviceID(0)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        var transportType: UInt32 = 0
        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        propertySize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &transportType
        )

        guard transportStatus == noErr else {
            return nil
        }

        return transportType
    }

    private func prepareScheduledStartChimeLocked(_ workItem: DispatchWorkItem) {
        cancelPendingStartChimeWorkItemsLocked()
        pendingStartChimeWorkItem = workItem
        lastStartChimeRequestUptime = nil
        hasRetriedStartChimeForCurrentSession = false
        hasPlayedStartChimeForCurrentSession = false
    }

    private func recordStartChimePlaybackLocked(_ didPlay: Bool) {
        cancelPendingStartChimeWorkItemsLocked()
        lastStartChimeRequestUptime = didPlay ? ProcessInfo.processInfo.systemUptime : nil
        hasRetriedStartChimeForCurrentSession = false
        hasPlayedStartChimeForCurrentSession = didPlay
    }

    private func resetStartChimePlaybackStateLocked() {
        cancelPendingStartChimeWorkItemsLocked()
        lastStartChimeRequestUptime = nil
        hasRetriedStartChimeForCurrentSession = false
        hasPlayedStartChimeForCurrentSession = false
    }

    private func cancelPendingStartChimeWorkItemsLocked() {
        pendingStartChimeWorkItem?.cancel()
        pendingStartChimeWorkItem = nil
        pendingStartChimeRetryWorkItem?.cancel()
        pendingStartChimeRetryWorkItem = nil
    }

    private func stopAudioEngine() {
        withStateLock {
            resetStartChimePlaybackStateLocked()
        }
        if let audioEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigurationObserver)
            self.audioEngineConfigurationObserver = nil
        }
        chimePlayerNode?.stop()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        chimePlayerNode = nil
        audioEngine = nil
    }

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}

// MARK: - Audio Errors

/// Audio-related errors.
enum AudioError: Error, CustomStringConvertible {
    case alreadyRecording
    case engineNotRunning
    case permissionDenied
    case engineStartFailed(String)
    case formatError(String)
    case processingError(String)

    var description: String {
        switch self {
        case .alreadyRecording:
            return "Already recording audio"
        case .engineNotRunning:
            return "Audio engine is not running"
        case .permissionDenied:
            return "Microphone permission denied"
        case .engineStartFailed(let message):
            return "Audio engine start failed: \(message)"
        case .formatError(let message):
            return "Audio format error: \(message)"
        case .processingError(let message):
            return "Audio processing error: \(message)"
        }
    }
}
