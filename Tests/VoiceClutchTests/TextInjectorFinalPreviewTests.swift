import XCTest
@testable import VoiceClutch

@MainActor
final class TextInjectorFinalPreviewTests: XCTestCase {
    func testProvisionalFinalPreview_addsPeriodWhenMissingTerminalPunctuation() {
        let preview = TextInjector.provisionalFinalPreviewText(
            fromNormalizedTranscript: "send the build report to the team"
        )

        XCTAssertEqual(preview, "send the build report to the team.")
    }

    func testProvisionalFinalPreview_addsQuestionMarkForQuestionUtterance() {
        let preview = TextInjector.provisionalFinalPreviewText(
            fromNormalizedTranscript: "can you send the build report"
        )

        XCTAssertEqual(preview, "can you send the build report?")
    }

    func testProvisionalFinalPreview_preservesExistingTerminalPunctuation() {
        let preview = TextInjector.provisionalFinalPreviewText(
            fromNormalizedTranscript: "looks good!"
        )

        XCTAssertEqual(preview, "looks good!")
    }

    func testProvisionalFinalPreview_returnsEmptyForEmptyNormalizedTranscript() {
        let normalized = TextInjector.normalizedStreamingTranscript("   \n\t")
        let preview = TextInjector.provisionalFinalPreviewText(
            fromNormalizedTranscript: normalized
        )

        XCTAssertEqual(normalized, "")
        XCTAssertEqual(preview, "")
    }

    func testCanApplyLiveRewriteNow_requiresIntervalWithoutBypass() {
        let now = 10.0
        let lastRewriteDisplayTime = 9.90

        let shouldApply = TextInjector.canApplyLiveRewriteNow(
            now: now,
            lastRewriteDisplayTime: lastRewriteDisplayTime,
            bypassRewriteThrottle: false
        )

        XCTAssertFalse(shouldApply)
    }

    func testCanApplyLiveRewriteNow_allowsBypassForProvisionalFinalPath() {
        let now = 10.0
        let lastRewriteDisplayTime = 9.90

        let shouldApply = TextInjector.canApplyLiveRewriteNow(
            now: now,
            lastRewriteDisplayTime: lastRewriteDisplayTime,
            bypassRewriteThrottle: true
        )

        XCTAssertTrue(shouldApply)
    }
}
