import Foundation

/// Coordinates audio capture and ASR for a single dictation host.
@MainActor
final class TranscriptionSession {
    enum SessionError: Error {
        case notReady
    }

    let audioManager: AudioManager
    private var asrProcessor: ASRProcessor?
    private(set) var isReady = false

    var onTranscriptionResult: ((String, Bool) -> Void)?
    var onStateChange: ((VoiceClutchState) -> Void)?

    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
    }

    /// Prepare the ASR pipeline so recording can begin immediately.
    func prepare() async throws {
        if isReady {
            return
        }

        let prepareStart = Date()
        let processor = try await ASRProcessor()

        let preloadStart = Date()
        try await processor.preload()
        let preloadDuration = Date().timeIntervalSince(preloadStart)

        let warmUpStart = Date()
        var warmUpError: Error?
        onStateChange?(.warmingUp)
        do {
            try await processor.warmUpIfNeeded()
        } catch {
            warmUpError = error
        }
        let warmUpDuration = Date().timeIntervalSince(warmUpStart)

        asrProcessor = processor
        audioManager.setASRProcessor(processor)
        isReady = true
        onStateChange?(.idle)

        let totalDuration = Date().timeIntervalSince(prepareStart)
        debugLogPrepareTimings(
            totalDuration: totalDuration,
            preloadDuration: preloadDuration,
            warmUpDuration: warmUpDuration,
            warmUpError: warmUpError
        )
    }

    private func debugLogPrepareTimings(
        totalDuration: TimeInterval,
        preloadDuration: TimeInterval,
        warmUpDuration: TimeInterval,
        warmUpError: Error?
    ) {
        #if DEBUG
        let totalMs = Int((totalDuration * 1_000).rounded())
        let preloadMs = Int((preloadDuration * 1_000).rounded())
        let warmUpMs = Int((warmUpDuration * 1_000).rounded())
        let warmUpStatus = warmUpError == nil ? "success" : "failed"

        print("⏱️ ASR prepare total=\(totalMs)ms preload=\(preloadMs)ms warmup=\(warmUpMs)ms status=\(warmUpStatus)")

        if let warmUpError {
            print("⚠️ ASR warm-up failed: \(warmUpError)")
        }
        #endif
    }

    /// Start a recording and forward partial/final transcription results.
    func startRecording(onCaptureReady: (@MainActor @Sendable () -> Void)? = nil) throws {
        guard isReady else {
            throw SessionError.notReady
        }

        try audioManager.startRecording(
            callback: { [weak self] text, isFinal in
                guard let self else { return }

                Task { @MainActor in
                    self.onTranscriptionResult?(text, isFinal)
                }
            },
            onCaptureReady: onCaptureReady
        )
    }

    func stopRecording() {
        audioManager.stopRecording()
    }

    @discardableResult
    func playStartChime() -> Bool {
        audioManager.playStartChime()
    }

    @discardableResult
    func playStopChime() -> Bool {
        audioManager.playStopChime()
    }

    @discardableResult
    func compactMemoryIfIdle() -> Bool {
        audioManager.compactMemoryIfIdle()
    }

    func shutdown() {
        audioManager.cancelRecording()
        let processor = asrProcessor
        Task {
            await processor?.releaseModel()
        }
        asrProcessor = nil
        isReady = false
    }
}
