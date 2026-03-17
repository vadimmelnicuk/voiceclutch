import Foundation

private let normalizedTokenCharacterSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
private let contractionExpansionMap: [String: [String]] = [
    "i'm": ["i", "am"],
    "you're": ["you", "are"],
    "we're": ["we", "are"],
    "they're": ["they", "are"],
    "he's": ["he", "is"],
    "she's": ["she", "is"],
    "it's": ["it", "is"],
    "that's": ["that", "is"],
    "there's": ["there", "is"],
    "what's": ["what", "is"],
    "who's": ["who", "is"],
    "let's": ["let", "us"],
    "i've": ["i", "have"],
    "you've": ["you", "have"],
    "we've": ["we", "have"],
    "they've": ["they", "have"],
    "i'll": ["i", "will"],
    "you'll": ["you", "will"],
    "we'll": ["we", "will"],
    "they'll": ["they", "will"],
    "he'll": ["he", "will"],
    "she'll": ["she", "will"],
    "it'll": ["it", "will"],
    "i'd": ["i", "would"],
    "you'd": ["you", "would"],
    "we'd": ["we", "would"],
    "they'd": ["they", "would"],
    "he'd": ["he", "would"],
    "she'd": ["she", "would"],
    "it'd": ["it", "would"],
    "can't": ["can", "not"],
    "won't": ["will", "not"],
    "don't": ["do", "not"],
    "doesn't": ["does", "not"],
    "didn't": ["did", "not"],
    "isn't": ["is", "not"],
    "aren't": ["are", "not"],
    "wasn't": ["was", "not"],
    "weren't": ["were", "not"],
    "haven't": ["have", "not"],
    "hasn't": ["has", "not"],
    "hadn't": ["had", "not"],
    "wouldn't": ["would", "not"],
    "shouldn't": ["should", "not"],
    "couldn't": ["could", "not"],
    "mustn't": ["must", "not"],
    "mightn't": ["might", "not"],
    "needn't": ["need", "not"]
]

func normalizedWordTokens(from text: String) -> [String] {
    var normalizedTokens: [String] = []
    for token in normalizedForComparison(text).split(whereSeparator: \.isWhitespace) {
        let normalizedToken = String(token)
            .trimmingCharacters(in: normalizedTokenCharacterSet)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        guard !normalizedToken.isEmpty else { continue }

        if let expanded = contractionExpansionMap[normalizedToken] {
            normalizedTokens.append(contentsOf: expanded)
        } else if normalizedToken.hasSuffix("n't"), normalizedToken.count > 3 {
            let stem = String(normalizedToken.dropLast(3))
            if !stem.isEmpty {
                normalizedTokens.append(stem)
                normalizedTokens.append("not")
            }
        } else {
            normalizedTokens.append(normalizedToken)
        }
    }
    return normalizedTokens
}

func normalizedForComparison(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
}

struct TranscriptValidationEngine {
    private let logger = AppLogger(category: "TranscriptValidation")

    func validate(
        candidate: String,
        reference: String,
        vocabulary: CustomVocabularySnapshot,
        requiresCodeSyntaxPostEdit: Bool,
        protectedSpans: [ProtectedSpan]
    ) -> LocalLLMValidationDecision {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidateText = CodeSyntaxSpeechRepairPolicy.normalizedCodeSpeech(
            trimmedCandidate,
            requiresCodeSyntaxPostEdit: requiresCodeSyntaxPostEdit
        )
        let normalizedReferenceText = CodeSyntaxSpeechRepairPolicy.normalizedCodeSpeech(
            trimmedReference,
            requiresCodeSyntaxPostEdit: requiresCodeSyntaxPostEdit
        )

        guard !normalizedCandidateText.isEmpty else {
            return .rejected(.emptyOutput)
        }

        if containsPromptBoundaryMarkers(normalizedCandidateText),
           !containsPromptBoundaryMarkers(normalizedReferenceText) {
            return .rejected(.wordingChanged)
        }

        let candidateTokens = normalizedWordTokens(from: normalizedCandidateText)
        let referenceTokens = normalizedWordTokens(from: normalizedReferenceText)

        if candidateTokens == referenceTokens {
            return .accepted(normalizedCandidateText)
        }

        if requiresCodeSyntaxPostEdit,
           modifiesProtectedSpans(
               from: normalizedReferenceText,
               to: normalizedCandidateText,
               protected: protectedSpans
           ) {
            return .rejected(.protectedTermsChanged)
        }

        if changesVocabularyTerms(
            from: normalizedReferenceText,
            to: normalizedCandidateText,
            vocabulary: vocabulary
        ) {
            return requiresCodeSyntaxPostEdit
                ? .rejected(.wordingChanged)
                : .rejected(.protectedTermsChanged)
        }

        if collapsedTokenKey(normalizedCandidateText) == collapsedTokenKey(normalizedReferenceText) {
            return .accepted(normalizedCandidateText)
        }

        let isLikelyCodeSafe = requiresCodeSyntaxPostEdit && isLikelyCodeSafeSyntaxFix(
            candidate: normalizedCandidateText,
            reference: normalizedReferenceText
        )

        if dropsTooMuchContent(
            candidate: normalizedCandidateText,
            reference: normalizedReferenceText,
            allowsCodeSyntaxFixes: requiresCodeSyntaxPostEdit
        ) {
            if !requiresCodeSyntaxPostEdit {
                let overlap = Set(referenceTokens).intersection(Set(candidateTokens)).count
                let maxTokenCount = max(referenceTokens.count, candidateTokens.count)
                let overlapRatio = maxTokenCount > 0 ? Double(overlap) / Double(maxTokenCount) : 0.0
                let lengthRatio = !normalizedReferenceText.isEmpty
                    ? Double(normalizedCandidateText.count) / Double(normalizedReferenceText.count)
                    : 0.0

                if overlapRatio < 0.15 || lengthRatio < 0.35 || lengthRatio > 2.5 {
                    return .rejected(.droppedContent)
                }
            } else if !isLikelyCodeSafe {
                return .rejected(.droppedContent)
            }
        }

        if isExcessiveRewrite(
            candidate: normalizedCandidateText,
            reference: normalizedReferenceText,
            allowsCodeSyntaxFixes: requiresCodeSyntaxPostEdit
        ) {
            return requiresCodeSyntaxPostEdit
                ? .rejected(.wordingChanged)
                : .rejected(.excessiveRewrite)
        }

        if requiresCodeSyntaxPostEdit {
            return isLikelyCodeSafe
                ? .accepted(normalizedCandidateText)
                : .rejected(.wordingChanged)
        }

        let tokenOverlap = Set(referenceTokens).intersection(Set(candidateTokens)).count
        let maxTokenCount = max(referenceTokens.count, candidateTokens.count)
        let overlapRatio = maxTokenCount > 0 ? Double(tokenOverlap) / Double(maxTokenCount) : 0.0
        let retentionRatio = orderedTokenRetentionRatio(candidate: candidateTokens, reference: referenceTokens)
        if overlapRatio >= 0.45, retentionRatio >= 0.78 {
            return .accepted(normalizedCandidateText)
        }

        logger.debug(
            "Validation rejected candidateTokens=\(candidateTokens.count) referenceTokens=\(referenceTokens.count) overlap=\(String(format: "%.2f", overlapRatio)) retention=\(String(format: "%.2f", retentionRatio))"
        )
        return .rejected(.wordingChanged)
    }

    private func orderedTokenRetentionRatio(candidate: [String], reference: [String]) -> Double {
        guard !reference.isEmpty else { return 1.0 }
        let matchedCount = orderedMatchCount(candidate: candidate, reference: reference)
        return Double(matchedCount) / Double(reference.count)
    }

    private func dropsTooMuchContent(candidate: String, reference: String, allowsCodeSyntaxFixes: Bool) -> Bool {
        let candidateTokens = normalizedWordTokens(from: candidate)
        let referenceTokens = normalizedWordTokens(from: reference)
        guard !referenceTokens.isEmpty else { return false }
        let matchedCount = orderedMatchCount(candidate: candidateTokens, reference: referenceTokens)

        let missingCount = referenceTokens.count - matchedCount
        let allowedMissingCount = allowsCodeSyntaxFixes
            ? max(2, referenceTokens.count / 3)
            : max(2, referenceTokens.count / 2)
        return missingCount > allowedMissingCount
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
            guard containsPhrase(preferredTokens, in: originalTokens) else { continue }
            guard containsPhrase(preferredTokens, in: formattedTokens) else {
                return true
            }
        }

        return false
    }

    private func modifiesProtectedSpans(
        from original: String,
        to formatted: String,
        protected: [ProtectedSpan]
    ) -> Bool {
        guard !protected.isEmpty else { return false }
        guard !original.isEmpty else { return false }

        for span in protected where span.type != .command {
            if !formatted.contains(span.text) {
                return true
            }
        }

        return false
    }

    private func isLikelyCodeSafeSyntaxFix(candidate: String, reference: String) -> Bool {
        let candidateTokens = normalizedWordTokens(from: candidate).map(canonicalizedCodeToken)
        let referenceTokens = normalizedWordTokens(from: reference).map(canonicalizedCodeToken)
        let referenceCollapsed = collapsedTokenKey(reference)
        let candidateCollapsed = collapsedTokenKey(candidate)

        guard !referenceCollapsed.isEmpty, !candidateCollapsed.isEmpty else {
            return false
        }

        let droppedCount = droppedTokenCount(candidate: candidateTokens, reference: referenceTokens)
        let allowedDropped = max(2, referenceTokens.count * 2 / 3)
        guard droppedCount <= allowedDropped else { return false }

        let distance = editDistance(candidateCollapsed, referenceCollapsed)
        let allowedDistance = max(12, max(referenceCollapsed.count, candidateCollapsed.count) * 2 / 3)
        guard distance <= allowedDistance else { return false }

        let tokenOverlap = Set(referenceTokens).intersection(Set(candidateTokens)).count
        let maxTokens = max(referenceTokens.count, candidateTokens.count)
        let overlapRatio = maxTokens > 0 ? Double(tokenOverlap) / Double(maxTokens) : 0.0
        guard overlapRatio >= 0.55 else { return false }

        let allowedTokenGrowth = max(2, referenceTokens.count / 5)
        if candidateTokens.count > referenceTokens.count + allowedTokenGrowth {
            return false
        }

        return true
    }

    private func droppedTokenCount(candidate: [String], reference: [String]) -> Int {
        guard !reference.isEmpty else { return 0 }
        let matchedCount = orderedMatchCount(candidate: candidate, reference: reference)
        return reference.count - matchedCount
    }

    private func orderedMatchCount(candidate: [String], reference: [String]) -> Int {
        guard !candidate.isEmpty, !reference.isEmpty else { return 0 }

        var candidateStart = 0
        var matchedCount = 0

        for referenceToken in reference {
            guard candidateStart < candidate.count else { break }

            var searchIndex = candidateStart
            var foundIndex: Int?
            while searchIndex < candidate.count {
                if candidate[searchIndex] == referenceToken {
                    foundIndex = searchIndex
                    break
                }
                searchIndex += 1
            }

            if let foundIndex {
                matchedCount += 1
                candidateStart = foundIndex + 1
            }
        }

        return matchedCount
    }

    private func isExcessiveRewrite(candidate: String, reference: String, allowsCodeSyntaxFixes: Bool) -> Bool {
        if CustomVocabularyManager.normalizedLookupKey(candidate) == CustomVocabularyManager.normalizedLookupKey(reference) {
            return false
        }

        let candidateCollapsed = collapsedTokenKey(candidate)
        let referenceCollapsed = collapsedTokenKey(reference)
        guard !candidateCollapsed.isEmpty, !referenceCollapsed.isEmpty else {
            return true
        }

        let distance = editDistance(candidateCollapsed, referenceCollapsed)
        let maxLength = max(candidateCollapsed.count, referenceCollapsed.count)
        let allowedDistance = allowsCodeSyntaxFixes
            ? max(8, maxLength * 2 / 3)
            : max(12, maxLength * 2 / 3)
        return distance > allowedDistance
    }

    private func containsPromptBoundaryMarkers(_ text: String) -> Bool {
        if text.localizedCaseInsensitiveContains("END_INPUT") ||
            text.localizedCaseInsensitiveContains("INPUT_JSON") ||
            text.localizedCaseInsensitiveContains("OUTPUT_JSON") ||
            text.localizedCaseInsensitiveContains("RESPONSE_JSON") {
            return true
        }

        let lines = text.split(whereSeparator: \.isNewline)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.caseInsensitiveCompare("INPUT:") == .orderedSame ||
                trimmed.caseInsensitiveCompare("Input JSON:") == .orderedSame ||
                trimmed.caseInsensitiveCompare("Output JSON:") == .orderedSame
        }
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

    private func canonicalizedCodeToken(_ token: String) -> String {
        switch token {
        case "==", "===":
            return "="
        default:
            return token
        }
    }

    private func collapsedTokenKey(_ text: String) -> String {
        text.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func editDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs {
            return 0
        }
        if lhs.isEmpty {
            return rhs.count
        }
        if rhs.isEmpty {
            return lhs.count
        }

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
