import Combine
import Foundation

/// Prepares the shared dictation stack for whichever host owns the UI.
@MainActor
public final class TranscriptionBootstrapper: ObservableObject {
    public enum PreparationOutcome: Sendable {
        case usedExistingModels
        case downloadedModels
    }

    @Published public private(set) var downloadProgress: Double = 0.0

    private let transcriptionSession: TranscriptionSession
    private let downloadManager: ModelDownloadManager
    private var cancellables = Set<AnyCancellable>()

    public convenience init() {
        self.init(
            transcriptionSession: TranscriptionSession(),
            downloadManager: ModelDownloadManager()
        )
    }

    init(
        transcriptionSession: TranscriptionSession,
        downloadManager: ModelDownloadManager
    ) {
        self.transcriptionSession = transcriptionSession
        self.downloadManager = downloadManager
        bindDownloadProgress()
    }

    public var audioManager: AudioManager {
        transcriptionSession.audioManager
    }

    public var isReady: Bool {
        transcriptionSession.isReady
    }

    public var onTranscriptionResult: ((String, Bool) -> Void)? {
        get { transcriptionSession.onTranscriptionResult }
        set { transcriptionSession.onTranscriptionResult = newValue }
    }

    public func areModelsInstalled() -> Bool {
        ModelDownloadManager.areModelsInstalled()
    }

    public func requiredDownloadSize() async -> Int64? {
        try? await downloadManager.getDownloadSize()
    }

    public func prepareForUse(onModelLoading: (() -> Void)? = nil) async throws -> PreparationOutcome {
        let hadExistingModels = areModelsInstalled()

        if !hadExistingModels {
            try await downloadManager.downloadAsrModels()
        }

        onModelLoading?()
        try await transcriptionSession.prepare()
        return hadExistingModels ? .usedExistingModels : .downloadedModels
    }

    public func startRecording(onCaptureReady: (@MainActor @Sendable () -> Void)? = nil) throws {
        try transcriptionSession.startRecording(onCaptureReady: onCaptureReady)
    }

    public func stopRecording() {
        transcriptionSession.stopRecording()
    }

    @discardableResult
    public func playStartChime() -> Bool {
        transcriptionSession.playStartChime()
    }

    @discardableResult
    public func playStopChime() -> Bool {
        transcriptionSession.playStopChime()
    }

    @discardableResult
    public func compactMemoryIfIdle() -> Bool {
        transcriptionSession.compactMemoryIfIdle()
    }

    public func shutdown() {
        transcriptionSession.shutdown()
    }

    private func bindDownloadProgress() {
        downloadManager.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.downloadProgress = progress
            }
            .store(in: &cancellables)
    }
}
