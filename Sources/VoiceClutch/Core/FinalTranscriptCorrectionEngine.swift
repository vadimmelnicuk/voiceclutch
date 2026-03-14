import Foundation

struct FinalTranscriptCorrectionEngine {
    private struct WordSpan {
        let range: Range<String.Index>
        let text: String
        let normalized: String
        let collapsed: String
        let soundex: String
    }

    private struct FuzzyDefinition {
        let source: String
        let replacement: String
        let wordCount: Int
        let normalized: String
        let collapsed: String
        let soundex: String
    }

    private struct CandidateScore {
        let replacement: String
        let score: Double
    }

    private struct CandidateMatch {
        let range: Range<String.Index>
        let replacement: String
        let wordCount: Int
        let score: Double
    }

    func correctedTranscript(from text: String, vocabulary: CustomVocabularySnapshot) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let rewritten = CustomVocabularyManager.applyRewriteRules(to: trimmed, snapshot: vocabulary)
        return applyFuzzyCorrections(to: rewritten, vocabulary: vocabulary)
    }

    private func applyFuzzyCorrections(to text: String, vocabulary: CustomVocabularySnapshot) -> String {
        let wordSpans = self.wordSpans(in: text)
        guard !wordSpans.isEmpty else { return text }

        let groupedCandidates = Dictionary(grouping: fuzzyDefinitions(from: vocabulary), by: \.wordCount)
        guard !groupedCandidates.isEmpty else { return text }

        let maxWordCount = groupedCandidates.keys.max() ?? 0
        guard maxWordCount > 0 else { return text }

        var matches: [CandidateMatch] = []
        for startIndex in wordSpans.indices {
            let remainingWords = wordSpans.count - startIndex
            let upperBound = min(maxWordCount, remainingWords)
            guard upperBound > 0 else { continue }

            for wordCount in 1...upperBound {
                guard let candidates = groupedCandidates[wordCount], !candidates.isEmpty else { continue }
                let endIndex = startIndex + wordCount - 1
                let phrase = joinedPhrase(from: wordSpans[startIndex...endIndex], in: text)
                guard let score = bestCandidate(for: phrase, candidates: candidates) else {
                    continue
                }

                matches.append(
                    CandidateMatch(
                        range: wordSpans[startIndex].range.lowerBound..<wordSpans[endIndex].range.upperBound,
                        replacement: score.replacement,
                        wordCount: wordCount,
                        score: score.score
                    )
                )
            }
        }

        guard !matches.isEmpty else { return text }

        let selectedMatches = selectNonOverlappingMatches(matches, in: text)
        guard !selectedMatches.isEmpty else { return text }

        var corrected = text
        for match in selectedMatches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            corrected.replaceSubrange(match.range, with: match.replacement)
        }
        return corrected
    }

    private func fuzzyDefinitions(from vocabulary: CustomVocabularySnapshot) -> [FuzzyDefinition] {
        CustomVocabularyManager.fuzzyCandidates(from: vocabulary).compactMap { candidate in
            let normalized = CustomVocabularyManager.normalizedLookupKey(candidate.source)
            let collapsed = CustomVocabularyManager.normalizedCollapsedKey(candidate.source)
            let wordCount = candidate.source.split(whereSeparator: \.isWhitespace).count
            guard
                !normalized.isEmpty,
                !collapsed.isEmpty,
                wordCount > 0,
                collapsed.count >= 4
            else {
                return nil
            }

            return FuzzyDefinition(
                source: candidate.source,
                replacement: candidate.replacement,
                wordCount: wordCount,
                normalized: normalized,
                collapsed: collapsed,
                soundex: soundexPhrase(candidate.source)
            )
        }
    }

    private func wordSpans(in text: String) -> [WordSpan] {
        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}'’-]*", options: []) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let token = String(text[matchRange])
            let normalized = CustomVocabularyManager.normalizedLookupKey(token)
            let collapsed = CustomVocabularyManager.normalizedCollapsedKey(token)
            guard !normalized.isEmpty, !collapsed.isEmpty else { return nil }

            return WordSpan(
                range: matchRange,
                text: token,
                normalized: normalized,
                collapsed: collapsed,
                soundex: soundex(token)
            )
        }
    }

    private func joinedPhrase(from spans: ArraySlice<WordSpan>, in text: String) -> String {
        guard let first = spans.first, let last = spans.last else { return "" }
        return String(text[first.range.lowerBound..<last.range.upperBound])
    }

    private func bestCandidate(for phrase: String, candidates: [FuzzyDefinition]) -> CandidateScore? {
        let normalizedPhrase = CustomVocabularyManager.normalizedLookupKey(phrase)
        let collapsedPhrase = CustomVocabularyManager.normalizedCollapsedKey(phrase)
        guard !normalizedPhrase.isEmpty, !collapsedPhrase.isEmpty, collapsedPhrase.count >= 4 else {
            return nil
        }

        let phraseSoundex = soundexPhrase(phrase)
        let phraseFirstCharacter = collapsedPhrase.first
        let phraseLastCharacter = collapsedPhrase.last

        var best: CandidateScore?
        var secondBestScore = 0.0

        for candidate in candidates {
            guard CustomVocabularyManager.normalizedLookupKey(candidate.replacement) != normalizedPhrase else {
                continue
            }
            guard candidate.normalized != normalizedPhrase else {
                continue
            }
            guard abs(candidate.collapsed.count - collapsedPhrase.count) <= 2 else {
                continue
            }

            let editDistance = self.editDistance(candidate.collapsed, collapsedPhrase)
            let maxLength = max(candidate.collapsed.count, collapsedPhrase.count)
            let allowedDistance = max(1, min(2, maxLength / 4))
            guard editDistance > 0, editDistance <= allowedDistance else {
                continue
            }

            let sharesInitialSignal = candidate.collapsed.first == phraseFirstCharacter || candidate.soundex == phraseSoundex
            guard sharesInitialSignal else {
                continue
            }

            var score = 1.0 - (Double(editDistance) / Double(maxLength))
            if candidate.soundex == phraseSoundex {
                score += 0.08
            }
            if candidate.collapsed.first == phraseFirstCharacter {
                score += 0.03
            }
            if candidate.collapsed.last == phraseLastCharacter {
                score += 0.03
            }

            guard score >= 0.86 else {
                continue
            }

            if let currentBest = best {
                if score > currentBest.score {
                    secondBestScore = currentBest.score
                    best = CandidateScore(replacement: candidate.replacement, score: score)
                } else if score > secondBestScore {
                    secondBestScore = score
                }
            } else {
                best = CandidateScore(replacement: candidate.replacement, score: score)
            }
        }

        guard let best else { return nil }
        guard best.score - secondBestScore >= 0.05 else { return nil }
        return best
    }

    private func selectNonOverlappingMatches(_ matches: [CandidateMatch], in text: String) -> [CandidateMatch] {
        let sortedMatches = matches.sorted { lhs, rhs in
            if lhs.wordCount != rhs.wordCount {
                return lhs.wordCount > rhs.wordCount
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return text.distance(from: text.startIndex, to: lhs.range.lowerBound)
                < text.distance(from: text.startIndex, to: rhs.range.lowerBound)
        }

        var accepted: [CandidateMatch] = []
        for candidate in sortedMatches where !accepted.contains(where: { overlaps($0.range, candidate.range) }) {
            accepted.append(candidate)
        }
        return accepted
    }

    private func overlaps(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private func soundexPhrase(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .map { soundex(String($0)) }
            .joined(separator: " ")
    }

    private func soundex(_ value: String) -> String {
        let letters = CustomVocabularyManager.normalizedCollapsedKey(value)
        guard let first = letters.first else { return "" }

        var encoded = String(first).uppercased()
        var previousDigit: Character?

        for character in letters.dropFirst() {
            let digit = soundexDigit(for: character)
            if digit == "0" {
                previousDigit = nil
                continue
            }
            if digit != previousDigit {
                encoded.append(digit)
            }
            previousDigit = digit
            if encoded.count == 4 {
                break
            }
        }

        while encoded.count < 4 {
            encoded.append("0")
        }
        return encoded
    }

    private func soundexDigit(for character: Character) -> Character {
        switch character {
        case "b", "f", "p", "v":
            return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z":
            return "2"
        case "d", "t":
            return "3"
        case "l":
            return "4"
        case "m", "n":
            return "5"
        case "r":
            return "6"
        default:
            return "0"
        }
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
