import Carbon
import Foundation

enum CorrectionCaptureStrategy: Equatable {
    case focusedTextDiff
    case editTracker
    case none
}

struct CorrectionCaptureStrategyResolver {
    static func resolve(
        focusedDiffHasCandidate: Bool,
        trackerIsDeterministic: Bool,
        trackerHasCandidate: Bool
    ) -> CorrectionCaptureStrategy {
        if focusedDiffHasCandidate {
            return .focusedTextDiff
        }
        if trackerHasCandidate, trackerIsDeterministic {
            return .editTracker
        }
        return .none
    }
}

struct CursorAwareEditTracker {
    private(set) var modeledText: String
    private(set) var caretOffsetFromEnd: Int
    private(set) var selectedRangeLength: Int
    private(set) var isDeterministic: Bool
    private(set) var hasMeaningfulEdit: Bool

    init(initialText: String) {
        self.modeledText = initialText
        self.caretOffsetFromEnd = 0
        self.selectedRangeLength = 0
        self.isDeterministic = true
        self.hasMeaningfulEdit = false
    }

    mutating func resetBaseline(to text: String) {
        modeledText = text
        caretOffsetFromEnd = 0
        selectedRangeLength = 0
        isDeterministic = true
        hasMeaningfulEdit = false
    }

    mutating func noteMouseInteraction() {
        noteMouseInteraction(recoveredCaretOffsetFromEnd: nil, recoveredSelectionLength: 0)
    }

    mutating func noteMouseInteraction(
        recoveredCaretOffsetFromEnd: Int?,
        recoveredSelectionLength: Int = 0
    ) {
        guard let recoveredCaretOffsetFromEnd else {
            isDeterministic = false
            selectedRangeLength = 0
            return
        }
        guard
            recoveredCaretOffsetFromEnd >= 0,
            recoveredSelectionLength >= 0,
            recoveredCaretOffsetFromEnd + recoveredSelectionLength <= modeledText.count
        else {
            isDeterministic = false
            selectedRangeLength = 0
            return
        }

        caretOffsetFromEnd = recoveredCaretOffsetFromEnd
        selectedRangeLength = recoveredSelectionLength
    }

    @discardableResult
    mutating func applyKeyEvent(
        _ event: ObservedKeyEvent,
        pasteTextProvider: () -> String?
    ) -> Bool {
        guard event.kind == .keyDown else {
            return false
        }

        let modifierFlags = CGEventFlags(rawValue: event.modifierFlagsRawValue)

        if modifierFlags.contains(.maskCommand) {
            return handleCommandShortcut(event, pasteTextProvider: pasteTextProvider)
        }

        if modifierFlags.contains(.maskControl) {
            return false
        }

        switch event.keyCode {
        case UInt32(kVK_LeftArrow):
            if selectedRangeLength > 0 {
                caretOffsetFromEnd += selectedRangeLength
                selectedRangeLength = 0
                return false
            }
            moveCaretLeft()
            return false
        case UInt32(kVK_RightArrow):
            if selectedRangeLength > 0 {
                selectedRangeLength = 0
                return false
            }
            moveCaretRight()
            return false
        case UInt32(kVK_Home):
            selectedRangeLength = 0
            moveCaretToStart()
            return false
        case UInt32(kVK_End):
            selectedRangeLength = 0
            moveCaretToEnd()
            return false
        case UInt32(kVK_UpArrow), UInt32(kVK_DownArrow), UInt32(kVK_PageUp), UInt32(kVK_PageDown), UInt32(kVK_Tab):
            isDeterministic = false
            selectedRangeLength = 0
            return false
        case UInt32(kVK_Delete):
            return applyBackspace()
        case UInt32(kVK_ForwardDelete):
            return applyForwardDelete()
        default:
            guard let characters = event.characters, !characters.isEmpty else {
                return false
            }
            guard !characters.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else {
                return false
            }
            insertText(characters)
            return true
        }
    }

    private mutating func handleCommandShortcut(
        _ event: ObservedKeyEvent,
        pasteTextProvider: () -> String?
    ) -> Bool {
        switch event.keyCode {
        case UInt32(kVK_ANSI_C):
            return false
        case UInt32(kVK_ANSI_A):
            isDeterministic = false
            selectedRangeLength = 0
            return false
        case UInt32(kVK_ANSI_X), UInt32(kVK_ANSI_Z):
            isDeterministic = false
            selectedRangeLength = 0
            hasMeaningfulEdit = true
            return true
        case UInt32(kVK_ANSI_V):
            guard let pastedText = pasteTextProvider(), !pastedText.isEmpty else {
                return false
            }
            insertText(pastedText)
            return true
        default:
            return false
        }
    }

    @discardableResult
    private mutating func applyBackspace() -> Bool {
        if deleteSelectionIfNeeded() {
            return true
        }
        guard modeledText.count > caretOffsetFromEnd else {
            return false
        }

        let removeIndex = modeledText.index(modeledText.endIndex, offsetBy: -(caretOffsetFromEnd + 1))
        modeledText.remove(at: removeIndex)
        hasMeaningfulEdit = true
        return true
    }

    @discardableResult
    private mutating func applyForwardDelete() -> Bool {
        if deleteSelectionIfNeeded() {
            return true
        }
        guard caretOffsetFromEnd > 0 else {
            return false
        }

        let removeIndex = modeledText.index(modeledText.endIndex, offsetBy: -caretOffsetFromEnd)
        modeledText.remove(at: removeIndex)
        caretOffsetFromEnd = max(0, caretOffsetFromEnd - 1)
        hasMeaningfulEdit = true
        return true
    }

    private mutating func insertText(_ text: String) {
        _ = deleteSelectionIfNeeded()
        let insertIndex = modeledText.index(modeledText.endIndex, offsetBy: -caretOffsetFromEnd)
        modeledText.insert(contentsOf: text, at: insertIndex)
        hasMeaningfulEdit = true
    }

    @discardableResult
    private mutating func deleteSelectionIfNeeded() -> Bool {
        guard selectedRangeLength > 0 else {
            return false
        }
        guard selectedRangeLength + caretOffsetFromEnd <= modeledText.count else {
            isDeterministic = false
            selectedRangeLength = 0
            return false
        }

        let selectionStart = modeledText.index(
            modeledText.endIndex,
            offsetBy: -(caretOffsetFromEnd + selectedRangeLength)
        )
        let selectionEnd = modeledText.index(selectionStart, offsetBy: selectedRangeLength)
        modeledText.removeSubrange(selectionStart..<selectionEnd)
        selectedRangeLength = 0
        hasMeaningfulEdit = true
        return true
    }

    private mutating func moveCaretLeft() {
        caretOffsetFromEnd = min(modeledText.count, caretOffsetFromEnd + 1)
    }

    private mutating func moveCaretRight() {
        caretOffsetFromEnd = max(0, caretOffsetFromEnd - 1)
    }

    private mutating func moveCaretToStart() {
        caretOffsetFromEnd = modeledText.count
    }

    private mutating func moveCaretToEnd() {
        caretOffsetFromEnd = 0
    }
}
