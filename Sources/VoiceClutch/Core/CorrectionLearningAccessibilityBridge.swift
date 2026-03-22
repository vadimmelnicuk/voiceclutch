import AppKit
import ApplicationServices
import Foundation

struct CorrectionLearningAccessibilityElement: Hashable {
    fileprivate enum Storage: Hashable {
        case live(ObjectIdentifier)
        case test(String)
    }

    fileprivate let storage: Storage
    fileprivate let rawElement: AXUIElement?

    init(_ element: AXUIElement) {
        self.storage = .live(ObjectIdentifier(element as AnyObject))
        self.rawElement = element
    }

    internal init(testID: String) {
        self.storage = .test(testID)
        self.rawElement = nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage == rhs.storage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

struct CorrectionLearningTextMarkerRange: Hashable {
    fileprivate enum Storage: Hashable {
        case live(ObjectIdentifier)
        case test(String)
    }

    fileprivate let storage: Storage
    fileprivate let rawValue: CFTypeRef?

    init?(rawValue: CFTypeRef?) {
        guard let rawValue else { return nil }
        self.storage = .live(ObjectIdentifier(rawValue as AnyObject))
        self.rawValue = rawValue
    }

    internal init(testID: String) {
        self.storage = .test(testID)
        self.rawValue = nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage == rhs.storage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

protocol CorrectionLearningAccessibilityClient {
    func frontmostApplicationPID() -> pid_t?
    func focusedElement() -> CorrectionLearningAccessibilityElement?
    func applicationElement(for pid: pid_t) -> CorrectionLearningAccessibilityElement
    func processIdentifier(of element: CorrectionLearningAccessibilityElement) -> pid_t?
    func parent(of element: CorrectionLearningAccessibilityElement) -> CorrectionLearningAccessibilityElement?
    func childElements(of element: CorrectionLearningAccessibilityElement, attribute: CFString) -> [CorrectionLearningAccessibilityElement]
    func role(of element: CorrectionLearningAccessibilityElement) -> String?
    func stringValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> String?
    func attributedStringValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> String?
    func rangeValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> CFRange?
    func integerValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> Int64?
    func boolValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> Bool?
    @discardableResult
    func setBoolValue(_ value: Bool, on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> AXError
    func textMarkerRangeValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> CorrectionLearningTextMarkerRange?
    func parameterizedTextMarkerRangeValue(
        on element: CorrectionLearningAccessibilityElement,
        attribute: CFString,
        parameterElement: CorrectionLearningAccessibilityElement
    ) -> CorrectionLearningTextMarkerRange?
    func stringValue(
        on element: CorrectionLearningAccessibilityElement,
        textMarkerRange: CorrectionLearningTextMarkerRange,
        attribute: CFString
    ) -> String?
}

final class LiveCorrectionLearningAccessibilityClient: CorrectionLearningAccessibilityClient {
    private let systemWideElement = AXUIElementCreateSystemWide()

    func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func focusedElement() -> CorrectionLearningAccessibilityElement? {
        uiElementAttributeValue(on: systemWideElement, attribute: kAXFocusedUIElementAttribute as CFString)
            .map(CorrectionLearningAccessibilityElement.init)
    }

    func applicationElement(for pid: pid_t) -> CorrectionLearningAccessibilityElement {
        CorrectionLearningAccessibilityElement(AXUIElementCreateApplication(pid))
    }

    func processIdentifier(of element: CorrectionLearningAccessibilityElement) -> pid_t? {
        guard let rawElement = element.rawElement else { return nil }

        var pid: pid_t = 0
        let status = AXUIElementGetPid(rawElement, &pid)
        guard status == .success, pid > 0 else {
            return nil
        }
        return pid
    }

    func parent(of element: CorrectionLearningAccessibilityElement) -> CorrectionLearningAccessibilityElement? {
        uiElementAttributeValue(on: element, attribute: kAXParentAttribute as CFString)
            .map(CorrectionLearningAccessibilityElement.init)
    }

    func childElements(of element: CorrectionLearningAccessibilityElement, attribute: CFString) -> [CorrectionLearningAccessibilityElement] {
        guard let rawElement = element.rawElement else { return [] }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(rawElement, attribute, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? [Any] else {
            return []
        }

        return array.compactMap { item in
            guard CFGetTypeID(item as CFTypeRef) == AXUIElementGetTypeID() else {
                return nil
            }
            let uiElement = item as! AXUIElement
            return CorrectionLearningAccessibilityElement(uiElement)
        }
    }

    func role(of element: CorrectionLearningAccessibilityElement) -> String? {
        stringValue(on: element, attribute: kAXRoleAttribute as CFString)
    }

    func stringValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> String? {
        guard let rawElement = element.rawElement else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(rawElement, attribute, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    func attributedStringValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> String? {
        guard let rawElement = element.rawElement else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(rawElement, attribute, &value)
        guard status == .success, let value else {
            return nil
        }

        if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
            return (value as? NSAttributedString)?.string
        }
        return nil
    }

    func rangeValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> CFRange? {
        guard let rawElement = element.rawElement else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(rawElement, attribute, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    func integerValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> Int64? {
        guard let rawElement = element.rawElement else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(rawElement, attribute, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }

        var result: Int64 = 0
        let number = value as! CFNumber
        guard CFNumberGetValue(number, .sInt64Type, &result) else {
            return nil
        }
        return result
    }

    func boolValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> Bool? {
        guard let rawElement = element.rawElement else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(rawElement, attribute, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    @discardableResult
    func setBoolValue(_ value: Bool, on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> AXError {
        guard let rawElement = element.rawElement else { return .illegalArgument }
        return AXUIElementSetAttributeValue(rawElement, attribute, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func textMarkerRangeValue(on element: CorrectionLearningAccessibilityElement, attribute: CFString) -> CorrectionLearningTextMarkerRange? {
        guard let rawElement = element.rawElement else { return nil }

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(rawElement, attribute, &value)
        guard status == .success else {
            return nil
        }
        return CorrectionLearningTextMarkerRange(rawValue: value)
    }

    func parameterizedTextMarkerRangeValue(
        on element: CorrectionLearningAccessibilityElement,
        attribute: CFString,
        parameterElement: CorrectionLearningAccessibilityElement
    ) -> CorrectionLearningTextMarkerRange? {
        guard let rawElement = element.rawElement,
              let parameterRawElement = parameterElement.rawElement else {
            return nil
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            rawElement,
            attribute,
            parameterRawElement,
            &value
        )
        guard status == .success else {
            return nil
        }
        return CorrectionLearningTextMarkerRange(rawValue: value)
    }

    func stringValue(
        on element: CorrectionLearningAccessibilityElement,
        textMarkerRange: CorrectionLearningTextMarkerRange,
        attribute: CFString
    ) -> String? {
        guard let rawElement = element.rawElement,
              let rawTextMarkerRange = textMarkerRange.rawValue else {
            return nil
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            rawElement,
            attribute,
            rawTextMarkerRange,
            &value
        )
        guard status == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private func uiElementAttributeValue(on element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard status == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let uiElement: AXUIElement = value as! AXUIElement
        return uiElement
    }

    private func uiElementAttributeValue(
        on element: CorrectionLearningAccessibilityElement,
        attribute: CFString
    ) -> AXUIElement? {
        guard let rawElement = element.rawElement else { return nil }
        return uiElementAttributeValue(on: rawElement, attribute: attribute)
    }
}

final class CorrectionLearningAccessibilityBridge {
    struct ManualAccessibilityEntry {
        let appElement: CorrectionLearningAccessibilityElement
        let processIdentifier: pid_t
        let previousValue: Bool?
        let shouldRestore: Bool
    }

    struct ManualAccessibilitySession {
        let entries: [ManualAccessibilityEntry]
    }

    struct RecoveredSelectionState: Equatable {
        let caretOffsetFromEnd: Int
        let selectedRangeLength: Int
        let source: String
    }

    private enum SnapshotSource: String {
        case value = "value"
        case attributedValue = "attributed_value"
        case selectedText = "selected_text"
        case visibleRange = "visible_range"
        case fullRange = "full_range"
        case selectedTextMarkerRange = "selected_text_marker_range"
        case fullTextMarkerRange = "full_text_marker_range"
    }

    private struct SnapshotResult {
        let text: String
        let source: SnapshotSource
        let role: String?
        let element: CorrectionLearningAccessibilityElement
    }

    private let client: CorrectionLearningAccessibilityClient
    private let manualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
    private let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange" as CFString
    private let textMarkerRangeForUIElementAttribute = "AXTextMarkerRangeForUIElement" as CFString
    private let webAreaRole = "AXWebArea"
    private let candidateAttributes: [CFString] = [
        kAXContentsAttribute as CFString,
        kAXSelectedChildrenAttribute as CFString,
        kAXVisibleChildrenAttribute as CFString,
        kAXChildrenAttribute as CFString,
        "AXLinkedUIElements" as CFString,
        "AXOwns" as CFString,
    ]
    private let maxAncestorDepth = 8
    private let maxDescendantDepth = 6
    private let maxDescendantNodes = 96
    private let maxSnapshotLength: Int64 = 50_000

    init(
        client: CorrectionLearningAccessibilityClient = LiveCorrectionLearningAccessibilityClient()
    ) {
        self.client = client
    }

    func focusedElement() -> CorrectionLearningAccessibilityElement? {
        client.focusedElement()
    }

    func prepareFocusedApplicationAccessibility() -> ManualAccessibilitySession? {
        var candidatePIDs: [pid_t] = []
        if let frontmostPID = client.frontmostApplicationPID() {
            candidatePIDs.append(frontmostPID)
        }
        if let focusedElement = client.focusedElement(),
           let focusedPID = client.processIdentifier(of: focusedElement),
           !candidatePIDs.contains(focusedPID) {
            candidatePIDs.append(focusedPID)
        }
        guard !candidatePIDs.isEmpty else { return nil }

        let entries = candidatePIDs.compactMap(enableManualAccessibility(for:))
        guard !entries.isEmpty else { return nil }
        return ManualAccessibilitySession(entries: entries)
    }

    func restoreManualAccessibilityIfNeeded(_ session: ManualAccessibilitySession?) {
        guard let session else { return }
        for entry in session.entries where entry.shouldRestore {
            _ = client.setBoolValue(false, on: entry.appElement, attribute: manualAccessibilityAttribute)
        }
    }

    private func enableManualAccessibility(for processIdentifier: pid_t) -> ManualAccessibilityEntry? {
        let appElement = client.applicationElement(for: processIdentifier)
        let previousValue = client.boolValue(on: appElement, attribute: manualAccessibilityAttribute)
        let status = client.setBoolValue(true, on: appElement, attribute: manualAccessibilityAttribute)
        switch status {
        case .success:
            return ManualAccessibilityEntry(
                appElement: appElement,
                processIdentifier: processIdentifier,
                previousValue: previousValue,
                shouldRestore: previousValue == false
            )
        case .attributeUnsupported, .noValue:
            return nil
        default:
            return nil
        }
    }

    func focusedTextSelection(
        preferredElement: CorrectionLearningAccessibilityElement? = nil,
        anchorText: String? = nil,
        reusePreferredElementSnapshot: Bool = false
    ) -> (text: String, element: CorrectionLearningAccessibilityElement)? {
        if reusePreferredElementSnapshot,
           let preferredElement,
           let snapshot = snapshotResult(from: preferredElement) {
            return (snapshot.text, snapshot.element)
        }

        if let preferredElement,
           let snapshot = firstFocusedSnapshot(startingAt: preferredElement, anchorText: anchorText) {
            return (snapshot.text, snapshot.element)
        }

        guard let focusedElement = client.focusedElement(),
              let snapshot = firstFocusedSnapshot(startingAt: focusedElement, anchorText: anchorText) else {
            return nil
        }
        return (snapshot.text, snapshot.element)
    }

    func focusedTextSnapshot(
        preferredElement: CorrectionLearningAccessibilityElement? = nil,
        reusePreferredElementSnapshot: Bool = false
    ) -> String? {
        focusedTextSelection(
            preferredElement: preferredElement,
            reusePreferredElementSnapshot: reusePreferredElementSnapshot
        )?.text
    }

    func inferredInsertionStartInFocusedField(
        insertedText: String,
        focusedTextAtStart: String?,
        preferredElement: CorrectionLearningAccessibilityElement?
    ) -> Int? {
        if let focusedTextAtStart,
           let matchedRange = uniqueRange(of: insertedText, in: focusedTextAtStart) {
            return focusedTextAtStart.distance(from: focusedTextAtStart.startIndex, to: matchedRange.lowerBound)
        }

        guard insertedText.count > 0,
              let selectedRange = selectedTextRangeSnapshot(preferredElement: preferredElement),
              selectedRange.length == 0,
              selectedRange.location >= insertedText.count else {
            return nil
        }

        return selectedRange.location - insertedText.count
    }

    func selectedTextRangeSnapshot(preferredElement: CorrectionLearningAccessibilityElement?) -> CFRange? {
        for element in elementsToInspect(preferredElement: preferredElement) {
            guard let selectedRange = client.rangeValue(on: element, attribute: kAXSelectedTextRangeAttribute as CFString),
                  selectedRange.location >= 0,
                  selectedRange.length >= 0 else {
                continue
            }
            return selectedRange
        }
        return nil
    }

    func recoverSelectionState(
        modeledText: String,
        insertionStartInField: Int?,
        preferredElement: CorrectionLearningAccessibilityElement?
    ) -> RecoveredSelectionState? {
        guard !modeledText.isEmpty else { return nil }

        let startElement = preferredElement ?? client.focusedElement()
        guard let startElement else { return nil }

        for element in candidateElements(startingAt: startElement) {
            if let recoveredState = recoverSelectionStateFromSelectedText(
                modeledText: modeledText,
                element: element
            ) {
                return recoveredState
            }

            guard let selectedRange = client.rangeValue(
                on: element,
                attribute: kAXSelectedTextRangeAttribute as CFString
            ) else {
                continue
            }
            guard selectedRange.location >= 0, selectedRange.length >= 0 else {
                continue
            }

            if let insertionStartInField {
                let insertionEndInField = insertionStartInField + modeledText.count
                let selectionStartInField = selectedRange.location
                let selectionEndInField = selectionStartInField + selectedRange.length
                guard selectionStartInField >= insertionStartInField,
                      selectionEndInField <= insertionEndInField else {
                    continue
                }

                let relativeSelectionEnd = selectionEndInField - insertionStartInField
                let caretOffsetFromEnd = modeledText.count - relativeSelectionEnd
                return RecoveredSelectionState(
                    caretOffsetFromEnd: caretOffsetFromEnd,
                    selectedRangeLength: selectedRange.length,
                    source: "selected_range_with_anchor"
                )
            }

            guard let fullText = fullTextSnapshot(from: element),
                  let modeledRange = uniqueRange(of: modeledText, in: fullText) else {
                continue
            }

            let modeledStartOffset = fullText.distance(from: fullText.startIndex, to: modeledRange.lowerBound)
            let modeledEndOffset = fullText.distance(from: fullText.startIndex, to: modeledRange.upperBound)
            let selectionStartInField = selectedRange.location
            let selectionEndInField = selectionStartInField + selectedRange.length
            guard selectionStartInField >= modeledStartOffset,
                  selectionEndInField <= modeledEndOffset else {
                continue
            }

            let relativeSelectionEnd = selectionEndInField - modeledStartOffset
            let caretOffsetFromEnd = modeledText.count - relativeSelectionEnd
            return RecoveredSelectionState(
                caretOffsetFromEnd: caretOffsetFromEnd,
                selectedRangeLength: selectedRange.length,
                source: "selected_range_with_full_text"
            )
        }

        return nil
    }

    func fullTextSnapshot(from element: CorrectionLearningAccessibilityElement) -> String? {
        fullSnapshotResult(from: element)?.text
    }

    private func fullSnapshotResult(from element: CorrectionLearningAccessibilityElement) -> SnapshotResult? {
        let role = client.role(of: element)
        if let value = client.stringValue(on: element, attribute: kAXValueAttribute as CFString),
           let normalized = normalizedSnapshotText(value) {
            return SnapshotResult(text: normalized, source: .value, role: role, element: element)
        }
        if let attributedValue = client.attributedStringValue(on: element, attribute: kAXValueAttribute as CFString),
           let normalized = normalizedSnapshotText(attributedValue) {
            return SnapshotResult(text: normalized, source: .attributedValue, role: role, element: element)
        }
        if let fullRangeValue = fullRangeStringValue(on: element),
           let normalized = normalizedSnapshotText(fullRangeValue) {
            return SnapshotResult(text: normalized, source: .fullRange, role: role, element: element)
        }
        if let fullTextMarkerValue = fullTextMarkerRangeStringValue(on: element),
           let normalized = normalizedSnapshotText(fullTextMarkerValue) {
            return SnapshotResult(text: normalized, source: .fullTextMarkerRange, role: role, element: element)
        }
        return nil
    }

    func candidateElements(startingAt element: CorrectionLearningAccessibilityElement) -> [CorrectionLearningAccessibilityElement] {
        var ancestors: [CorrectionLearningAccessibilityElement] = []
        var visited = Set<CorrectionLearningAccessibilityElement>()
        var current: CorrectionLearningAccessibilityElement? = element

        for _ in 0..<maxAncestorDepth {
            guard let node = current, visited.insert(node).inserted else { break }
            ancestors.append(node)
            current = client.parent(of: node)
        }

        var preferredDescendants: [CorrectionLearningAccessibilityElement] = []
        var fallbackDescendants: [CorrectionLearningAccessibilityElement] = []
        var queue = ancestors.map { ($0, 0) }
        var queued = Set(ancestors)
        var inspectedDescendants = 0

        while !queue.isEmpty, inspectedDescendants < maxDescendantNodes {
            let (node, depth) = queue.removeFirst()
            guard depth < maxDescendantDepth else { continue }

            for attribute in candidateAttributes {
                for child in client.childElements(of: node, attribute: attribute) {
                    guard queued.insert(child).inserted else { continue }
                    queue.append((child, depth + 1))
                    inspectedDescendants += 1
                    if visited.contains(child) {
                        continue
                    }
                    visited.insert(child)
                    if isPreferredCandidateRole(client.role(of: child)) {
                        preferredDescendants.append(child)
                    } else {
                        fallbackDescendants.append(child)
                    }
                    if inspectedDescendants >= maxDescendantNodes {
                        break
                    }
                }
                if inspectedDescendants >= maxDescendantNodes {
                    break
                }
            }
        }

        return ancestors + preferredDescendants + fallbackDescendants
    }

    private func firstFocusedSnapshot(
        startingAt element: CorrectionLearningAccessibilityElement,
        anchorText: String? = nil
    ) -> SnapshotResult? {
        var bestSnapshot: SnapshotResult?
        var bestScore = Int.min
        let normalizedAnchorText = normalizeAnchor(anchorText)
        let anchorTokens = normalizedAnchorText.map(normalizedAnchorTokens(from:)) ?? []

        for (index, candidate) in candidateElements(startingAt: element).enumerated() {
            if let snapshot = snapshotResult(from: candidate) {
                let score = snapshotSelectionScore(
                    snapshot,
                    anchorText: normalizedAnchorText,
                    anchorTokens: anchorTokens,
                    orderIndex: index
                )
                if score > bestScore {
                    bestScore = score
                    bestSnapshot = snapshot
                }
            }
        }
        return bestSnapshot
    }

    private func snapshotResult(from element: CorrectionLearningAccessibilityElement) -> SnapshotResult? {
        fullSnapshotResult(from: element) ?? fallbackSnapshotText(from: element)
    }

    private func fallbackSnapshotText(from element: CorrectionLearningAccessibilityElement) -> SnapshotResult? {
        let role = client.role(of: element)

        if let selectedText = client.stringValue(on: element, attribute: kAXSelectedTextAttribute as CFString),
           !selectedText.isEmpty,
           let normalized = normalizedSnapshotText(selectedText) {
            return SnapshotResult(text: normalized, source: .selectedText, role: role, element: element)
        }
        if let visibleRangeValue = visibleRangeStringValue(on: element),
           let normalized = normalizedSnapshotText(visibleRangeValue) {
            return SnapshotResult(text: normalized, source: .visibleRange, role: role, element: element)
        }
        if let selectedTextMarkerValue = selectedTextMarkerRangeStringValue(on: element),
           let normalized = normalizedSnapshotText(selectedTextMarkerValue) {
            return SnapshotResult(text: normalized, source: .selectedTextMarkerRange, role: role, element: element)
        }
        return nil
    }

    private func recoverSelectionStateFromSelectedText(
        modeledText: String,
        element: CorrectionLearningAccessibilityElement
    ) -> RecoveredSelectionState? {
        let selectedText: String?
        let source: String

        if let rawSelectedText = client.stringValue(on: element, attribute: kAXSelectedTextAttribute as CFString),
           !rawSelectedText.isEmpty {
            selectedText = rawSelectedText
            source = "selected_text"
        } else if let textMarkerSelectedText = selectedTextMarkerRangeStringValue(on: element) {
            selectedText = textMarkerSelectedText
            source = "selected_text_marker"
        } else {
            selectedText = nil
            source = ""
        }

        guard let selectedText,
              let normalizedSelectedText = normalizedSnapshotText(selectedText),
              !normalizedSelectedText.isEmpty,
              normalizedSelectedText.count <= modeledText.count,
              let selectedRangeInModeledText = uniqueRange(of: normalizedSelectedText, in: modeledText) else {
            return nil
        }

        let selectedRangeUpperOffset = modeledText.distance(
            from: selectedRangeInModeledText.upperBound,
            to: modeledText.endIndex
        )
        return RecoveredSelectionState(
            caretOffsetFromEnd: selectedRangeUpperOffset,
            selectedRangeLength: normalizedSelectedText.count,
            source: source
        )
    }

    private func elementsToInspect(
        preferredElement: CorrectionLearningAccessibilityElement?
    ) -> [CorrectionLearningAccessibilityElement] {
        if let preferredElement {
            return candidateElements(startingAt: preferredElement)
        }
        guard let focusedElement = client.focusedElement() else {
            return []
        }
        return candidateElements(startingAt: focusedElement)
    }

    private func visibleRangeStringValue(on element: CorrectionLearningAccessibilityElement) -> String? {
        guard let visibleRange = client.rangeValue(on: element, attribute: kAXVisibleCharacterRangeAttribute as CFString),
              visibleRange.length > 0 else {
            return nil
        }
        return stringForRange(on: element, range: visibleRange)
    }

    private func stringForRange(on element: CorrectionLearningAccessibilityElement, range: CFRange) -> String? {
        guard let rawElement = element.rawElement else { return nil }

        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var rangeStringValue: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            rawElement,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rangeStringValue
        )
        guard status == .success,
              let rangeStringValue,
              CFGetTypeID(rangeStringValue) == CFStringGetTypeID() else {
            return nil
        }

        return rangeStringValue as? String
    }

    private func fullRangeStringValue(on element: CorrectionLearningAccessibilityElement) -> String? {
        guard let characterCount = client.integerValue(on: element, attribute: kAXNumberOfCharactersAttribute as CFString),
              characterCount > 0 else {
            return nil
        }

        let range = CFRange(location: 0, length: Int(min(characterCount, maxSnapshotLength)))
        return stringForRange(on: element, range: range)
    }

    private func selectedTextMarkerRangeStringValue(on element: CorrectionLearningAccessibilityElement) -> String? {
        guard let textMarkerRange = client.textMarkerRangeValue(on: element, attribute: selectedTextMarkerRangeAttribute) else {
            return nil
        }
        return client.stringValue(
            on: element,
            textMarkerRange: textMarkerRange,
            attribute: stringForTextMarkerRangeAttribute
        )
    }

    private func fullTextMarkerRangeStringValue(on element: CorrectionLearningAccessibilityElement) -> String? {
        guard let textMarkerRange = client.parameterizedTextMarkerRangeValue(
            on: element,
            attribute: textMarkerRangeForUIElementAttribute,
            parameterElement: element
        ) else {
            return nil
        }
        return client.stringValue(
            on: element,
            textMarkerRange: textMarkerRange,
            attribute: stringForTextMarkerRangeAttribute
        )
    }

    private func normalizedSnapshotText(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty, normalized.count <= maxSnapshotLength else {
            return nil
        }
        return normalized
    }

    private func uniqueRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }

        var searchStart = haystack.startIndex
        var uniqueMatch: Range<String.Index>?
        while searchStart <= haystack.endIndex,
              let match = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if uniqueMatch != nil {
                return nil
            }
            uniqueMatch = match

            if match.lowerBound < haystack.endIndex {
                searchStart = haystack.index(after: match.lowerBound)
            } else {
                break
            }
        }
        return uniqueMatch
    }

    private func isPreferredCandidateRole(_ role: String?) -> Bool {
        guard let role else { return false }
        let preferredRoles: Set<String> = [
            webAreaRole,
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXStaticTextRole as String,
            kAXGroupRole as String,
        ]
        return preferredRoles.contains(role)
    }

    private func snapshotSelectionScore(
        _ snapshot: SnapshotResult,
        anchorText: String?,
        anchorTokens: [String],
        orderIndex: Int
    ) -> Int {
        let roleScore = rolePriority(for: snapshot.role)
        let orderScore = max(0, 100 - orderIndex)
        guard let anchorText, !anchorText.isEmpty else {
            return roleScore + orderScore
        }

        let normalizedSnapshot = CustomVocabularyManager.normalizedLookupKey(snapshot.text)
        let collapsedSnapshot = CustomVocabularyManager.normalizedCollapsedKey(snapshot.text)
        let collapsedAnchor = CustomVocabularyManager.normalizedCollapsedKey(anchorText)
        let snapshotTokens = normalizedAnchorTokens(from: normalizedSnapshot)
        let snapshotTokenSet = Set(snapshotTokens)

        var score = roleScore + orderScore

        if normalizedSnapshot == anchorText {
            score += 10_000
        } else if !collapsedAnchor.isEmpty, collapsedSnapshot == collapsedAnchor {
            score += 9_000
        } else if normalizedSnapshot.contains(anchorText) {
            score += 8_000
        } else if !collapsedAnchor.isEmpty, collapsedSnapshot.contains(collapsedAnchor) {
            score += 7_000
        }

        let overlapCount = anchorTokens.reduce(0) { partialResult, token in
            partialResult + (snapshotTokenSet.contains(token) ? 1 : 0)
        }
        score += overlapCount * 400

        if !anchorTokens.isEmpty {
            let recall = Double(overlapCount) / Double(anchorTokens.count)
            let precision = snapshotTokens.isEmpty ? 0 : Double(overlapCount) / Double(snapshotTokens.count)
            let f1: Double
            if precision > 0, recall > 0 {
                f1 = (2 * precision * recall) / (precision + recall)
            } else {
                f1 = 0
            }

            score += Int(recall * 2_000)
            score += Int(precision * 3_000)
            score += Int(f1 * 4_000)

            if recall < 0.25 {
                score -= 3_000
            }
            if precision < 0.35 {
                score -= 2_500
            }

            let extraTokenCount = max(0, snapshotTokens.count - overlapCount)
            score -= min(extraTokenCount * 250, 6_000)
        }

        let lengthDelta = abs(snapshot.text.count - anchorText.count)
        score -= min(lengthDelta * 2, 2_000)

        if snapshot.text.count < max(8, anchorText.count / 2) {
            score -= 2_000
        }

        if normalizedSnapshot.contains(anchorText) {
            let trailingCharacters = max(0, snapshot.text.count - anchorText.count)
            score -= min(trailingCharacters * 20, 5_000)
        }

        return score
    }

    private func rolePriority(for role: String?) -> Int {
        guard let role else { return 0 }
        if role == webAreaRole {
            return 300
        }
        if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
            return 250
        }
        if role == kAXGroupRole as String {
            return 150
        }
        if role == "AXToolbar" {
            return -3_000
        }
        if role == kAXStaticTextRole as String {
            return 50
        }
        return 0
    }

    private func normalizeAnchor(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = CustomVocabularyManager.normalizedLookupKey(text)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedAnchorTokens(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
