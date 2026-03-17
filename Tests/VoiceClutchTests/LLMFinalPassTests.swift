import XCTest
@testable import VoiceClutch

final class ListFormattingIntentDetectorTests: XCTestCase {
    func testDetector_returnsNumberedForExplicitOrdinalEnumeration() {
        let context = TranscriptFormattingContext(domain: .general, requiresCodeSyntaxPostEdit: false)
        let transcript = "first option use sqlite second option use postgres third option use redis"

        let hint = ListFormattingIntentDetector.hint(for: transcript, formattingContext: context)

        XCTAssertEqual(hint, .numbered)
    }

    func testDetector_returnsBulletedWhenBulletCueAndMultipleOptionsArePresent() {
        let context = TranscriptFormattingContext(domain: .documents, requiresCodeSyntaxPostEdit: false)
        let transcript = "use bullet points apples, bananas, oranges"

        let hint = ListFormattingIntentDetector.hint(for: transcript, formattingContext: context)

        XCTAssertEqual(hint, .bulleted)
    }

    func testDetector_returnsNoneWhenOnlySingleEnumerationSignalExists() {
        let context = TranscriptFormattingContext(domain: .general, requiresCodeSyntaxPostEdit: false)
        let transcript = "first we should evaluate all options carefully"

        let hint = ListFormattingIntentDetector.hint(for: transcript, formattingContext: context)

        XCTAssertEqual(hint, .none)
    }

    func testDetector_disablesListIntentInCodeAndTerminalContexts() {
        let transcript = "first option use sqlite second option use postgres"

        let codeContext = TranscriptFormattingContext(domain: .code, requiresCodeSyntaxPostEdit: true)
        let terminalContext = TranscriptFormattingContext(domain: .terminal, requiresCodeSyntaxPostEdit: true)

        XCTAssertEqual(ListFormattingIntentDetector.hint(for: transcript, formattingContext: codeContext), .none)
        XCTAssertEqual(ListFormattingIntentDetector.hint(for: transcript, formattingContext: terminalContext), .none)
    }
}

final class ListFormattingPromptBuilderTests: XCTestCase {
    func testLocalPromptBuilder_includesNumberedListInstructionWhenHintIsNumbered() {
        let builder = LocalLLMSmartFormattingPromptBuilder()
        let request = LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: "first option use sqlite second option use postgres",
            deterministicTranscript: "first option use sqlite second option use postgres",
            vocabulary: .init(),
            formattingContext: TranscriptFormattingContext(domain: .general, requiresCodeSyntaxPostEdit: false),
            listFormattingHint: .numbered
        )

        let prompt = builder.buildPrompt(for: request)

        XCTAssertTrue(prompt.contains("vertical numbered list using '1. '"))
        XCTAssertTrue(prompt.contains("Preserve original option wording and order"))
    }

    func testConstrainedPromptBuilder_usesMinimalContractAndJsonInput() {
        let builder = ConstrainedFormattingPromptBuilder()
        let request = LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: "use bullet points apples, bananas, oranges",
            deterministicTranscript: "use bullet points apples, bananas, oranges",
            vocabulary: .init(),
            formattingContext: TranscriptFormattingContext(domain: .general, requiresCodeSyntaxPostEdit: false),
            listFormattingHint: .bulleted
        )

        let prompt = builder.buildPrompt(for: request, extendedContext: .empty)

        XCTAssertTrue(prompt.contains("Improve dictated text for clarity and intended meaning."))
        XCTAssertTrue(prompt.contains("Preserve core intent and factual content."))
        XCTAssertTrue(prompt.contains("You may rephrase when needed to fix likely ASR wording errors and improve clarity while preserving intent."))
        XCTAssertTrue(prompt.contains("Remove obvious filler words when they reduce clarity."))
        XCTAssertTrue(prompt.contains("Do not copy instruction text into final_text."))
        XCTAssertTrue(prompt.contains("Return one valid JSON object with exactly one key:"))
        XCTAssertTrue(prompt.contains("{\"final_text\":\"...\"}"))
        XCTAssertTrue(prompt.contains("No markdown. No extra keys. No extra text."))
        XCTAssertTrue(prompt.contains("Input JSON:"))
        XCTAssertTrue(prompt.contains("\"transcript\":"))
        XCTAssertTrue(prompt.contains(#""transcript":"use bullet points apples, bananas, oranges""#))
        XCTAssertFalse(prompt.contains("LIST FORMAT HINT:"))
    }

    func testConstrainedPromptBuilder_jsonInputEscapesTranscriptContent() {
        let builder = ConstrainedFormattingPromptBuilder()
        let request = LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: #"say "hello" then new line"#,
            deterministicTranscript: "say \"hello\"\nthen new line",
            vocabulary: .init(),
            formattingContext: TranscriptFormattingContext(domain: .general, requiresCodeSyntaxPostEdit: false)
        )

        let prompt = builder.buildPrompt(for: request, extendedContext: .empty)

        XCTAssertTrue(prompt.contains(#""transcript":"say \"hello\"\nthen new line""#))
    }
}

#if canImport(MLXLLM) && canImport(MLXLMCommon)
final class LocalLLMCoordinatorListSanitizationTests: XCTestCase {
    private struct MockSession: LocalLLMGeneratingSession {
        let response: String

        func respond(to prompt: String) async throws -> String {
            response
        }
    }

    func testCoordinatorPreservesMultilineBulletsAfterSanitize() async {
        let coordinator = LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                MockSession(
                    response: #"{"final_text":"- first option low latency\n- second option better consistency"}"#
                )
            }
        )
        let request = LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: "first option low latency second option better consistency",
            deterministicTranscript: "first option low latency second option better consistency",
            vocabulary: .init(),
            formattingContext: TranscriptFormattingContext(domain: .general, requiresCodeSyntaxPostEdit: false),
            listFormattingHint: .bulleted
        )

        let result = await coordinator.process(request)

        XCTAssertEqual(result.outcome, .refined)
        XCTAssertEqual(
            result.transcript,
            "- first option low latency\n- second option better consistency"
        )
        XCTAssertTrue(result.transcript.contains("\n- second option"))
    }
}
#endif

final class LocalLLMRuntimeLifecycleTests: XCTestCase {
    private actor LoadCounter {
        private var value = 0

        func increment() {
            value += 1
        }

        func current() -> Int {
            value
        }
    }

    private struct RespondingSession: LocalLLMGeneratingSession {
        let response: String

        func respond(to prompt: String) async throws -> String {
            response
        }
    }

    private struct ThrowingSession: LocalLLMGeneratingSession {
        struct TestError: LocalizedError {
            var errorDescription: String? { "forced failure" }
        }

        func respond(to prompt: String) async throws -> String {
            throw TestError()
        }
    }

    private func request(
        deterministic: String = "hello world",
        requiresCodeSyntaxPostEdit: Bool = false
    ) -> LocalLLMRequest {
        LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: deterministic,
            deterministicTranscript: deterministic,
            vocabulary: .init(),
            formattingContext: TranscriptFormattingContext(
                domain: requiresCodeSyntaxPostEdit ? .code : .general,
                requiresCodeSyntaxPostEdit: requiresCodeSyntaxPostEdit
            )
        )
    }

    func testRuntime_reusesSingleSessionAcrossPrepareAndProcess() async {
        let counter = LoadCounter()
        let coordinator = LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                await counter.increment()
                return RespondingSession(response: #"{"final_text":"hello world","edits":[]}"#)
            }
        )

        await coordinator.prepareIfPossible()
        _ = await coordinator.process(request())

        let loadCount = await counter.current()
        XCTAssertEqual(loadCount, 1)
    }

    func testRuntime_reloadsAfterCriticalMemoryPressureRelease() async {
        let counter = LoadCounter()
        let coordinator = LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                await counter.increment()
                return RespondingSession(response: #"{"final_text":"hello world","edits":[]}"#)
            }
        )

        _ = await coordinator.process(request())
        await coordinator.handleMemoryPressure(level: .critical)
        _ = await coordinator.process(request())

        let loadCount = await counter.current()
        XCTAssertEqual(loadCount, 2)
    }

    func testRuntime_failurePathDoesNotLoadExtraSession() async {
        let counter = LoadCounter()
        let coordinator = LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                await counter.increment()
                return ThrowingSession()
            }
        )

        let first = await coordinator.process(request())
        let second = await coordinator.process(request())

        XCTAssertEqual(first.outcome, .failed)
        XCTAssertEqual(second.outcome, .failed)
        let loadCount = await counter.current()
        XCTAssertEqual(loadCount, 1)
    }

    func testRuntime_rejectsInvalidOutputContractWithoutLeakingProposalTemplate() async {
        let deterministic = "All right, let's test a simple prompt."
        let coordinator = LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                RespondingSession(response: "All right, let's test a simple prompt. The formatted text here.")
            }
        )

        let result = await coordinator.process(request(deterministic: deterministic))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.failureReason, .invalidOutput)
        XCTAssertEqual(result.transcript, deterministic)
        XCTAssertEqual(result.proposedTranscript, deterministic)
    }

    func testRuntime_rejectsInvalidOutputContractWithoutLeakingDuplicatedProposal() async {
        let deterministic = "Another one"
        let coordinator = LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                RespondingSession(response: "Another one Another one")
            }
        )

        let result = await coordinator.process(request(deterministic: deterministic))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.failureReason, .invalidOutput)
        XCTAssertEqual(result.transcript, deterministic)
        XCTAssertEqual(result.proposedTranscript, deterministic)
    }

    func testRuntime_treatsInstructionEchoAsInvalidOutputWithoutLeakingProposal() async {
        let deterministic = "please explain how to rotate API keys in the dashboard"
        let coordinator = LocalLLMCoordinator(
            preferenceLoader: { true },
            sessionLoader: {
                RespondingSession(
                    response: #"{"final_text":"You may rephrase when needed to fix likely ASR wording errors and improve clarity while preserving intent."}"#
                )
            }
        )

        let result = await coordinator.process(request(deterministic: deterministic))

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.failureReason, .invalidOutput)
        XCTAssertEqual(result.transcript, deterministic)
        XCTAssertEqual(result.proposedTranscript, deterministic)
    }
}

final class StructuredResponseValidatorTests: XCTestCase {
    private let validator = StructuredResponseValidator()

    // MARK: - Helpers

    private func validateStructured(
        finalText: String,
        from original: String,
        edits: [TranscriptEdit] = [],
        requiresCodeSyntaxPostEdit: Bool = false,
        vocabulary: CustomVocabularySnapshot = .init(),
        protectedSpans: [ProtectedSpan] = []
    ) -> LocalLLMValidationDecision {
        validator.validate(
            response: StructuredFormattingResponse(finalText: finalText, edits: edits),
            original: original,
            vocabulary: vocabulary,
            requiresCodeSyntaxPostEdit: requiresCodeSyntaxPostEdit,
            protectedSpans: protectedSpans
        )
    }

    private func assertAccepted(
        _ decision: LocalLLMValidationDecision,
        equals expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .accepted(let acceptedText) = decision else {
            return XCTFail("Expected accepted text but received \(decision)", file: file, line: line)
        }

        XCTAssertEqual(acceptedText, expectedText, file: file, line: line)
    }

    private func assertRejected(
        _ decision: LocalLLMValidationDecision,
        as reason: LocalLLMValidationFailureReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejectedReason) = decision else {
            return XCTFail("Expected rejected but received \(decision)", file: file, line: line)
        }

        XCTAssertEqual(rejectedReason, reason, file: file, line: line)
    }

    // MARK: - Non-code final-pass behavior

    func testStructuredValidation_acceptsFinalTextWhenNoEditsProvidedAndOnlyPunctuationChanged() {
        let original = "hello,world! We met yesterday"
        let finalText = "hello, world. We met yesterday."
        let result = validateStructured(finalText: finalText, from: original, edits: [])

        assertAccepted(result, equals: finalText)
    }

    func testStructuredValidation_acceptsHighOverlapNoOpEditListWithoutRejection() {
        let original = "i need to fix the meeting notes before we send the update to the team today"
        let finalText = "i need to fix the meeting notes before we send update to the team today"
        let result = validateStructured(finalText: finalText, from: original, edits: [])

        assertAccepted(result, equals: finalText)
    }

    func testStructuredValidation_rejectsWideContentRemovalWithoutTooMuchOverlap() {
        let original = "the quarterly review should cover metrics product quality and deployment status"
        let finalText = "zz qk rt mn"
        let result = validateStructured(finalText: finalText, from: original, edits: [])

        assertRejected(result, as: .droppedContent)
    }

    func testStructuredValidation_acceptsExplicitPunctuationEditsWithKnownReasons() {
        let original = "Please send this before monday and include the agenda."
        let edits = [
            TranscriptEdit(from: ",", to: ",", reason: .punctuation),
            TranscriptEdit(from: " monday", to: " Monday", reason: .capitalization),
            TranscriptEdit(from: " agenda.", to: " agenda", reason: .spacing)
        ]
        let finalText = "Please send this before Monday and include the agenda"
        let result = validateStructured(finalText: finalText, from: original, edits: edits)

        assertAccepted(result, equals: finalText)
    }

    // MARK: - Code-mode syntax behavior

    func testStructuredValidation_acceptsCodeSyntaxFixesWithoutMarkingAsWordingChanged() {
        let original = "if x plus one equals y then return x"
        let edits = [
            TranscriptEdit(
                from: "x plus one equals y",
                to: "x + 1 == y",
                reason: .obviousAsrFix
            )
        ]
        let finalText = "if x + 1 == y then return x"
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: edits,
            requiresCodeSyntaxPostEdit: true
        )

        assertAccepted(result, equals: finalText)
    }

    func testStructuredValidation_acceptsCodeSyntaxFixWithoutEditMetadataWhenSemanticallyClose() {
        let original = "x plus y equals z"
        let finalText = "x + y == z"
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [],
            requiresCodeSyntaxPostEdit: true
        )

        assertAccepted(result, equals: finalText)
    }

    func testStructuredValidation_rejectsCodeModeThatDropsProtectedSpans() {
        let original = "Please review https://example.com for deployment instructions."
        let protectedSpans = ProtectedSpanDetector().detectProtectedSpans(in: original)
        let finalText = "Please review deployment instructions."
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [
                TranscriptEdit(
                    from: "https://example.com",
                    to: "",
                    reason: .obviousAsrFix
                )
            ],
            requiresCodeSyntaxPostEdit: true,
            protectedSpans: protectedSpans
        )

        assertRejected(result, as: .protectedTermsChanged)
    }

    func testStructuredValidation_rejectsCodeModeVocabularyMismatchForPreferredGlossaryTerm() {
        let original = "I use voice clutch for local edits."
        let finalText = "I use voiceclutch for local edits."
        let vocabulary = CustomVocabularySnapshot(
            manualEntries: [
                ManualVocabularyEntry(canonical: "voice clutch", aliases: ["vc", "voiceclutch"])
            ]
        )

        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [
                TranscriptEdit(from: "voice clutch", to: "voiceclutch", reason: .obviousAsrFix)
            ],
            requiresCodeSyntaxPostEdit: true,
            vocabulary: vocabulary
        )

        assertRejected(result, as: .wordingChanged)
    }

    func testStructuredValidation_rejectsUnsafeCodeModeInsertionsWithLowSemanticSafety() {
        let original = "let x = 1"
        let finalText = "let x = 1 ; import Foundation print(\"danger\")"
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [
                TranscriptEdit(
                    from: "let x = 1",
                    to: "let x = 1 ; import Foundation print(\"danger\")",
                    reason: .obviousAsrFix
                )
            ],
            requiresCodeSyntaxPostEdit: true
        )

        assertRejected(result, as: .wordingChanged)
    }

    func testStructuredValidation_cleansCodeModePunctuationLeakArtifacts() {
        let original = "For I to n minus 1 open brace x, close brace, print open paren x, close paren, if x plus 1 equals y"
        let finalText = "For I to n - 1 { x, } , print ( x, ) , if x + 1 = y"
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [
                TranscriptEdit(from: "minus", to: "-", reason: .obviousAsrFix),
                TranscriptEdit(from: "open brace", to: "{", reason: .punctuation),
                TranscriptEdit(from: "close brace", to: "}", reason: .punctuation),
                TranscriptEdit(from: "plus", to: "+", reason: .obviousAsrFix)
            ],
            requiresCodeSyntaxPostEdit: true
        )

        assertAccepted(result, equals: "For I to n - 1 {x} print (x) if x + 1 = y")
    }

    func testStructuredValidation_preservesIntentionalCommaInsideCodeArguments() {
        let original = "foo(x, y)"
        let finalText = "foo(x, y)"
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [],
            requiresCodeSyntaxPostEdit: true
        )

        assertAccepted(result, equals: "foo(x, y)")
    }

    func testStructuredValidation_preservesExplicitSpokenCommaCommandInCodeMode() {
        let original = "print open paren x comma y close paren"
        let finalText = "print open paren x comma y close paren"
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [],
            requiresCodeSyntaxPostEdit: true
        )

        assertAccepted(result, equals: "print (x, y)")
    }

    func testStructuredValidation_doesNotApplyCodePunctuationScrubInNonCodeMode() {
        let original = "For I to n - 1 { x, } , print ( x, ) , if x + 1 = y"
        let finalText = original
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [],
            requiresCodeSyntaxPostEdit: false
        )

        assertAccepted(result, equals: finalText)
    }

    func testStructuredValidation_rejectsInvalidParserPayloadWithNoOverlapAndNoCommonTokens() {
        let original = "schedule office hours after lunch"
        let finalText = "banana galaxy"
        let result = validateStructured(
            finalText: finalText,
            from: original,
            edits: [
                TranscriptEdit(from: "schedule office hours after lunch", to: "banana galaxy", reason: .obviousAsrFix)
            ]
        )

        assertRejected(result, as: .droppedContent)
    }

    // MARK: - Regression-style wordingChanged fallback cases

    func testStructuredValidation_acceptsMinorWordingChangeWhenOverlapIsStrong() {
        let original = "The patch should preserve all punctuation except where required."
        let finalText = "The patch should preserve all punctuation except where required"
        let result = validateStructured(finalText: finalText, from: original, edits: [])

        assertAccepted(result, equals: finalText)
    }

    func testStructuredValidation_acceptsCollapsedTokenMatchForEquivalentWording() {
        let original = "User typed VoiceClutch and expects auto-correction"
        let finalText = "User typed VoiceClutch and expects auto correction"
        let result = validateStructured(finalText: finalText, from: original)

        assertAccepted(result, equals: finalText)
    }
}

final class LocalLLMOutputValidatorTests: XCTestCase {
    private let validator = LocalLLMOutputValidator()

    // MARK: - Helpers

    private func request(
        deterministic: String,
        original: String? = nil,
        requiresCodeSyntaxPostEdit: Bool = false,
        domain: TranscriptFormattingDomain = .general,
        vocabulary: CustomVocabularySnapshot = .init()
    ) -> LocalLLMRequest {
        LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: original ?? deterministic,
            deterministicTranscript: deterministic,
            vocabulary: vocabulary,
            formattingContext: TranscriptFormattingContext(
                domain: domain,
                requiresCodeSyntaxPostEdit: requiresCodeSyntaxPostEdit
            )
        )
    }

    private func validate(
        candidate: String,
        against original: String,
        requiresCodeSyntaxPostEdit: Bool = false,
        domain: TranscriptFormattingDomain = .general,
        vocabulary: CustomVocabularySnapshot = .init()
    ) -> LocalLLMValidationDecision {
        let request = request(
            deterministic: original,
            original: original,
            requiresCodeSyntaxPostEdit: requiresCodeSyntaxPostEdit,
            domain: domain,
            vocabulary: vocabulary
        )

        return validator.validate(candidate: candidate, for: request)
    }

    private func assertAccepted(
        _ decision: LocalLLMValidationDecision,
        equals expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .accepted(let acceptedText) = decision else {
            return XCTFail("Expected accepted text but received \(decision)", file: file, line: line)
        }

        XCTAssertEqual(acceptedText, expectedText, file: file, line: line)
    }

    private func assertRejected(
        _ decision: LocalLLMValidationDecision,
        as reason: LocalLLMValidationFailureReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejectedReason) = decision else {
            return XCTFail("Expected rejected but received \(decision)", file: file, line: line)
        }

        XCTAssertEqual(rejectedReason, reason, file: file, line: line)
    }

    // MARK: - Non-code fallback behavior

    func testPlainValidation_acceptsEquivalentTokensWithPunctuationAndCapitalizationChanges() {
        let original = "hello world"
        let result = validate(
            candidate: "Hello, world!",
            against: original
        )

        assertAccepted(result, equals: "Hello, world!")
    }

    func testPlainValidation_acceptsNonFormattingWordingChangeWhenSimilarityFallbackApplies() {
        let original = "we should review this section before sending the final draft tomorrow morning with notes from the previous review meeting"
        let result = validate(
            candidate: "we should review this section before sending the final draft tomorrow night with notes from the previous review meeting",
            against: original
        )

        assertAccepted(result, equals: "we should review this section before sending the final draft tomorrow night with notes from the previous review meeting")
    }

    func testPlainValidation_acceptsPlainTextSyntaxAdjustmentsWithoutRejecting() {
        let original = "the app should handle edge cases in deterministic mode."
        let result = validate(
            candidate: "the app should handle edge cases in deterministic mode",
            against: original
        )

        assertAccepted(result, equals: "the app should handle edge cases in deterministic mode")
    }

    func testPlainValidation_rejectsEmptyOutput() {
        let result = validate(candidate: "   ", against: "original transcript")

        assertRejected(result, as: .emptyOutput)
    }

    func testPlainValidation_rejectsLowOverlapRewriteAsExcessive() {
        let original = "build the release branch and run tests before deployment"
        let result = validate(candidate: "asdf qwer zxcv uiop", against: original)

        XCTAssertNotEqual(result, .accepted("asdf qwer zxcv uiop"), "Expected rejection")
    }

    func testPlainValidation_acceptsCandidatesWithStrongTokenOverlapThreshold() {
        let original = "send the status update, confirm attendance, then close the call"
        let result = validate(candidate: "send the status update confirm attendance and then close the call", against: original)

        assertAccepted(result, equals: "send the status update confirm attendance and then close the call")
    }

    func testPlainValidation_acceptsLargeNonCodeRewordingWhenMeaningLikelyPreserved() {
        let original = "sing as mouse you're just completely reliant on your arrow"
        let result = validate(
            candidate: "Using a mouse, you're almost entirely reliant on the arrow pointer.",
            against: original
        )

        assertAccepted(
            result,
            equals: "Using a mouse, you're almost entirely reliant on the arrow pointer."
        )
    }

    func testPlainValidation_rejectsPromptBoundaryMarkerLeakage() {
        let original = "Something that you've typed messages to, he really wanted to"
        let result = validate(
            candidate: "Something that you've typed messages to, he really wanted to END_INPUT",
            against: original
        )

        assertRejected(result, as: .wordingChanged)
    }

    func testPlainValidation_acceptsPromptBoundaryMarkerWhenPresentInOriginal() {
        let original = "the constant name is END_INPUT in this snippet"
        let result = validate(
            candidate: "the constant name is END_INPUT in this snippet",
            against: original
        )

        assertAccepted(result, equals: original)
    }

    // MARK: - Vocabulary / protected change detection

    func testPlainValidation_rejectsChangedManualVocabularyTermInGeneralContext() {
        let original = "for this sprint cycle we reviewed the notes from the quality assurance review and confirmed the expected behavior during the latest deployment for voice clutch"
        let modified = "for this sprint cycle we reviewed the notes from the quality assurance review and confirmed the expected behavior during the latest deployment for vc"
        let vocabulary = CustomVocabularySnapshot(
            manualEntries: [
                ManualVocabularyEntry(canonical: "voice clutch", aliases: ["vc"])
            ]
        )

        let result = validate(candidate: modified, against: original, vocabulary: vocabulary)

        assertRejected(result, as: .protectedTermsChanged)
    }

    // MARK: - Code-mode fallback checks

    func testPlainValidation_acceptsLikelySafeCodeSyntaxCorrection() {
        let original = "if x equals y"
        let result = validate(
            candidate: "if x == y",
            against: original,
            requiresCodeSyntaxPostEdit: true,
            domain: .code
        )

        assertAccepted(result, equals: "if x == y")
    }

    func testPlainValidation_rejectsUnsafeCodeModeChangeWithTooManyInsertions() {
        let original = "if x equals y"
        let result = validate(
            candidate: "if x > y ; import Foundation ; while true { doDangerousThing() }",
            against: original,
            requiresCodeSyntaxPostEdit: true,
            domain: .code
        )

        if case .rejected = result {} else {
            return XCTFail("Expected rejection, received acceptance")
        }
    }

    func testPlainValidation_rejectsTooMuchContentDroppedInCodeMode() {
        let original = "function takes user input and returns a validated payload"
        let result = validate(
            candidate: "function takes input",
            against: original,
            requiresCodeSyntaxPostEdit: true,
            domain: .code
        )

        assertRejected(result, as: .droppedContent)
    }

    func testPlainValidation_acceptsSmallWordingShiftWithHighTokenOverlap() {
        let original = "please send the status update and share the follow-up notes from the standup"
        let result = validate(
            candidate: "please send final status update and share the follow up notes from the standup",
            against: original
        )

        assertAccepted(
            result,
            equals: "please send final status update and share the follow up notes from the standup"
        )
    }

    func testPlainValidation_rejectsLowOverlapButLengthyRewriteBeforeDropGuard() {
        let original = "we deployed the package and confirmed all smoke tests before shipping"
        let result = validate(candidate: "random words that do not relate to the original request", against: original)

        assertRejected(result, as: .droppedContent)
    }

    func testPlainValidation_acceptsQuestionWordingWithMinorASRNoiseInNonCodeMode() {
        let original = "can you review the draft before we publish it"
        let result = validate(candidate: "can you please review the draft before we publish it", against: original)

        assertAccepted(result, equals: "can you please review the draft before we publish it")
    }

    func testPlainValidation_acceptsCodeSyntaxParenthesisAndOperatorFixes() {
        let original = "if x plus one equals y"
        let result = validate(
            candidate: "if x + 1 = y",
            against: original,
            requiresCodeSyntaxPostEdit: true,
            domain: .code
        )

        assertAccepted(result, equals: "if x + 1 = y")
    }

    func testPlainValidation_rejectsCodeModeWithSemanticDriftDespiteOperatorSimilarity() {
        let original = "if x equals y"
        let result = validate(
            candidate: "if x writes to file",
            against: original,
            requiresCodeSyntaxPostEdit: true,
            domain: .code
        )

        assertRejected(result, as: .wordingChanged)
    }

    func testPlainValidation_cleansCodeModePunctuationLeakArtifacts() {
        let original = "For I to n minus 1 open brace x, close brace, print open paren x, close paren, if x plus 1 equals y"
        let result = validate(
            candidate: "For I to n - 1 { x, } , print ( x, ) , if x + 1 = y",
            against: original,
            requiresCodeSyntaxPostEdit: true,
            domain: .code
        )

        assertAccepted(result, equals: "For I to n - 1 {x} print (x) if x + 1 = y")
    }

    func testPlainValidation_stripsTrailingStopInCodeMode() {
        let original = "if x plus 1 equals y"
        let result = validate(
            candidate: "if x + 1 = y.",
            against: original,
            requiresCodeSyntaxPostEdit: true,
            domain: .code
        )

        assertAccepted(result, equals: "if x + 1 = y")
    }

    func testPlainValidation_doesNotApplyCodePunctuationScrubInNonCodeMode() {
        let original = "For I to n - 1 { x, } , print ( x, ) , if x + 1 = y"
        let candidate = original
        let result = validate(
            candidate: candidate,
            against: original,
            requiresCodeSyntaxPostEdit: false,
            domain: .general
        )

        assertAccepted(result, equals: candidate)
    }
}

final class StructuredResponseParserTests: XCTestCase {
    private let parser = StructuredResponseParser()

    func testParser_parsesStrictJSONResponse() {
        let raw = #"""
        {
          "final_text": "Hello, world!",
          "edits": [
            { "from": "Hello", "to": "Hello,", "reason": "punctuation" },
            { "from": " world", "to": " world!", "reason": "punctuation" }
          ]
        }
        """#

        let response = parser.parse(raw)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.finalText, "Hello, world!")
        XCTAssertEqual(response?.edits.count, 2)
    }

    func testParser_defaultsMissingEditReasonToUnknown() {
        let raw = #"""
        {
          "final_text": "I like this",
          "edits": [
            { "from": "I like this", "to": "I like this" }
          ]
        }
        """#

        let response = parser.parse(raw)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.finalText, "I like this")
        XCTAssertEqual(response?.edits.count, 1)
        XCTAssertEqual(response?.edits.first?.reason, .unknown)
    }

    func testParser_parsesMarkdownWrappedResponse() {
        let raw = """
        Some explanatory text
        ```json
        {
          "final_text": "if x > y",
          "edits": []
        }
        ```
        """

        let response = parser.parse(raw)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.finalText, "if x > y")
        XCTAssertTrue(response?.edits.isEmpty == true)
    }

    func testParser_returnsNilOnMalformedResponse() {
        let raw = """
        {
          "text": "Missing expected key"
        """

        XCTAssertNil(parser.parse(raw))
    }

    func testParser_returnsNilOnPlainTextResponse() {
        let raw = "Here is your improved transcript."

        XCTAssertNil(parser.parse(raw))
    }

    func testParser_extractsFinalTextFromMalformedJsonWhenFinalTextFieldExists() {
        let raw = #"""
        {
          "final_text": "I'm not entirely sure what to do. I have a few options. First, draft an email. Second, set up a call. Third, send a Teams message.",
          "edits": [
            { "from": "few", "to": "a few", "reason": "style improvement"
          ]
        """#

        let response = parser.parse(raw)
        XCTAssertNotNil(response)
        XCTAssertEqual(
            response?.finalText,
            "I'm not entirely sure what to do. I have a few options. First, draft an email. Second, set up a call. Third, send a Teams message."
        )
        XCTAssertEqual(response?.edits.count, 0)
    }

    func testParser_extractsFinalTextFromLogStyleMalformedPayload() {
        let raw = #"""
        {
          "final_text": "I'm not entirely sure what to do. I have a few options. First, I need to draft an email. Second, I just can set up a call. And third, just drop by the Teams message.",
          "edits": [
            {"from": "I have few options.", "to": "I have a few options.", "reason": "spelling and flow"},
            {"from": "Second, I just can set up a call.", "to": "Second, I can set up a call.", "reason": "spacing and command consistency"},
            {"from": "And third, just drop by Teams message", "to": "And third, just drop by the Teams message.", "reason": "correct punctuation and closing"]
          ]
        }
        """#

        let response = parser.parse(raw)
        XCTAssertNotNil(response)
        XCTAssertEqual(
            response?.finalText,
            "I'm not entirely sure what to do. I have a few options. First, I need to draft an email. Second, I just can set up a call. And third, just drop by the Teams message."
        )
    }
}

@MainActor
final class TranscriptPostProcessorTests: XCTestCase {
    private struct FixedContextProvider: TranscriptFormattingContextProviding {
        let context: TranscriptFormattingContext

        func currentContext() -> TranscriptFormattingContext {
            context
        }
    }

    private actor RejectingLLMService: LocalLLMServing {
        func prepareIfPossible() async {}

        func process(_ request: LocalLLMRequest) async -> LocalLLMResponse {
            LocalLLMResponse(
                transcript: request.deterministicTranscript,
                proposedTranscript: #"{ "final_text": "I don't understand how this works", "edits": [] }"#,
                outcome: .rejected,
                durationMs: 1,
                skipReason: nil,
                failureReason: nil,
                validationFailure: .wordingChanged,
                wasOutputAccepted: false
            )
        }
    }

    func testProcess_appliesCodeSyntaxNormalizationWhenLLMIsRejected() async {
        let processor = TranscriptPostProcessor(
            llmService: RejectingLLMService(),
            contextProvider: FixedContextProvider(
                context: TranscriptFormattingContext(
                    domain: .code,
                    requiresCodeSyntaxPostEdit: true
                )
            ),
            isSmartFormattingEnabled: { true }
        )

        let result = await processor.process(
            transcript: "For i to n minus 1 open brace x print open paren x close paren if x plus 1 equals y.",
            vocabularySnapshot: .init()
        )

        XCTAssertEqual(result.llmResponse.outcome, .rejected)
        XCTAssertEqual(result.finalTranscript, result.deterministicTranscript)
        XCTAssertTrue(result.finalTranscript.contains("-"))
        XCTAssertTrue(result.finalTranscript.contains("{"))
        XCTAssertTrue(result.finalTranscript.contains("("))
        XCTAssertTrue(result.finalTranscript.contains("+"))
        XCTAssertTrue(result.finalTranscript.contains("="))
        XCTAssertFalse(result.finalTranscript.localizedCaseInsensitiveContains("minus"))
        XCTAssertFalse(result.finalTranscript.localizedCaseInsensitiveContains("open brace"))
        XCTAssertFalse(result.finalTranscript.localizedCaseInsensitiveContains("open paren"))
        XCTAssertFalse(result.finalTranscript.localizedCaseInsensitiveContains("plus"))
        XCTAssertFalse(result.finalTranscript.localizedCaseInsensitiveContains("equals"))
        XCTAssertFalse(result.finalTranscript.hasSuffix("."))
    }

    func testProcess_keepsTrailingStopOutsideCodeMode() async {
        let processor = TranscriptPostProcessor(
            llmService: RejectingLLMService(),
            contextProvider: FixedContextProvider(
                context: TranscriptFormattingContext(
                    domain: .documents,
                    requiresCodeSyntaxPostEdit: false
                )
            ),
            isSmartFormattingEnabled: { true }
        )

        let input = "Please review this section."
        let result = await processor.process(
            transcript: input,
            vocabularySnapshot: .init()
        )

        XCTAssertEqual(result.llmResponse.outcome, .rejected)
        XCTAssertEqual(result.finalTranscript, input)
        XCTAssertTrue(result.finalTranscript.hasSuffix("."))
    }

    func testProcess_formatsEnumeratedOptionsAsNumberedListWhenHintIsDetected() async {
        let processor = TranscriptPostProcessor(
            llmService: RejectingLLMService(),
            contextProvider: FixedContextProvider(
                context: TranscriptFormattingContext(
                    domain: .documents,
                    requiresCodeSyntaxPostEdit: false
                )
            ),
            isSmartFormattingEnabled: { true }
        )

        let input = "I'm not entirely sure what to do. I have a few options. One, draft an email. Second, set up a call. And third, send a Teams message."
        let result = await processor.process(
            transcript: input,
            vocabularySnapshot: .init()
        )

        XCTAssertEqual(result.llmResponse.outcome, .rejected)
        XCTAssertEqual(
            result.finalTranscript,
            "I'm not entirely sure what to do. I have a few options.\n1. draft an email.\n2. set up a call.\n3. send a Teams message."
        )
    }

    func testProcess_formatsLogStyleEnumeratedOptionsIntoNumberedList() async {
        let processor = TranscriptPostProcessor(
            llmService: RejectingLLMService(),
            contextProvider: FixedContextProvider(
                context: TranscriptFormattingContext(
                    domain: .documents,
                    requiresCodeSyntaxPostEdit: false
                )
            ),
            isSmartFormattingEnabled: { true }
        )

        let input = "I'm not entirely sure what to do. I have few options. One, I need to draft an email. Second, I just can set up a call. And third, just drop by Teams message."
        let result = await processor.process(
            transcript: input,
            vocabularySnapshot: .init()
        )

        XCTAssertEqual(result.llmResponse.outcome, .rejected)
        XCTAssertTrue(result.finalTranscript.contains("\n1. I need to draft an email."))
        XCTAssertTrue(result.finalTranscript.contains("\n2. I just can set up a call."))
        XCTAssertTrue(result.finalTranscript.contains("\n3. just drop by Teams message."))
    }

    func testProcess_doesNotApplyListFallbackInCodeContext() async {
        let processor = TranscriptPostProcessor(
            llmService: RejectingLLMService(),
            contextProvider: FixedContextProvider(
                context: TranscriptFormattingContext(
                    domain: .code,
                    requiresCodeSyntaxPostEdit: true
                )
            ),
            isSmartFormattingEnabled: { true }
        )

        let input = "one compile the binary second run tests third deploy"
        let result = await processor.process(
            transcript: input,
            vocabularySnapshot: .init()
        )

        XCTAssertEqual(result.llmResponse.outcome, .rejected)
        XCTAssertFalse(result.finalTranscript.contains("\n1. "))
        XCTAssertFalse(result.finalTranscript.contains("\n- "))
    }

    func testProcess_formatsBulletCueOptionsIntoBulletedList() async {
        let processor = TranscriptPostProcessor(
            llmService: RejectingLLMService(),
            contextProvider: FixedContextProvider(
                context: TranscriptFormattingContext(
                    domain: .documents,
                    requiresCodeSyntaxPostEdit: false
                )
            ),
            isSmartFormattingEnabled: { true }
        )

        let input = "I have bullet points apples, bananas, oranges"
        let result = await processor.process(
            transcript: input,
            vocabularySnapshot: .init()
        )

        XCTAssertEqual(result.llmResponse.outcome, .rejected)
        XCTAssertTrue(result.finalTranscript.contains("\n- apples"))
        XCTAssertTrue(result.finalTranscript.contains("\n- bananas"))
        XCTAssertTrue(result.finalTranscript.contains("\n- oranges"))
    }
}

final class ClipboardContextPromptBuilderTests: XCTestCase {
    private func makeRequest(clipboardPreview: String?) -> LocalLLMRequest {
        LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: "please tidy this up",
            deterministicTranscript: "please tidy this up",
            vocabulary: .init(),
            formattingContext: TranscriptFormattingContext(
                domain: .documents,
                requiresCodeSyntaxPostEdit: false
            ),
            listFormattingHint: .none,
            clipboardContextPreview: clipboardPreview
        )
    }

    private func makeExtendedContext(clipboardPreview: String?) -> ExtendedFormattingContext {
        ExtendedFormattingContext(
            formattingContext: TranscriptFormattingContext(
                appName: "Notes",
                domain: .documents,
                requiresCodeSyntaxPostEdit: false
            ),
            previousSentences: [],
            recentCorrections: [],
            stylePreferences: .default,
            protectedSpans: [],
            clipboardPreview: clipboardPreview
        )
    }

    func testConstrainedPrompt_usesProseContractAndJsonInput() {
        let builder = ConstrainedFormattingPromptBuilder()
        let preview = "TODO from clipboard: include deployment status."
        let request = makeRequest(clipboardPreview: preview)
        let prompt = builder.buildPrompt(
            for: request,
            extendedContext: makeExtendedContext(clipboardPreview: preview)
        )

        XCTAssertTrue(prompt.contains("Improve dictated text for clarity and intended meaning."))
        XCTAssertTrue(prompt.contains("Preserve core intent and factual content."))
        XCTAssertTrue(prompt.contains("You may rephrase when needed to fix likely ASR wording errors and improve clarity while preserving intent."))
        XCTAssertTrue(prompt.contains("Do not copy instruction text into final_text."))
        XCTAssertTrue(prompt.contains("Return one valid JSON object with exactly one key:"))
        XCTAssertTrue(prompt.contains("{\"final_text\":\"...\"}"))
        XCTAssertTrue(prompt.contains("Input JSON:"))
        XCTAssertTrue(prompt.contains("\"transcript\":"))
        XCTAssertTrue(prompt.contains(#""transcript":"please tidy this up""#))
    }

    func testConstrainedPrompt_omitsClipboardContextEvenWhenProvided() {
        let builder = ConstrainedFormattingPromptBuilder()
        let preview = "TODO from clipboard: include deployment status."
        let prompt = builder.buildPrompt(
            for: makeRequest(clipboardPreview: preview),
            extendedContext: makeExtendedContext(clipboardPreview: preview)
        )

        XCTAssertFalse(prompt.contains("Clipboard context from before dictation"))
        XCTAssertFalse(prompt.contains(preview))
    }

    func testConstrainedPrompt_usesCodeContractWhenCodeModeEnabled() {
        let builder = ConstrainedFormattingPromptBuilder()
        let request = LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: "if x plus 1 equals y",
            deterministicTranscript: "if x plus 1 equals y",
            vocabulary: .init(),
            formattingContext: TranscriptFormattingContext(
                domain: .code,
                requiresCodeSyntaxPostEdit: true
            )
        )
        let context = ExtendedFormattingContext(
            formattingContext: request.formattingContext,
            previousSentences: [],
            recentCorrections: [],
            stylePreferences: .default,
            protectedSpans: [],
            clipboardPreview: nil
        )
        let prompt = builder.buildPrompt(for: request, extendedContext: context)

        XCTAssertTrue(prompt.contains("Fix dictated code minimally."))
        XCTAssertTrue(prompt.contains("Return one valid JSON object with exactly one key:"))
        XCTAssertTrue(prompt.contains("Fix only obvious punctuation, spacing, brackets, quotes, operators, and spoken symbols."))
    }

    func testFallbackPrompt_includesClipboardContextWhenProvided() {
        let builder = LocalLLMSmartFormattingPromptBuilder()
        let preview = "Current ticket summary from clipboard."
        let prompt = builder.buildPrompt(for: makeRequest(clipboardPreview: preview))

        XCTAssertTrue(prompt.contains("Clipboard context from before dictation"))
        XCTAssertTrue(prompt.contains(preview))
    }
}

@MainActor
final class DictationControllerClipboardContextTests: XCTestCase {
    func testMakeClipboardContextPreview_returnsNilForEmptyInput() {
        XCTAssertNil(DictationController.makeClipboardContextPreview(from: nil))
        XCTAssertNil(DictationController.makeClipboardContextPreview(from: " \n\t  "))
    }

    func testMakeClipboardContextPreview_collapsesWhitespaceForShortInput() {
        let preview = DictationController.makeClipboardContextPreview(
            from: "  deployment \n   checklist\titem one   "
        )

        XCTAssertEqual(preview, "deployment checklist item one")
    }

    func testMakeClipboardContextPreview_truncatesLongInputWithMarker() {
        let input = String(repeating: "a", count: 400)
        let preview = DictationController.makeClipboardContextPreview(from: input, maxLength: 300)

        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.count, 300)
        XCTAssertTrue(preview?.hasSuffix(" [truncated]") == true)
    }
}

@MainActor
final class TranscriptPostProcessorClipboardContextTests: XCTestCase {
    private struct FixedContextProvider: TranscriptFormattingContextProviding {
        let context: TranscriptFormattingContext

        func currentContext() -> TranscriptFormattingContext {
            context
        }
    }

    private actor CapturingLLMService: LocalLLMServing {
        private var latestRequest: LocalLLMRequest?

        func prepareIfPossible() async {}

        func process(_ request: LocalLLMRequest) async -> LocalLLMResponse {
            latestRequest = request
            return LocalLLMResponse(
                transcript: request.deterministicTranscript,
                proposedTranscript: request.deterministicTranscript,
                outcome: .unchanged,
                durationMs: 1,
                skipReason: nil,
                failureReason: nil,
                validationFailure: nil,
                wasOutputAccepted: true
            )
        }

        func capturedRequest() -> LocalLLMRequest? {
            latestRequest
        }
    }

    func testProcess_passesClipboardPreviewToRequest() async {
        let llmService = CapturingLLMService()
        let processor = TranscriptPostProcessor(
            llmService: llmService,
            contextProvider: FixedContextProvider(
                context: TranscriptFormattingContext(
                    domain: .documents,
                    requiresCodeSyntaxPostEdit: false
                )
            ),
            isSmartFormattingEnabled: { true }
        )

        _ = await processor.process(
            transcript: "Please clean this up",
            vocabularySnapshot: .init(),
            clipboardContextPreview: "Clipboard notes for context"
        )

        let captured = await llmService.capturedRequest()
        XCTAssertEqual(captured?.clipboardContextPreview, "Clipboard notes for context")
    }
}
