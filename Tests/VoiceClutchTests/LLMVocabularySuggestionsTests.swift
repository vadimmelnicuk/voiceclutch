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

    func testManager_exportPortableVocabulary_usesPortableShapeOnly() throws {
        let manager = makeManager()
        _ = try manager.addManualEntry(from: "VoiceClutch: voice clutch")
        _ = try manager.addShortcutEntry(from: "vc => VoiceClutch")
        _ = try manager.upsertLearnedRule(source: "voice cluch", target: "VoiceClutch")
        _ = try manager.upsertLearnedRule(source: "Badim", target: "Vadim")
        _ = try manager.addLLMSuggestions([
            LLMVocabularySuggestion(
                source: "open ai",
                target: "OpenAI",
                evidence: .transcriptOnly,
                confidence: 0.9,
                targetTermStatus: .new
            )
        ])

        let data = try manager.exportPortableVocabulary()
        let exported = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exportString = try XCTUnwrap(String(data: data, encoding: .utf8))
        let schemaIndex = try XCTUnwrap(exportString.range(of: "\"schemaVersion\"")?.lowerBound)
        let manualIndex = try XCTUnwrap(exportString.range(of: "\"manualEntries\"")?.lowerBound)
        let shortcutIndex = try XCTUnwrap(exportString.range(of: "\"shortcutEntries\"")?.lowerBound)
        let learnedIndex = try XCTUnwrap(exportString.range(of: "\"learnedRules\"")?.lowerBound)
        XCTAssertLessThan(schemaIndex, manualIndex)
        XCTAssertLessThan(schemaIndex, shortcutIndex)
        XCTAssertLessThan(schemaIndex, learnedIndex)
        XCTAssertTrue(exportString.contains("\"manualEntries\": [\n    {"))
        XCTAssertTrue(exportString.contains("\"shortcutEntries\": [\n    {"))
        XCTAssertTrue(exportString.contains("\"learnedRules\": [\n    {"))
        XCTAssertTrue(exportString.contains("},\n    {"))

        XCTAssertEqual(
            Set(exported.keys),
            Set(["schemaVersion", "manualEntries", "shortcutEntries", "learnedRules"])
        )
        XCTAssertEqual(exported["schemaVersion"] as? Int, 1)
        XCTAssertEqual((exported["manualEntries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((exported["shortcutEntries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((exported["learnedRules"] as? [[String: Any]])?.count, 2)
        XCTAssertNil((exported["learnedRules"] as? [[String: Any]])?.first?["count"])
        XCTAssertNil(exported["llmSuggestions"])
    }

    func testManager_importPortableVocabulary_mergeImportWinsOnConflicts() throws {
        let manager = makeManager()
        _ = try manager.addManualEntry(from: "OpenAI: open ai")
        _ = try manager.addShortcutEntry(from: "vc => VoiceClutch")
        _ = try manager.upsertLearnedRule(source: "voice cluch", target: "VoiceClutch")
        _ = try manager.addLLMSuggestions([
            LLMVocabularySuggestion(
                source: "chat gpt",
                target: "ChatGPT",
                evidence: .transcriptOnly,
                confidence: 0.85,
                targetTermStatus: .new
            )
        ])

        let importJSON = #"""
        {
          "schemaVersion": 1,
          "manualEntries": [
            { "canonical": "OpenAI", "aliases": ["oh pen ai"] },
            { "canonical": "ChatGPT", "aliases": ["chat gpt"] }
          ],
          "shortcutEntries": [
            { "trigger": "vc", "replacement": "Voice Clutch" },
            { "trigger": "g p t", "replacement": "GPT" }
          ],
          "learnedRules": [
            { "source": "voice cluch", "target": "VoiceClutch Pro" },
            { "source": "chat g p t", "target": "ChatGPT" }
          ]
        }
        """#
        _ = try manager.importPortableVocabulary(Data(importJSON.utf8))

        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.pendingSuggestions.count, 1)

        guard let openAIEntry = snapshot.manualEntries.first(where: {
            CustomVocabularyManager.normalizedLookupKey($0.canonical) == "openai"
        }) else {
            return XCTFail("Expected imported OpenAI manual entry")
        }
        XCTAssertEqual(Set(openAIEntry.aliases), Set(["oh pen ai"]))

        XCTAssertTrue(snapshot.manualEntries.contains(where: {
            CustomVocabularyManager.normalizedLookupKey($0.canonical) == "chatgpt"
        }))

        guard let vcShortcut = snapshot.shortcutEntries.first(where: {
            CustomVocabularyManager.normalizedLookupKey($0.trigger) == "vc"
        }) else {
            return XCTFail("Expected imported vc shortcut")
        }
        XCTAssertEqual(vcShortcut.replacement, "Voice Clutch")

        XCTAssertTrue(snapshot.shortcutEntries.contains(where: {
            CustomVocabularyManager.normalizedLookupKey($0.trigger) == "g p t"
                && CustomVocabularyManager.normalizedLookupKey($0.replacement) == "gpt"
        }))

        guard let learnedConflict = snapshot.learnedRules.first(where: {
            CustomVocabularyManager.normalizedLookupKey($0.source) == "voice cluch"
                && CustomVocabularyManager.normalizedLookupKey($0.target) == "voiceclutch pro"
        }) else {
            return XCTFail("Expected conflicting learned rule to be overwritten by import")
        }
        XCTAssertEqual(learnedConflict.source, "voice cluch")
        XCTAssertEqual(learnedConflict.target, "VoiceClutch Pro")

        XCTAssertTrue(snapshot.learnedRules.contains(where: {
            CustomVocabularyManager.normalizedLookupKey($0.source) == "chat g p t"
                && CustomVocabularyManager.normalizedLookupKey($0.target) == "chatgpt"
        }))
    }

    func testManager_portableVocabularyExportImportRoundTripPreservesVocabularyData() throws {
        let sourceManager = makeManager()
        _ = try sourceManager.addManualEntry(from: "VoiceClutch: voice clutch, vc")
        _ = try sourceManager.addShortcutEntry(from: "cmd tea => Cmd+T")
        _ = try sourceManager.upsertLearnedRule(source: "open ai", target: "OpenAI")
        _ = try sourceManager.addLLMSuggestions([
            LLMVocabularySuggestion(
                source: "chat gpt",
                target: "ChatGPT",
                evidence: .transcriptOnly,
                confidence: 0.71,
                targetTermStatus: .new
            )
        ])

        let exportedData = try sourceManager.exportPortableVocabulary()
        let targetManager = makeManager()
        _ = try targetManager.importPortableVocabulary(exportedData)

        let sourceSnapshot = sourceManager.snapshot()
        let targetSnapshot = targetManager.snapshot()

        let sourceManual = Dictionary(uniqueKeysWithValues: sourceSnapshot.manualEntries.map {
            (
                CustomVocabularyManager.normalizedLookupKey($0.canonical),
                Set($0.aliases.map(CustomVocabularyManager.normalizedLookupKey))
            )
        })
        let targetManual = Dictionary(uniqueKeysWithValues: targetSnapshot.manualEntries.map {
            (
                CustomVocabularyManager.normalizedLookupKey($0.canonical),
                Set($0.aliases.map(CustomVocabularyManager.normalizedLookupKey))
            )
        })
        XCTAssertEqual(sourceManual, targetManual)

        let sourceShortcuts = Set(sourceSnapshot.shortcutEntries.map {
            "\(CustomVocabularyManager.normalizedLookupKey($0.trigger))->\(CustomVocabularyManager.normalizedLookupKey($0.replacement))"
        })
        let targetShortcuts = Set(targetSnapshot.shortcutEntries.map {
            "\(CustomVocabularyManager.normalizedLookupKey($0.trigger))->\(CustomVocabularyManager.normalizedLookupKey($0.replacement))"
        })
        XCTAssertEqual(sourceShortcuts, targetShortcuts)

        let sourceLearned = Set(sourceSnapshot.learnedRules.map {
            "\(CustomVocabularyManager.normalizedLookupKey($0.source))->\(CustomVocabularyManager.normalizedLookupKey($0.target))"
        })
        let targetLearned = Set(targetSnapshot.learnedRules.map {
            "\(CustomVocabularyManager.normalizedLookupKey($0.source))->\(CustomVocabularyManager.normalizedLookupKey($0.target))"
        })
        XCTAssertEqual(sourceLearned, targetLearned)
        XCTAssertTrue(targetSnapshot.pendingSuggestions.isEmpty)
    }

    func testManager_importPortableVocabulary_invalidDataDoesNotMutateState() throws {
        let manager = makeManager()
        _ = try manager.addManualEntry(from: "VoiceClutch: voice clutch")
        _ = try manager.addShortcutEntry(from: "vc => VoiceClutch")
        _ = try manager.upsertLearnedRule(source: "voice cluch", target: "VoiceClutch")
        let before = manager.snapshot()

        let invalidData = Data("{\"schemaVersion\":1,\"manualEntries\":[".utf8)
        XCTAssertThrowsError(try manager.importPortableVocabulary(invalidData))

        let after = manager.snapshot()
        XCTAssertEqual(before.manualEntries, after.manualEntries)
        XCTAssertEqual(before.shortcutEntries, after.shortcutEntries)
        XCTAssertEqual(before.learnedRules, after.learnedRules)
        XCTAssertEqual(before.pendingSuggestions, after.pendingSuggestions)
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
