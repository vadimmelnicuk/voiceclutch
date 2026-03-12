import Foundation

public struct StreamingMetricsSnapshot: Sendable {
    public let ingestChunks: Int
    public let partialsReceived: Int
    public let partialsEmitted: Int
    public let rewriteCount: Int
    public let triggerToRecordingStartMs: Double
    public let triggerToAudioEngineStartMs: Double
    public let triggerToFirstTapMs: Double
    public let triggerToCaptureReadyMs: Double
    public let triggerToASRStreamReadyMs: Double
    public let triggerToFirstPartialMs: Double
    public let bufferedSamplesFlushedOnStreamReady: Int
    public let tapToIngestEnqueueAverageMs: Double
    public let tapToIngestEnqueueMaxMs: Double
    public let lastStopToFinalMs: Double
}

final class StreamingMetrics: @unchecked Sendable {
    static let shared = StreamingMetrics()

    private let lock = NSLock()
    private var ingestChunks = 0
    private var partialsReceived = 0
    private var partialsEmitted = 0
    private var rewriteCount = 0
    private var triggerPressedUptime: TimeInterval?
    private var triggerToRecordingStartMs = 0.0
    private var triggerToAudioEngineStartMs = 0.0
    private var triggerToFirstTapMs = 0.0
    private var triggerToCaptureReadyMs = 0.0
    private var triggerToASRStreamReadyMs = 0.0
    private var triggerToFirstPartialMs = 0.0
    private var bufferedSamplesFlushedOnStreamReady = 0
    private var tapToIngestEnqueueTotalMs = 0.0
    private var tapToIngestEnqueueSamples = 0
    private var tapToIngestEnqueueMaxMs = 0.0
    private var stopRequestedUptime: TimeInterval?
    private var lastStopToFinalMs = 0.0

    private init() {}

    func resetForSession() {
        lock.lock()
        resetSessionState(preservingTrigger: false)
        lock.unlock()
    }

    func markTriggerPressed() {
        lock.lock()
        resetSessionState(preservingTrigger: false)
        triggerPressedUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func beginSession() {
        lock.lock()
        resetSessionState(preservingTrigger: true)
        lock.unlock()
    }

    func markRecordingStart() {
        lock.lock()
        if triggerToRecordingStartMs == 0 {
            triggerToRecordingStartMs = elapsedSinceTriggerLocked()
        }
        lock.unlock()
    }

    func markAudioEngineStarted() {
        lock.lock()
        if triggerToAudioEngineStartMs == 0 {
            triggerToAudioEngineStartMs = elapsedSinceTriggerLocked()
        }
        lock.unlock()
    }

    func markFirstTapReceived() {
        lock.lock()
        if triggerToFirstTapMs == 0 {
            triggerToFirstTapMs = elapsedSinceTriggerLocked()
        }
        lock.unlock()
    }

    func markCaptureReady() {
        lock.lock()
        if triggerToCaptureReadyMs == 0 {
            triggerToCaptureReadyMs = elapsedSinceTriggerLocked()
        }
        lock.unlock()
    }

    func markASRStreamReady(bufferedSamplesFlushed: Int) {
        lock.lock()
        bufferedSamplesFlushedOnStreamReady = bufferedSamplesFlushed
        if triggerToASRStreamReadyMs == 0 {
            triggerToASRStreamReadyMs = elapsedSinceTriggerLocked()
        }
        lock.unlock()
    }

    func markFirstPartialEmitted() {
        lock.lock()
        if triggerToFirstPartialMs == 0 {
            triggerToFirstPartialMs = elapsedSinceTriggerLocked()
        }
        lock.unlock()
    }

    func incrementIngestChunks() {
        lock.lock()
        ingestChunks += 1
        lock.unlock()
    }

    func incrementPartialsReceived() {
        lock.lock()
        partialsReceived += 1
        lock.unlock()
    }

    func incrementPartialsEmitted() {
        lock.lock()
        partialsEmitted += 1
        lock.unlock()
    }

    func incrementRewriteCount() {
        lock.lock()
        rewriteCount += 1
        lock.unlock()
    }

    func recordTapToIngestEnqueue(durationMs: Double) {
        lock.lock()
        tapToIngestEnqueueTotalMs += durationMs
        tapToIngestEnqueueSamples += 1
        tapToIngestEnqueueMaxMs = max(tapToIngestEnqueueMaxMs, durationMs)
        lock.unlock()
    }

    func markStopRequested() {
        lock.lock()
        stopRequestedUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func markFinalDelivered() {
        lock.lock()
        if let startedAt = stopRequestedUptime {
            lastStopToFinalMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        }
        stopRequestedUptime = nil
        lock.unlock()
    }

    func snapshot() -> StreamingMetricsSnapshot {
        lock.lock()
        let averageMs = tapToIngestEnqueueSamples == 0
            ? 0
            : tapToIngestEnqueueTotalMs / Double(tapToIngestEnqueueSamples)
        let snapshot = StreamingMetricsSnapshot(
            ingestChunks: ingestChunks,
            partialsReceived: partialsReceived,
            partialsEmitted: partialsEmitted,
            rewriteCount: rewriteCount,
            triggerToRecordingStartMs: triggerToRecordingStartMs,
            triggerToAudioEngineStartMs: triggerToAudioEngineStartMs,
            triggerToFirstTapMs: triggerToFirstTapMs,
            triggerToCaptureReadyMs: triggerToCaptureReadyMs,
            triggerToASRStreamReadyMs: triggerToASRStreamReadyMs,
            triggerToFirstPartialMs: triggerToFirstPartialMs,
            bufferedSamplesFlushedOnStreamReady: bufferedSamplesFlushedOnStreamReady,
            tapToIngestEnqueueAverageMs: averageMs,
            tapToIngestEnqueueMaxMs: tapToIngestEnqueueMaxMs,
            lastStopToFinalMs: lastStopToFinalMs
        )
        lock.unlock()
        return snapshot
    }

    private func resetSessionState(preservingTrigger: Bool) {
        let existingTriggerUptime = preservingTrigger ? triggerPressedUptime : nil
        ingestChunks = 0
        partialsReceived = 0
        partialsEmitted = 0
        rewriteCount = 0
        triggerPressedUptime = existingTriggerUptime
        triggerToRecordingStartMs = 0
        triggerToAudioEngineStartMs = 0
        triggerToFirstTapMs = 0
        triggerToCaptureReadyMs = 0
        triggerToASRStreamReadyMs = 0
        triggerToFirstPartialMs = 0
        bufferedSamplesFlushedOnStreamReady = 0
        tapToIngestEnqueueTotalMs = 0
        tapToIngestEnqueueSamples = 0
        tapToIngestEnqueueMaxMs = 0
        stopRequestedUptime = nil
        lastStopToFinalMs = 0
    }

    private func elapsedSinceTriggerLocked() -> Double {
        guard let triggerPressedUptime else { return 0 }
        return max(0, (ProcessInfo.processInfo.systemUptime - triggerPressedUptime) * 1_000)
    }
}
