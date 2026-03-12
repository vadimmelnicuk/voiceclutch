import Combine
import Foundation

/// Coordinates dictation state, preparation, and text delivery for the app host.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: VoiceClutchState = .idle
    @Published public private(set) var downloadProgress: Double = 0.0

    private let bootstrapper: TranscriptionBootstrapper
    private var cancellables = Set<AnyCancellable>()
    private var processingTimeoutTask: Task<Void, Never>?
    private var latestPartialText: String = ""
    private var lastInjectedPartialText: String = ""
    private var isAwaitingFinalResult = false

    public init(bootstrapper: TranscriptionBootstrapper = TranscriptionBootstrapper()) {
        self.bootstrapper = bootstrapper

        bootstrapper.onTranscriptionResult = { [weak self] text, isFinal in
            self?.handleTranscriptionResult(text, isFinal: isFinal)
        }

        bootstrapper.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.downloadProgress = progress
            }
            .store(in: &cancellables)
    }

    public var audioManager: AudioManager {
        bootstrapper.audioManager
    }

    public var isReady: Bool {
        bootstrapper.isReady
    }

    public func setState(_ nextState: VoiceClutchState) {
        state = nextState
    }

    public func areModelsInstalled() -> Bool {
        bootstrapper.areModelsInstalled()
    }

    public func requiredDownloadSize() async -> Int64? {
        await bootstrapper.requiredDownloadSize()
    }

    @discardableResult
    public func prepareForUse() async throws -> TranscriptionBootstrapper.PreparationOutcome {
        let outcome = try await bootstrapper.prepareForUse { [weak self] in
            self?.state = .loadingModel
        }
        state = .idle
        return outcome
    }

    public func startRecording() throws {
        guard state == .idle else { return }
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        resetPartialState()
        isAwaitingFinalResult = false

        guard isReady else {
            throw TranscriptionSession.SessionError.notReady
        }

        state = .recording

        do {
            try bootstrapper.startRecording()
            TextInjector.beginStreamingSession()
        } catch {
            state = .idle
            resetPartialState()
            isAwaitingFinalResult = false
            TextInjector.cancelStreamingSession()
            throw error
        }
    }

    public func stopRecording() {
        guard state == .recording else { return }
        state = .processing
        isAwaitingFinalResult = true
        bootstrapper.stopRecording()

        processingTimeoutTask?.cancel()
        processingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000_000)
            await MainActor.run {
                guard let self, self.state == .processing, self.isAwaitingFinalResult else { return }
                self.isAwaitingFinalResult = false
                let fallbackText = self.latestPartialText
                TextInjector.commitStreamingFinalNormalized(fallbackText)
                self.resetPartialState()
                self.state = .idle
            }
        }
    }

    public func shutdown() {
        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        resetPartialState()
        isAwaitingFinalResult = false
        TextInjector.cancelStreamingSession()
        bootstrapper.shutdown()
        state = .idle
    }

    @discardableResult
    func compactMemoryIfIdle() -> Bool {
        guard state == .idle, !isAwaitingFinalResult else {
            return false
        }

        processingTimeoutTask?.cancel()
        processingTimeoutTask = nil
        resetPartialState()
        TextInjector.cancelStreamingSession()
        return bootstrapper.compactMemoryIfIdle()
    }

    private func handleTranscriptionResult(_ text: String, isFinal: Bool) {
        if isFinal {
            guard isAwaitingFinalResult else { return }
            isAwaitingFinalResult = false
            processingTimeoutTask?.cancel()
            processingTimeoutTask = nil
            let normalizedFinalText = TextInjector.normalizedStreamingTranscript(text)
            let stabilizedFinalText = stabilizedTranscript(normalizedFinalText, previous: latestPartialText)
            let finalText = !stabilizedFinalText.isEmpty ? stabilizedFinalText : latestPartialText
            TextInjector.commitStreamingFinalNormalized(finalText)
            resetPartialState()
            state = .idle
            return
        }

        // Ignore post-release partials while processing final ASR output.
        // This avoids release-tail punctuation churn from rewriting already
        // injected text; only the final transcript should apply in this phase.
        guard state == .recording, !text.isEmpty else {
            return
        }

        let normalizedPartialText = TextInjector.normalizedStreamingTranscript(text)
        guard !normalizedPartialText.isEmpty else {
            return
        }

        let stabilizedPartialText = stabilizedTranscript(normalizedPartialText, previous: latestPartialText)
        latestPartialText = stabilizedPartialText
        guard shouldInjectPartial(stabilizedPartialText) else { return }
        TextInjector.updateStreamingPartialNormalized(stabilizedPartialText)
    }

    private func resetPartialState() {
        latestPartialText = ""
        lastInjectedPartialText = ""
    }

    private func shouldInjectPartial(_ text: String) -> Bool {
        guard text != lastInjectedPartialText else { return false }
        lastInjectedPartialText = text
        return true
    }

    private func stabilizedTranscript(_ candidate: String, previous: String) -> String {
        guard !candidate.isEmpty, !previous.isEmpty else {
            return candidate
        }

        guard candidate.hasPrefix(previous) else {
            return candidate
        }

        let suffixStart = candidate.index(candidate.startIndex, offsetBy: previous.count)
        let suffix = String(candidate[suffixStart...])
        guard let overlapLength = duplicatedJoinOverlapLength(previous: previous, suffix: suffix) else {
            return candidate
        }

        let trimmedSuffixStart = suffix.index(suffix.startIndex, offsetBy: overlapLength)
        let stabilized = previous + suffix[trimmedSuffixStart...]
        return stabilized.count < candidate.count ? stabilized : candidate
    }

    private func duplicatedJoinOverlapLength(previous: String, suffix: String) -> Int? {
        guard !suffix.isEmpty else { return nil }

        let maxOverlap = min(previous.count, suffix.count)
        guard maxOverlap >= 3 else { return nil }

        for overlapLength in stride(from: maxOverlap, through: 3, by: -1) {
            let previousStart = previous.index(previous.endIndex, offsetBy: -overlapLength)
            let previousOverlap = previous[previousStart...]
            let suffixEnd = suffix.index(suffix.startIndex, offsetBy: overlapLength)
            let suffixOverlap = suffix[..<suffixEnd]

            guard previousOverlap.caseInsensitiveCompare(String(suffixOverlap)) == .orderedSame else {
                continue
            }

            guard hasWordBoundary(before: previousStart, in: previous) else {
                continue
            }

            guard hasWordBoundary(after: suffixEnd, in: suffix) else {
                continue
            }

            return overlapLength
        }

        return nil
    }

    private func hasWordBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let precedingIndex = text.index(before: index)
        return !isAlphaNumeric(text[precedingIndex])
    }

    private func hasWordBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return !isAlphaNumeric(text[index])
    }

    private func isAlphaNumeric(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
