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

    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
    }

    /// Prepare the ASR pipeline so recording can begin immediately.
    func prepare() async throws {
        if isReady {
            return
        }

        let processor = try await ASRProcessor()
        try await processor.preload()
        try await processor.warmUpIfNeeded()

        asrProcessor = processor
        audioManager.setASRProcessor(processor)
        isReady = true
    }

    /// Start a recording and forward partial/final transcription results.
    func startRecording() throws {
        guard isReady else {
            throw SessionError.notReady
        }

        try audioManager.startRecording { [weak self] text, isFinal in
            guard let self else { return }

            Task { @MainActor in
                self.onTranscriptionResult?(text, isFinal)
            }
        }
    }

    func stopRecording() {
        audioManager.stopRecording()
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
