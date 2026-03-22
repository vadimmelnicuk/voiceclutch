import XCTest
@testable import VoiceClutch

final class VocabularyListBuilderTests: XCTestCase {
    func testRows_prioritizePendingSuggestionsByMostRecent() {
        let olderSuggestionID = UUID()
        let newerSuggestionID = UUID()
        let olderTime = Date(timeIntervalSince1970: 1_700_000_000)
        let newerTime = Date(timeIntervalSince1970: 1_700_100_000)
        let snapshot = CustomVocabularySnapshot(
            pendingSuggestions: [
                LLMVocabularySuggestion(
                    id: olderSuggestionID,
                    source: "voice clutch",
                    target: "VoiceClutch",
                    evidence: .transcriptOnly,
                    confidence: 0.99,
                    targetTermStatus: .existing,
                    createdAt: olderTime,
                    updatedAt: olderTime
                ),
                LLMVocabularySuggestion(
                    id: newerSuggestionID,
                    source: "open ai",
                    target: "OpenAI",
                    evidence: .userEdit,
                    confidence: 0.10,
                    targetTermStatus: .existing,
                    createdAt: newerTime,
                    updatedAt: newerTime
                )
            ]
        )

        let rows = VocabularyListBuilder.rows(from: snapshot)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].kind, .suggestion(newerSuggestionID))
        XCTAssertEqual(rows[1].kind, .suggestion(olderSuggestionID))
        XCTAssertTrue(rows.allSatisfy(\.highlightsSuggestion))
    }

    func testRows_sortSavedEntriesByMostRecentAfterSuggestions() {
        let shortcutID = UUID()
        let learnedID = UUID()
        let olderTime = Date(timeIntervalSince1970: 1_700_000_000)
        let newerTime = Date(timeIntervalSince1970: 1_700_100_000)
        let suggestionTime = Date(timeIntervalSince1970: 1_700_200_000)
        let suggestionID = UUID()
        let snapshot = CustomVocabularySnapshot(
            manualEntries: [
                ManualVocabularyEntry(canonical: "VoiceClutch", aliases: ["voice clutch"])
            ],
            shortcutEntries: [
                ShortcutVocabularyEntry(
                    id: shortcutID,
                    trigger: "cmd tea",
                    replacement: "Cmd+T",
                    createdAt: olderTime,
                    updatedAt: olderTime
                )
            ],
            learnedRules: [
                LearnedCorrectionRule(
                    id: learnedID,
                    source: "open ai",
                    target: "OpenAI",
                    createdAt: newerTime,
                    updatedAt: newerTime
                )
            ],
            pendingSuggestions: [
                LLMVocabularySuggestion(
                    id: suggestionID,
                    source: "voice cluch",
                    target: "VoiceClutch",
                    evidence: .userEdit,
                    confidence: 0.8,
                    targetTermStatus: .new,
                    createdAt: suggestionTime,
                    updatedAt: suggestionTime
                )
            ]
        )

        let rows = VocabularyListBuilder.rows(from: snapshot)
        let kinds: [VocabularyRowKind] = rows.map { $0.kind }

        XCTAssertEqual(kinds, [
            .suggestion(suggestionID),
            .learned(learnedID),
            .shortcut(shortcutID),
            .manual("VoiceClutch")
        ])
    }

    func testRows_keepManualCanonicalAndShortcutIdentifierForActions() {
        let shortcutID = UUID()
        let snapshot = CustomVocabularySnapshot(
            manualEntries: [
                ManualVocabularyEntry(canonical: "OpenAI", aliases: ["open ai"])
            ],
            shortcutEntries: [
                ShortcutVocabularyEntry(id: shortcutID, trigger: "vc name", replacement: "VoiceClutch")
            ]
        )

        let rows = VocabularyListBuilder.rows(from: snapshot)

        XCTAssertEqual(VocabularyListBuilder.pendingSuggestionCount(in: snapshot), 0)
        XCTAssertEqual(VocabularyListBuilder.savedEntryCount(in: snapshot), 2)
        XCTAssertTrue(rows.contains(where: { $0.kind == .manual("OpenAI") }))
        XCTAssertTrue(rows.contains(where: { $0.kind == .shortcut(shortcutID) }))

        guard let manualRow = rows.first(where: { $0.kind == .manual("OpenAI") }) else {
            return XCTFail("Missing manual row")
        }
        guard let shortcutRow = rows.first(where: { $0.kind == .shortcut(shortcutID) }) else {
            return XCTFail("Missing shortcut row")
        }
        XCTAssertEqual(manualRow.replacementText, "OpenAI")
        XCTAssertEqual(shortcutRow.sourceText, "vc name")
    }
}
