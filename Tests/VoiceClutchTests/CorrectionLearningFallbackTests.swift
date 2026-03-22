import Carbon
import CoreGraphics
import XCTest
@testable import VoiceClutch

final class CursorAwareEditTrackerTests: XCTestCase {
    func testTracker_handlesMidStringKeyboardCorrection() {
        var tracker = CursorAwareEditTracker(initialText: "hxllo ")

        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_Home))) { nil }
        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_RightArrow))) { nil }
        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_ForwardDelete))) { nil }
        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_ANSI_E), characters: "e")) { nil }

        XCTAssertEqual(tracker.modeledText, "hello ")
        XCTAssertTrue(tracker.hasMeaningfulEdit)
        XCTAssertTrue(tracker.isDeterministic)
    }

    func testTracker_handlesForwardDeleteAndPasteAtCaret() {
        var tracker = CursorAwareEditTracker(initialText: "foo x ")

        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_Home))) { nil }
        for _ in 0..<4 {
            _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_RightArrow))) { nil }
        }
        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_ForwardDelete))) { nil }
        _ = tracker.applyKeyEvent(
            keyDown(UInt32(kVK_ANSI_V), modifiers: .maskCommand)
        ) {
            "bar"
        }

        XCTAssertEqual(tracker.modeledText, "foo bar ")
        XCTAssertTrue(tracker.hasMeaningfulEdit)
        XCTAssertTrue(tracker.isDeterministic)
    }

    func testMouseInteraction_marksTrackerNonDeterministic() {
        var tracker = CursorAwareEditTracker(initialText: "hello ")

        tracker.noteMouseInteraction()

        XCTAssertFalse(tracker.isDeterministic)
        XCTAssertEqual(tracker.modeledText, "hello ")
    }

    func testMouseInteraction_recoversSelectionReplacementWithoutDowngrade() {
        var tracker = CursorAwareEditTracker(initialText: "foo bax ")

        tracker.noteMouseInteraction(
            recoveredCaretOffsetFromEnd: 1,
            recoveredSelectionLength: 3
        )
        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_ANSI_B), characters: "b")) { nil }
        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_ANSI_A), characters: "a")) { nil }
        _ = tracker.applyKeyEvent(keyDown(UInt32(kVK_ANSI_R), characters: "r")) { nil }

        XCTAssertTrue(tracker.isDeterministic)
        XCTAssertEqual(tracker.modeledText, "foo bar ")
    }

    func testMouseInteraction_invalidRecoveredSelectionDowngradesTracker() {
        var tracker = CursorAwareEditTracker(initialText: "hello ")

        tracker.noteMouseInteraction(
            recoveredCaretOffsetFromEnd: 5,
            recoveredSelectionLength: 2
        )

        XCTAssertFalse(tracker.isDeterministic)
    }

    private func keyDown(
        _ keyCode: UInt32,
        characters: String? = nil,
        modifiers: CGEventFlags = []
    ) -> ObservedKeyEvent {
        ObservedKeyEvent(
            kind: .keyDown,
            keyCode: keyCode,
            modifierFlagsRawValue: modifiers.rawValue,
            characters: characters
        )
    }
}

final class CorrectionLearningStrategyTests: XCTestCase {
    func testStrategyResolver_rejectsNonDeterministicTrackerCandidate() {
        let strategy = CorrectionCaptureStrategyResolver.resolve(
            focusedDiffHasCandidate: false,
            trackerIsDeterministic: false,
            trackerHasCandidate: true
        )

        XCTAssertEqual(strategy, .none)
    }

    func testStrategyResolver_usesDeterministicTrackerCandidate() {
        let strategy = CorrectionCaptureStrategyResolver.resolve(
            focusedDiffHasCandidate: false,
            trackerIsDeterministic: true,
            trackerHasCandidate: true
        )

        XCTAssertEqual(strategy, .editTracker)
    }

    func testCorrectionLearning_ignoresSyntheticEvents() {
        let syntheticEvent = ObservedKeyEvent(
            kind: .keyDown,
            keyCode: UInt32(kVK_ANSI_A),
            modifierFlagsRawValue: CGEventFlags.maskCommand.rawValue,
            characters: "a",
            eventSourceUserData: SyntheticInputEvent.syntheticEventTag
        )
        XCTAssertTrue(CorrectionLearningMonitor.shouldIgnoreEventForTesting(syntheticEvent))

        let userEvent = ObservedKeyEvent(
            kind: .keyDown,
            keyCode: UInt32(kVK_ANSI_A),
            modifierFlagsRawValue: CGEventFlags.maskCommand.rawValue,
            characters: "a",
            eventSourceUserData: 0
        )
        XCTAssertFalse(CorrectionLearningMonitor.shouldIgnoreEventForTesting(userEvent))
    }

    func testDeriveCorrection_acceptsSingleWordReplacementAndRejectsAppendOnlyExpansion() async {
        let replacement = await CorrectionLearningMonitor.deriveCorrectionForTesting(
            from: "manual corections are not detected",
            to: "manual corrections are not detected"
        )
        XCTAssertEqual(replacement?.source, "corections")
        XCTAssertEqual(replacement?.target, "corrections")

        let appendOnly = await CorrectionLearningMonitor.deriveCorrectionForTesting(
            from: "manual corrections",
            to: "manual corrections in vscode"
        )
        XCTAssertNil(appendOnly)
    }
}
