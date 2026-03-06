import Foundation

public struct StreamingMetricsSnapshot: Sendable {
    public let ingestChunks: Int
    public let partialsReceived: Int
    public let partialsEmitted: Int
    public let rewriteCount: Int
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
    private var tapToIngestEnqueueTotalMs = 0.0
    private var tapToIngestEnqueueSamples = 0
    private var tapToIngestEnqueueMaxMs = 0.0
    private var stopRequestedUptime: TimeInterval?
    private var lastStopToFinalMs = 0.0

    private init() {}

    func resetForSession() {
        lock.lock()
        ingestChunks = 0
        partialsReceived = 0
        partialsEmitted = 0
        rewriteCount = 0
        tapToIngestEnqueueTotalMs = 0
        tapToIngestEnqueueSamples = 0
        tapToIngestEnqueueMaxMs = 0
        stopRequestedUptime = nil
        lastStopToFinalMs = 0
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
            tapToIngestEnqueueAverageMs: averageMs,
            tapToIngestEnqueueMaxMs: tapToIngestEnqueueMaxMs,
            lastStopToFinalMs: lastStopToFinalMs
        )
        lock.unlock()
        return snapshot
    }
}
