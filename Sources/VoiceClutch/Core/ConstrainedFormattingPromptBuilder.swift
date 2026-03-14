import Foundation

/// Builds a constrained JSON prompt for the formatting LLM
struct ConstrainedFormattingPromptBuilder {
    let glossaryLimit: Int
    let maxPreviousSentences: Int
    let useJsonOutput: Bool

    init(
        glossaryLimit: Int = 24,
        maxPreviousSentences: Int = 3,
        useJsonOutput: Bool = true
    ) {
        self.glossaryLimit = glossaryLimit
        self.maxPreviousSentences = maxPreviousSentences
        self.useJsonOutput = useJsonOutput
    }

    func buildPrompt(
        for request: LocalLLMRequest,
        extendedContext: ExtendedFormattingContext
    ) -> String {
        var sections: [String] = []

        // System instruction with strict contract
        sections.append(systemContract())

        // Domain-specific instructions
        sections.append(domainInstructions(for: extendedContext))

        // Style preferences
        let styleInstructions = extendedContext.stylePreferences.promptInstructions()
        if !styleInstructions.isEmpty {
            sections.append("")
            sections.append("Style Preferences:")
            sections.append(contentsOf: styleInstructions)
        }

        // Protected spans warning
        if !extendedContext.protectedSpans.isEmpty {
            sections.append("")
            sections.append("PROTECTED SPANS - The following text must remain EXACTLY as written:")
            for span in extendedContext.protectedSpans.prefix(5) {
                let preview = String(span.text.prefix(60))
                sections.append("- [\(span.type.rawValue)] \(preview)\(span.text.count > 60 ? "..." : "")")
            }
        }

        // Context
        sections.append("")
        sections.append(contextSection(for: extendedContext))

        // Input text
        sections.append("")
        sections.append("INPUT TEXT TO FORMAT:")
        sections.append(request.deterministicTranscript)

        // Output format
        sections.append("")
        if useJsonOutput {
            sections.append(jsonOutputFormat())
        } else {
            sections.append("Return only the formatted text with no additional commentary.")
        }

        return sections.joined(separator: "\n")
    }

    // MARK: - Private

    private func systemContract() -> String {
        """
        You are a TRANSCRIPTION POST-EDITOR. Your role is narrowly constrained.

        GOAL: Make only MINIMAL edits needed for readability while preserving exact meaning.

        ALLOWED CHANGES:
        - Fix punctuation and capitalization
        - Fix obvious spacing issues
        - Split into paragraphs if clearly appropriate
        - Correct obvious ASR mistakes ONLY when highly confident (e.g., "voice clutch" → "VoiceClutch")
        - Normalize spoken punctuation commands if present ("period", "comma", etc.)

        DO NOT:
        - Add new information or words
        - Rephrase for "better" style
        - Shorten or expand the text
        - "Improve" tone or flow
        - Change technical terms, code, URLs, names, or product terms unless in the vocabulary list
        - Make semantic changes of any kind

        If the text already looks correct, return it unchanged.
        """
    }

    private func domainInstructions(for context: ExtendedFormattingContext) -> String {
        switch context.domain {
        case .code, .terminal:
            return """
            DOMAIN: Code/Terminal
            Be EXTRA CONSERVATIVE. Prefer leaving text untouched over risking corruption of literals,
            commands, or code. Only fix obvious punctuation/capitalization errors in prose comments.
            """
        case .messaging:
            return """
            DOMAIN: Messaging
            Keep the result lightweight and natural for chat-style writing.
            Minimal punctuation is acceptable.
            """
        case .documents, .email:
            return """
            DOMAIN: Documents/Email
            Favor clean sentence boundaries and standard prose punctuation.
            Use proper capitalization for sentences.
            """
        case .general:
            return """
            DOMAIN: General
            Apply balanced formatting appropriate for general prose.
            """
        }
    }

    private func contextSection(for context: ExtendedFormattingContext) -> String {
        var lines: [String] = []

        if let appName = context.appName {
            lines.append("Frontmost app: \(appName)")
        }
        if let bundleId = context.bundleIdentifier {
            lines.append("Bundle ID: \(bundleId)")
        }
        lines.append("Domain: \(context.domain.rawValue)")

        // Previous sentences
        let previous = context.previousSentences
        if !previous.isEmpty {
            lines.append("")
            lines.append("Previous sentences (for context only - do not rewrite these):")
            for (i, sentence) in previous.enumerated() {
                lines.append("  \(i + 1). \(sentence)")
            }
        }

        // Recent corrections
        let corrections = context.recentCorrections
        if !corrections.isEmpty {
            lines.append("")
            lines.append("Recent corrections learned from user edits:")
            for correction in corrections.prefix(6) {
                lines.append("  - \(correction.source) → \(correction.target)")
            }
        }

        // Vocabulary
        return lines.joined(separator: "\n")
    }

    private func jsonOutputFormat() -> String {
        """
        OUTPUT FORMAT (JSON only, no markdown):

        {
          "final_text": "the formatted text here",
          "edits": [
            {"from": "original", "to": "corrected", "reason": "punctuation|capitalization|spacing|paragraph|obvious_asr_fix"}
          ]
        }

        Return ONLY valid JSON. No commentary, no markdown code blocks.
        """
    }
}

/// Parses structured JSON responses from the LLM
struct StructuredResponseParser {
    func parse(_ raw: String) -> StructuredFormattingResponse? {
        let sanitized = sanitize(raw)

        if let response = decodeStructuredJson(from: sanitized) {
            return response
        }

        guard let extracted = extractJsonFromMarkdown(sanitized),
              extracted != sanitized else {
            return nil
        }

        return decodeStructuredJson(from: extracted)
    }

    private func decodeStructuredJson(from text: String) -> StructuredFormattingResponse? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let response = try decoder.decode(StructuredFormattingResponse.self, from: data)
            return response
        } catch {
            return nil
        }
    }

    private func sanitize(_ text: String) -> String {
        var sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code block markers
        if sanitized.hasPrefix("```json") {
            sanitized = String(sanitized.dropFirst(7))
        } else if sanitized.hasPrefix("```") {
            sanitized = String(sanitized.dropFirst(3))
        }

        if sanitized.hasSuffix("```") {
            sanitized = String(sanitized.dropLast(3))
        }

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJsonFromMarkdown(_ text: String) -> String? {
        // Look for JSON between { and } pairs
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}") else {
            return nil
        }

        let potential = String(text[firstBrace...lastBrace])
        // Validate it looks like JSON
        if potential.contains("\"final_text\"") || potential.contains("\"finalText\"") {
            return potential
        }

        return nil
    }
}

/// Validates structured responses with edit-type awareness
struct StructuredResponseValidator {
    private let protectedSpanDetector = ProtectedSpanDetector()

    func validate(
        response: StructuredFormattingResponse,
        original: String,
        vocabulary: CustomVocabularySnapshot
    ) -> LocalLLMValidationDecision {
        let finalText = response.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = original.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalText.isEmpty else {
            return .rejected(.emptyOutput)
        }

        // Check if protected spans were modified
        let protectedSpans = protectedSpanDetector.detectProtectedSpans(in: originalText)
        if modifiesProtectedSpans(from: originalText, to: finalText, protected: protectedSpans) {
            return .rejected(.protectedTermsChanged)
        }

        // Check if vocabulary terms were changed
        if changesVocabularyTerms(from: originalText, to: finalText, vocabulary: vocabulary) {
            return .rejected(.protectedTermsChanged)
        }

        if response.edits.isEmpty {
            return finalText == originalText
                ? .accepted(finalText)
                : .rejected(.wordingChanged)
        }

        // If all edits are punctuation/capitalization only, be more lenient
        if response.isFormattingOnly {
            // Check for excessive changes even if punctuation-only
            if isExcessivePunctuationChanges(original: originalText, formatted: finalText) {
                return .rejected(.excessiveRewrite)
            }
            return .accepted(finalText)
        }

        // For ASR fixes, check word token preservation
        let originalTokens = normalizedWordTokens(from: originalText)
        let formattedTokens = normalizedWordTokens(from: finalText)

        if originalTokens == formattedTokens {
            return .accepted(finalText)
        }

        // Check for content drop
        if dropsTooMuchContent(candidate: finalText, reference: originalText) {
            return .rejected(.droppedContent)
        }

        // Check edit distance
        let collapsedOriginal = collapsedTokenKey(originalText)
        let collapsedFormatted = collapsedTokenKey(finalText)
        let distance = editDistance(collapsedOriginal, collapsedFormatted)
        let allowedDistance = max(2, max(collapsedOriginal.count, collapsedFormatted.count) / 10)

        if distance > allowedDistance {
            return .rejected(.excessiveRewrite)
        }

        // If there are "obvious_asr_fix" edits, allow some token changes
        let hasAsrFixes = response.edits.contains { $0.reason == .obviousAsrFix }
        if hasAsrFixes && abs(originalTokens.count - formattedTokens.count) <= 2 {
            return .accepted(finalText)
        }

        return .rejected(.wordingChanged)
    }

    private func modifiesProtectedSpans(
        from original: String,
        to formatted: String,
        protected: [ProtectedSpan]
    ) -> Bool {
        guard !protected.isEmpty else { return false }

        for span in protected {
            if !formatted.contains(span.text) {
                return true
            }
        }

        return false
    }

    private func changesVocabularyTerms(
        from original: String,
        to formatted: String,
        vocabulary: CustomVocabularySnapshot
    ) -> Bool {
        let formattedTokens = normalizedWordTokens(from: formatted)
        let originalTokens = normalizedWordTokens(from: original)

        for entry in CustomVocabularyManager.glossaryEntries(from: vocabulary, limit: 24) {
            let preferredTokens = normalizedWordTokens(from: entry.preferred)
            guard !preferredTokens.isEmpty else { continue }

            // If the term exists in original but not in formatted, it was changed
            guard containsPhrase(preferredTokens, in: originalTokens) else { continue }
            guard containsPhrase(preferredTokens, in: formattedTokens) else {
                return true
            }
        }

        return false
    }

    private func dropsTooMuchContent(candidate: String, reference: String) -> Bool {
        let candidateTokens = normalizedWordTokens(from: candidate)
        let referenceTokens = normalizedWordTokens(from: reference)
        guard !referenceTokens.isEmpty else { return false }

        var candidateIndex = 0
        var matchedCount = 0

        for referenceToken in referenceTokens {
            while candidateIndex < candidateTokens.count {
                if candidateTokens[candidateIndex] == referenceToken {
                    matchedCount += 1
                    candidateIndex += 1
                    break
                }
                candidateIndex += 1
            }
        }

        let missingCount = referenceTokens.count - matchedCount
        let allowedMissingCount = max(0, referenceTokens.count / 12)
        return missingCount > allowedMissingCount
    }

    private func isExcessivePunctuationChanges(original: String, formatted: String) -> Bool {
        // Check if more than 30% of characters are punctuation changes
        let originalCollapsed = collapsedTokenKey(original)
        let formattedCollapsed = collapsedTokenKey(formatted)

        guard originalCollapsed == formattedCollapsed else {
            return false  // Content changed, not just punctuation
        }

        // Check length changes from punctuation
        let lengthDelta = abs(formatted.count - original.count)
        let allowedDelta = max(5, original.count / 20)
        return lengthDelta > allowedDelta
    }

    private func containsPhrase(_ phraseTokens: [String], in tokens: [String]) -> Bool {
        guard !phraseTokens.isEmpty, phraseTokens.count <= tokens.count else {
            return false
        }

        for index in 0...(tokens.count - phraseTokens.count) where Array(tokens[index..<(index + phraseTokens.count)]) == phraseTokens {
            return true
        }

        return false
    }

    private func collapsedTokenKey(_ text: String) -> String {
        text.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        var previousRow = Array(0...rhsCharacters.count)
        var currentRow = Array(repeating: 0, count: rhsCharacters.count + 1)

        for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
            currentRow[0] = lhsIndex + 1

            for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
                let substitutionCost = lhsCharacter == rhsCharacter ? 0 : 1
                currentRow[rhsIndex + 1] = min(
                    previousRow[rhsIndex + 1] + 1,
                    currentRow[rhsIndex] + 1,
                    previousRow[rhsIndex] + substitutionCost
                )
            }

            swap(&previousRow, &currentRow)
        }

        return previousRow[rhsCharacters.count]
    }
}
