import Foundation

actor VocabularySuggestionOrchestrator {
    nonisolated static let shared = VocabularySuggestionOrchestrator()

    private let vocabularyManager: CustomVocabularyManager
    private let isAutoCorrectionsEnabled: @Sendable () -> Bool
    private let logger = AppLogger(category: "VocabularySuggestions")

    init(
        vocabularyManager: CustomVocabularyManager = .shared,
        isAutoCorrectionsEnabled: @escaping @Sendable () -> Bool = { AutoAddCorrectionsPreference.load() }
    ) {
        self.vocabularyManager = vocabularyManager
        self.isAutoCorrectionsEnabled = isAutoCorrectionsEnabled
    }

    func processUserEditSignal(
        source: String,
        target: String,
        editedTranscript: String
    ) async {
        guard shouldGenerateSuggestions() else {
            return
        }

        let cleanedSource = CustomVocabularyManager.sanitizedTerm(source)
        let cleanedTarget = CustomVocabularyManager.sanitizedTerm(target)
        let cleanedTranscript = editedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSource.isEmpty, !cleanedTarget.isEmpty else {
            return
        }
        guard !cleanedTranscript.isEmpty else {
            return
        }

        let snapshot = vocabularyManager.snapshot()
        let normalizedTarget = CustomVocabularyManager.normalizedLookupKey(cleanedTarget)
        guard !normalizedTarget.isEmpty else {
            return
        }

        let targetStatus = CustomVocabularyManager.targetTermStatus(
            for: cleanedTarget,
            snapshot: snapshot
        )
        guard targetStatus != .existing else {
            logger.debug("Skipped manual-edit suggestion because target already exists in saved vocabulary")
            return
        }

        if snapshot.pendingSuggestions.contains(where: {
            $0.normalizedTarget == normalizedTarget
                || CustomVocabularyManager.normalizedLookupKey($0.target) == normalizedTarget
        }) {
            logger.debug("Skipped manual-edit suggestion because target already exists in pending suggestions")
            return
        }

        do {
            let suggestion = LLMVocabularySuggestion(
                source: cleanedSource,
                target: cleanedTarget,
                evidence: .userEdit,
                confidence: 0.99,
                targetTermStatus: targetStatus
            )
            let suggestions = [suggestion]
            _ = try vocabularyManager.addLLMSuggestions(suggestions)
            logger.info("Persisted \(suggestions.count) manual-edit vocabulary suggestion(s)")
        } catch {
            logger.warning("Failed to persist manual-edit vocabulary suggestions: \(error.localizedDescription)")
        }
    }

    private func shouldGenerateSuggestions() -> Bool {
        isAutoCorrectionsEnabled()
    }
}
