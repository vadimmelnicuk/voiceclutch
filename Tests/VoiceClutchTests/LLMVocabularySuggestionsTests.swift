import XCTest
@testable import VoiceClutch

final class LocalLLMVocabularySuggestionFlowTests: XCTestCase {
    private struct MockSession: LocalLLMGeneratingSession {
        let responseProvider: @Sendable (String) -> String

        func respond(to prompt: String) async throws -> String {
            responseProvider(prompt)
        }
    }

    private func makeCoordinator(response: @escaping @Sendable (String) -> String) -> LocalLLMCoordinator {
        LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                MockSession(responseProvider: response)
            }
        )
    }

    func testGenerateVocabularySuggestions_parsesAndValidatesStructuredResponse() async {
        let coordinator = makeCoordinator { _ in
            #"""
            {
              "suggestions": [
                {
                  "source": "voice clutch",
                  "target": "VoiceClutch",
                  "evidence": "transcript_only",
                  "confidence": 0.92,
                  "target_term_status": "existing"
                }
              ]
            }
            """#
        }

        let vocabulary = CustomVocabularySnapshot(
            manualEntries: [
                ManualVocabularyEntry(canonical: "VoiceClutch", aliases: ["voice clutch"])
            ]
        )
        let request = LocalLLMVocabularySuggestionRequest(
            transcript: "please use voice clutch for this app name",
            vocabulary: vocabulary
        )

        let suggestions = await coordinator.generateVocabularySuggestions(request)

        XCTAssertEqual(suggestions.count, 1)
        guard let first = suggestions.first else {
            return XCTFail("Expected at least one suggestion")
        }
        XCTAssertEqual(first.source, "voice clutch")
        XCTAssertEqual(first.target, "VoiceClutch")
        XCTAssertEqual(first.evidence, .transcriptOnly)
        XCTAssertEqual(first.targetTermStatus, .existing)
    }

    func testGenerateVocabularySuggestions_rejectsUnsafeAndLowConfidenceSuggestions() async {
        let coordinator = makeCoordinator { _ in
            #"""
            {
              "suggestions": [
                {
                  "source": "deploy checklist",
                  "target": "https://example.com/checklist",
                  "evidence": "transcript_only",
                  "confidence": 0.95,
                  "target_term_status": "new"
                },
                {
                  "source": "voice cluch",
                  "target": "VoiceClutch",
                  "evidence": "transcript_only",
                  "confidence": 0.45,
                  "target_term_status": "existing"
                }
              ]
            }
            """#
        }

        let request = LocalLLMVocabularySuggestionRequest(
            transcript: "voice cluch should be fixed",
            vocabulary: .init()
        )
        let suggestions = await coordinator.generateVocabularySuggestions(request)
        XCTAssertTrue(suggestions.isEmpty)
    }
}

final class CustomVocabularyManagerSuggestionLifecycleTests: XCTestCase {
    private func makeManager() -> CustomVocabularyManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = root.appendingPathComponent("custom-vocabulary-v2.json")
        let legacyURL = root.appendingPathComponent("custom-vocabulary-legacy.json")
        return CustomVocabularyManager(storageURL: storageURL, legacyStorageURL: legacyURL)
    }

    func testManager_dedupesPendingSuggestionsAndMergesEvidence() throws {
        let manager = makeManager()

        let first = LLMVocabularySuggestion(
            source: "voice clutch",
            target: "VoiceClutch",
            evidence: .transcriptOnly,
            confidence: 0.82,
            targetTermStatus: .existing
        )
        let second = LLMVocabularySuggestion(
            source: "voice clutch",
            target: "VoiceClutch",
            evidence: .userEdit,
            confidence: 0.91,
            targetTermStatus: .existing
        )

        _ = try manager.addLLMSuggestions([first, second])
        let pending = manager.snapshot().pendingSuggestions

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].evidence, .mixed)
        XCTAssertEqual(pending[0].confidence, 0.91, accuracy: 0.0001)
    }

    func testManager_approveSuggestionPromotesToLearnedRuleAndRemovesPending() throws {
        let manager = makeManager()

        let suggestion = LLMVocabularySuggestion(
            source: "voice clutch",
            target: "VoiceClutch",
            evidence: .transcriptOnly,
            confidence: 0.9,
            targetTermStatus: .existing
        )
        _ = try manager.addLLMSuggestions([suggestion])
        guard let suggestionID = manager.snapshot().pendingSuggestions.first?.id else {
            return XCTFail("Expected pending suggestion")
        }

        _ = try manager.approveLLMSuggestion(id: suggestionID)
        let snapshot = manager.snapshot()

        XCTAssertTrue(snapshot.pendingSuggestions.isEmpty)
        XCTAssertTrue(
            snapshot.learnedRules.contains(where: {
                CustomVocabularyManager.normalizedLookupKey($0.source) == "voice clutch" &&
                    CustomVocabularyManager.normalizedLookupKey($0.target) == "voiceclutch"
            })
        )
    }

    func testManager_dismissAndClearSuggestionHistory() throws {
        let manager = makeManager()
        let suggestion = LLMVocabularySuggestion(
            source: "open ai",
            target: "OpenAI",
            evidence: .transcriptOnly,
            confidence: 0.88,
            targetTermStatus: .new
        )
        _ = try manager.addLLMSuggestions([suggestion])
        guard let suggestionID = manager.snapshot().pendingSuggestions.first?.id else {
            return XCTFail("Expected pending suggestion")
        }

        _ = try manager.dismissLLMSuggestion(id: suggestionID)
        XCTAssertEqual(manager.llmSuggestions(status: .dismissed).count, 1)

        _ = try manager.clearDismissedAndOldSuggestions(maxAgeDays: 1)
        XCTAssertTrue(manager.llmSuggestions(status: .dismissed).isEmpty)
    }

    func testManager_migratesV2StoreToV3WithoutDataLoss() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storageURL = root.appendingPathComponent("custom-vocabulary-v2.json")
        let legacyURL = root.appendingPathComponent("custom-vocabulary-legacy.json")

        let v2JSON = #"""
        {
          "schemaVersion": 2,
          "manualEntries": [{ "canonical": "OpenAI", "aliases": ["open ai"] }],
          "shortcutEntries": [],
          "learnedRules": [],
          "createdAt": "2026-03-17T00:00:00Z",
          "updatedAt": "2026-03-17T00:00:00Z"
        }
        """#
        guard let data = v2JSON.data(using: .utf8) else {
            return XCTFail("Failed to create fixture data")
        }
        try data.write(to: storageURL)

        let manager = CustomVocabularyManager(storageURL: storageURL, legacyStorageURL: legacyURL)
        let snapshot = manager.snapshot()

        XCTAssertEqual(snapshot.manualEntries.count, 1)
        XCTAssertEqual(snapshot.manualEntries.first?.canonical, "OpenAI")
        XCTAssertTrue(snapshot.pendingSuggestions.isEmpty)
    }

    func testManager_updateShortcutEntryByID() throws {
        let manager = makeManager()
        _ = try manager.addShortcutEntry(from: "Casey => Casy")
        guard let id = manager.snapshot().shortcutEntries.first?.id else {
            return XCTFail("Expected shortcut entry")
        }

        _ = try manager.updateShortcutEntry(id: id, trigger: "KC", replacement: "Casy")

        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.shortcutEntries.count, 1)
        XCTAssertEqual(snapshot.shortcutEntries.first?.id, id)
        XCTAssertEqual(snapshot.shortcutEntries.first?.trigger, "KC")
        XCTAssertEqual(snapshot.shortcutEntries.first?.replacement, "Casy")
    }

    func testManager_updateLearnedRuleByID() throws {
        let manager = makeManager()
        _ = try manager.upsertLearnedRule(source: "Casey", target: "Casy")
        guard let id = manager.snapshot().learnedRules.first?.id else {
            return XCTFail("Expected learned rule")
        }

        _ = try manager.updateLearnedRule(id: id, source: "KC", target: "Casy")

        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.learnedRules.count, 1)
        XCTAssertEqual(snapshot.learnedRules.first?.id, id)
        XCTAssertEqual(snapshot.learnedRules.first?.source, "KC")
        XCTAssertEqual(snapshot.learnedRules.first?.target, "Casy")
    }

    func testManager_updateLearnedRuleWithAliasListProducesMultipleRewriteRules() throws {
        let manager = makeManager()
        _ = try manager.upsertLearnedRule(source: "Case", target: "Casey")
        guard let id = manager.snapshot().learnedRules.first?.id else {
            return XCTFail("Expected learned rule")
        }

        _ = try manager.updateLearnedRule(id: id, source: "Casey, KC", target: "Casy")
        let rules = manager.rewriteRules()

        XCTAssertTrue(rules.contains(where: { $0.source == "Casey" && $0.replacement == "Casy" }))
        XCTAssertTrue(rules.contains(where: { $0.source == "KC" && $0.replacement == "Casy" }))
    }

    func testManager_updateShortcutWithAliasListProducesMultipleRewriteRules() throws {
        let manager = makeManager()
        _ = try manager.addShortcutEntry(from: "Case => Casey")
        guard let id = manager.snapshot().shortcutEntries.first?.id else {
            return XCTFail("Expected shortcut entry")
        }

        _ = try manager.updateShortcutEntry(id: id, trigger: "Casey, KC", replacement: "Casy")
        let rules = manager.rewriteRules()

        XCTAssertTrue(rules.contains(where: { $0.source == "Casey" && $0.replacement == "Casy" }))
        XCTAssertTrue(rules.contains(where: { $0.source == "KC" && $0.replacement == "Casy" }))
    }

    func testManager_updateManualEntryByCanonicalKey() throws {
        let manager = makeManager()
        _ = try manager.addManualEntry(from: "VoiceClutch: voice clutch")

        _ = try manager.updateManualEntry(
            existingCanonical: "VoiceClutch",
            canonical: "VoiceClutch",
            aliases: ["vc", "voice clutch"]
        )

        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.manualEntries.count, 1)
        XCTAssertEqual(snapshot.manualEntries.first?.canonical, "VoiceClutch")
        XCTAssertEqual(Set(snapshot.manualEntries.first?.aliases ?? []), Set(["voice clutch", "vc"]))
    }
}

final class VocabularySuggestionOrchestratorTests: XCTestCase {
    private func makeManager() -> CustomVocabularyManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = root.appendingPathComponent("custom-vocabulary-v2.json")
        let legacyURL = root.appendingPathComponent("custom-vocabulary-legacy.json")
        return CustomVocabularyManager(storageURL: storageURL, legacyStorageURL: legacyURL)
    }

    func testOrchestrator_userEditSignalCreatesSinglePendingSuggestion() async {
        let manager = makeManager()
        let orchestrator = VocabularySuggestionOrchestrator(
            vocabularyManager: manager,
            isAutoCorrectionsEnabled: { true }
        )

        await orchestrator.processUserEditSignal(
            source: "voice clutch",
            target: "VoiceClutch",
            editedTranscript: "please use VoiceClutch for this"
        )

        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.pendingSuggestions.count, 1)
        XCTAssertTrue(snapshot.learnedRules.isEmpty)
        XCTAssertEqual(snapshot.pendingSuggestions[0].evidence, .userEdit)
    }

    func testOrchestrator_autoCorrectionsGatePreventsEnqueue() async {
        let manager = makeManager()
        let orchestrator = VocabularySuggestionOrchestrator(
            vocabularyManager: manager,
            isAutoCorrectionsEnabled: { false }
        )

        await orchestrator.processUserEditSignal(
            source: "voice clutch",
            target: "VoiceClutch",
            editedTranscript: "use VoiceClutch for this"
        )

        XCTAssertTrue(manager.snapshot().pendingSuggestions.isEmpty)
    }

    func testOrchestrator_dedupesRepeatedUserEditSignals() async {
        let manager = makeManager()
        let orchestrator = VocabularySuggestionOrchestrator(
            vocabularyManager: manager,
            isAutoCorrectionsEnabled: { true }
        )

        await orchestrator.processUserEditSignal(
            source: "voice clutch",
            target: "VoiceClutch",
            editedTranscript: "use VoiceClutch for this"
        )
        await orchestrator.processUserEditSignal(
            source: "voice clutch",
            target: "VoiceClutch",
            editedTranscript: "ship VoiceClutch now"
        )

        let pending = manager.snapshot().pendingSuggestions
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].evidence, .userEdit)
    }

    func testOrchestrator_skipsWhenTargetAlreadyExistsInSavedVocabulary() async throws {
        let manager = makeManager()
        _ = try manager.addManualEntry(from: "VoiceClutch: voice clutch")

        let orchestrator = VocabularySuggestionOrchestrator(
            vocabularyManager: manager,
            isAutoCorrectionsEnabled: { true }
        )

        await orchestrator.processUserEditSignal(
            source: "vc",
            target: "VoiceClutch",
            editedTranscript: "use VoiceClutch here"
        )

        XCTAssertTrue(manager.snapshot().pendingSuggestions.isEmpty)
    }

    func testOrchestrator_skipsWhenTargetAlreadyExistsInPendingSuggestions() async throws {
        let manager = makeManager()
        _ = try manager.addLLMSuggestions([
            LLMVocabularySuggestion(
                source: "voice cluch",
                target: "VoiceClutch",
                evidence: .transcriptOnly,
                confidence: 0.91,
                targetTermStatus: .new
            )
        ])

        let orchestrator = VocabularySuggestionOrchestrator(
            vocabularyManager: manager,
            isAutoCorrectionsEnabled: { true }
        )

        await orchestrator.processUserEditSignal(
            source: "vc",
            target: "VoiceClutch",
            editedTranscript: "ship VoiceClutch"
        )

        let pending = manager.snapshot().pendingSuggestions
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(CustomVocabularyManager.normalizedLookupKey(pending[0].target), "voiceclutch")
    }
}
