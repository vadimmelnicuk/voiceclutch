import Foundation

struct TranscriptPostProcessingResult: Sendable {
    let deterministicTranscript: String
    let llmResponse: LocalLLMResponse
    let preLockTranscript: String
    let finalTranscript: String
    let appliedEdits: [TranscriptEdit]
}

@MainActor
final class TranscriptPostProcessor {
    private let correctionEngine: FinalTranscriptCorrectionEngine
    private let llmService: any LocalLLMServing
    private let contextProvider: any TranscriptFormattingContextProviding
    private let isSmartFormattingEnabled: () -> Bool

    private static let listLayoutRegex = try? NSRegularExpression(
        pattern: #"\n\s*\d+\.\s"#,
        options: []
    )
    private static let numberedListMarkerRegex = try? NSRegularExpression(
        pattern: #"(?:^|[\s\.,;:])(?:and\s+)?(?:option\s+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten)|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|one|two|three|four|five|six|seven|eight|nine|ten)\s*[,:\-]?\s+"#,
        options: [.caseInsensitive]
    )
    private static let bulletCueRegex = try? NSRegularExpression(
        pattern: #"\b(?:bullet point|bullet points|bullet list)\b"#,
        options: [.caseInsensitive]
    )
    private static let listDelimiterRegex = try? NSRegularExpression(
        pattern: #"\s*(?:,|;|\band\b|\bor\b)\s*"#,
        options: [.caseInsensitive]
    )

    init(
        correctionEngine: FinalTranscriptCorrectionEngine = FinalTranscriptCorrectionEngine(),
        llmService: any LocalLLMServing,
        contextProvider: any TranscriptFormattingContextProviding = FrontmostTranscriptFormattingContextProvider(),
        isSmartFormattingEnabled: @escaping () -> Bool = { LocalSmartFormattingPreference.load() }
    ) {
        self.correctionEngine = correctionEngine
        self.llmService = llmService
        self.contextProvider = contextProvider
        self.isSmartFormattingEnabled = isSmartFormattingEnabled
    }

    convenience init(
        correctionEngine: FinalTranscriptCorrectionEngine = FinalTranscriptCorrectionEngine(),
        contextProvider: any TranscriptFormattingContextProviding = FrontmostTranscriptFormattingContextProvider(),
        isSmartFormattingEnabled: @escaping () -> Bool = { LocalSmartFormattingPreference.load() }
    ) {
        self.init(
            correctionEngine: correctionEngine,
            llmService: LocalLLMCoordinator(),
            contextProvider: contextProvider,
            isSmartFormattingEnabled: isSmartFormattingEnabled
        )
    }

    func prepareIfPossible() async {
        await llmService.prepareIfPossible()
    }

    func handleMemoryPressure(level: LocalLLMMemoryPressureLevel) async {
        await llmService.handleMemoryPressure(level: level)
    }

    func process(
        transcript: String,
        vocabularySnapshot: CustomVocabularySnapshot,
        clipboardContextPreview: String? = nil
    ) async -> TranscriptPostProcessingResult {
        let formattingContext = contextProvider.currentContext()

        let correctedTranscript = correctionEngine.correctedTranscript(
            from: transcript,
            vocabulary: vocabularySnapshot
        )
        let deterministicTranscript = CodeSyntaxSpeechRepairPolicy.normalizedCodeSpeech(
            correctedTranscript,
            requiresCodeSyntaxPostEdit: formattingContext.requiresCodeSyntaxPostEdit
        )
        let listFormattingHint = ListFormattingIntentDetector.hint(
            for: deterministicTranscript,
            formattingContext: formattingContext
        )

        let request = LocalLLMRequest(
            capability: .smartFormatting,
            originalTranscript: transcript,
            deterministicTranscript: deterministicTranscript,
            vocabulary: vocabularySnapshot,
            formattingContext: formattingContext,
            listFormattingHint: listFormattingHint,
            clipboardContextPreview: clipboardContextPreview
        )

        let llmResponse: LocalLLMResponse
        if let skipReason = LocalLLMRequestEvaluator.skipReason(
            for: request,
            isEnabled: isSmartFormattingEnabled()
        ) {
            llmResponse = .skipped(transcript: deterministicTranscript, reason: skipReason)
        } else {
            llmResponse = await llmService.process(request)
        }

        let preLockTranscript: String
        switch llmResponse.outcome {
        case .refined, .unchanged:
            preLockTranscript = llmResponse.transcript
        case .unavailable, .skipped, .timedOut, .failed, .rejected:
            preLockTranscript = deterministicTranscript
        }
        let listFormattedTranscript = listFormattedTranscriptIfNeeded(
            preLockTranscript,
            hint: listFormattingHint
        )

        let finalTranscript: String
        if listFormattedTranscript == deterministicTranscript {
            finalTranscript = listFormattedTranscript
        } else {
            finalTranscript = correctionEngine.correctedTranscript(
                from: listFormattedTranscript,
                vocabulary: vocabularySnapshot
            )
        }

        let appliedEdits: [TranscriptEdit]
        if case .refined = llmResponse.outcome,
           deterministicTranscript != finalTranscript {
            appliedEdits = deriveEdits(from: deterministicTranscript, to: finalTranscript)
        } else {
            appliedEdits = []
        }

        return TranscriptPostProcessingResult(
            deterministicTranscript: deterministicTranscript,
            llmResponse: llmResponse,
            preLockTranscript: preLockTranscript,
            finalTranscript: finalTranscript,
            appliedEdits: appliedEdits
        )
    }

    func recordCorrection(source: String, target: String) async {
        guard let coordinator = llmService as? LocalLLMCoordinator else { return }
        await coordinator.recordCorrection(source: source, target: target)
    }

    func getCorrectionHistory() async -> [LearnedCorrection] {
        guard let coordinator = llmService as? LocalLLMCoordinator else { return [] }
        return await coordinator.getCorrectionHistory()
    }

    func clearHistory() async {
        guard let coordinator = llmService as? LocalLLMCoordinator else { return }
        await coordinator.clearHistory()
    }

    private func listFormattedTranscriptIfNeeded(_ text: String, hint: ListFormattingHint) -> String {
        guard hint != .none else {
            return text
        }

        if containsListLayout(text) {
            return text
        }

        switch hint {
        case .none:
            return text
        case .numbered:
            return formatEnumeratedNumberedList(text) ?? text
        case .bulleted:
            return formatBulletedListFromCue(text) ?? text
        }
    }

    private func containsListLayout(_ text: String) -> Bool {
        if text.contains("\n- ") {
            return true
        }

        guard let regex = Self.listLayoutRegex else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func formatEnumeratedNumberedList(_ text: String) -> String? {
        guard let regex = Self.numberedListMarkerRegex else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard matches.count >= 2 else {
            return nil
        }

        guard let firstMarkerRange = Range(matches[0].range, in: text) else {
            return nil
        }
        let intro = String(text[..<firstMarkerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        var items: [String] = []
        for (index, match) in matches.enumerated() {
            guard let markerRange = Range(match.range, in: text) else { continue }
            let contentStart = markerRange.upperBound
            let contentEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: text) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = text.endIndex
            }

            let rawItem = String(text[contentStart..<contentEnd])
            let cleanedItem = rawItem.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
            )
            if !cleanedItem.isEmpty {
                items.append(cleanedItem)
            }
        }

        guard items.count >= 2 else {
            return nil
        }

        let numbered = items.enumerated().map { index, item in
            "\(index + 1). \(item)"
        }

        if intro.isEmpty {
            return numbered.joined(separator: "\n")
        }

        return "\(intro)\n" + numbered.joined(separator: "\n")
    }

    private func formatBulletedListFromCue(_ text: String) -> String? {
        guard let cueRegex = Self.bulletCueRegex else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let cueMatch = cueRegex.firstMatch(in: text, options: [], range: range),
              let cueRange = Range(cueMatch.range, in: text) else {
            return nil
        }

        var afterCue = String(text[cueRange.upperBound...])
        afterCue = afterCue.trimmingCharacters(in: .whitespacesAndNewlines)
        if afterCue.hasPrefix(":") {
            afterCue.removeFirst()
            afterCue = afterCue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !afterCue.isEmpty else {
            return nil
        }

        let parts = splitByListDelimiters(afterCue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,"))) }
            .filter { !$0.isEmpty }

        guard parts.count >= 2 else {
            return nil
        }

        let intro = String(text[..<cueRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bulleted = parts.map { "- \($0)" }.joined(separator: "\n")

        if intro.isEmpty {
            return bulleted
        }

        return "\(intro)\n\(bulleted)"
    }

    private func splitByListDelimiters(_ text: String) -> [String] {
        guard let regex = Self.listDelimiterRegex else {
            return [text]
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return [text]
        }

        var parts: [String] = []
        var currentStart = text.startIndex

        for match in matches {
            guard let delimiterRange = Range(match.range, in: text) else { continue }
            let segment = String(text[currentStart..<delimiterRange.lowerBound])
            parts.append(segment)
            currentStart = delimiterRange.upperBound
        }

        if currentStart < text.endIndex {
            parts.append(String(text[currentStart...]))
        }

        return parts
    }

    private func deriveEdits(from original: String, to modified: String) -> [TranscriptEdit] {
        // Simple character-level diff to extract edits
        var edits: [TranscriptEdit] = []

        // Find changed regions
        let originalChars = Array(original)
        let modifiedChars = Array(modified)
        let maxCommonPrefix = zip(originalChars, modifiedChars)
            .prefix(while: { $0 == $1 })
            .count

        let maxCommonSuffix = zip(originalChars.reversed(), modifiedChars.reversed())
            .prefix(while: { $0 == $1 })
            .count

        guard maxCommonPrefix + maxCommonSuffix < originalChars.count ||
              maxCommonPrefix + maxCommonSuffix < modifiedChars.count else {
            return edits
        }

        // Clamp suffix to available characters to avoid invalid ranges
        let originalRemaining = max(0, originalChars.count - maxCommonPrefix)
        let modifiedRemaining = max(0, modifiedChars.count - maxCommonPrefix)
        let clampedSuffix = min(maxCommonSuffix, originalRemaining, modifiedRemaining)

        let originalEditStart = originalChars.index(originalChars.startIndex, offsetBy: maxCommonPrefix)
        let originalEditEnd = originalChars.index(originalChars.endIndex, offsetBy: -clampedSuffix)
        let modifiedEditStart = modifiedChars.index(modifiedChars.startIndex, offsetBy: maxCommonPrefix)
        let modifiedEditEnd = modifiedChars.index(modifiedChars.endIndex, offsetBy: -clampedSuffix)

        // Ensure ranges are valid (start < end)
        guard originalEditStart < originalEditEnd,
              modifiedEditStart < modifiedEditEnd else {
            return edits
        }

        let fromText = String(originalChars[originalEditStart..<originalEditEnd])
        let toText = String(modifiedChars[modifiedEditStart..<modifiedEditEnd])

        // Determine edit type
        let editType: TranscriptEditType
        let fromLetters = fromText.filter { $0.isLetter || $0.isNumber }
        let toLetters = toText.filter { $0.isLetter || $0.isNumber }

        if fromLetters == toLetters {
            editType = .punctuation
        } else if fromText.lowercased() == toText.lowercased() {
            editType = .capitalization
        } else if fromText.filter({ !$0.isWhitespace }).isEmpty || toText.filter({ !$0.isWhitespace }).isEmpty {
            editType = .spacing
        } else {
            editType = .obviousAsrFix
        }

        edits.append(TranscriptEdit(from: fromText, to: toText, reason: editType))

        return edits
    }
}
