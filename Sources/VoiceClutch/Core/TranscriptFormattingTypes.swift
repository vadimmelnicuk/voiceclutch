import Foundation

// MARK: - Structured LLM Response Types

/// Edit types that the LLM is allowed to make
enum TranscriptEditType: String, Codable, Sendable {
    case punctuation = "punctuation"
    case capitalization = "capitalization"
    case spacing = "spacing"
    case paragraph = "paragraph"
    case obviousAsrFix = "obvious_asr_fix"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = TranscriptEditType(rawValue: rawValue) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A single tracked edit from the LLM
struct TranscriptEdit: Codable, Sendable, Equatable {
    let from: String
    let to: String
    let reason: TranscriptEditType

    init(from: String, to: String, reason: TranscriptEditType) {
        self.from = from
        self.to = to
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case from
        case to
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        reason = try container.decodeIfPresent(TranscriptEditType.self, forKey: .reason) ?? .unknown
    }

    var isPunctuationOnly: Bool {
        guard from.count == to.count else { return false }
        let fromLetters = from.filter { $0.isLetter || $0.isNumber }
        let toLetters = to.filter { $0.isLetter || $0.isNumber }
        return fromLetters == toLetters
    }
}

/// Structured response from the formatting LLM
struct StructuredFormattingResponse: Codable, Sendable {
    let finalText: String
    let edits: [TranscriptEdit]

    private enum CodingKeys: String, CodingKey {
        case finalText
        case edits
    }

    init(finalText: String, edits: [TranscriptEdit] = []) {
        self.finalText = finalText
        self.edits = edits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        finalText = try container.decode(String.self, forKey: .finalText)
        edits = try container.decodeIfPresent([TranscriptEdit].self, forKey: .edits) ?? []
    }

    /// True if all edits are punctuation/capitalization/spacing only (no wording changes)
    var isFormattingOnly: Bool {
        edits.allSatisfy { $0.reason == .punctuation || $0.reason == .capitalization || $0.reason == .spacing }
    }
}

// MARK: - Protected Spans

/// Spans of text that must never be modified by the LLM
struct ProtectedSpan: Sendable, Equatable {
    let range: Range<String.Index>
    let type: ProtectedSpanType
    let text: String

    func contains(_ index: String.Index, in text: String) -> Bool {
        range.contains(index)
    }

    func overlaps(_ other: Range<String.Index>) -> Bool {
        !(other.upperBound <= range.lowerBound || other.lowerBound >= range.upperBound)
    }
}

enum ProtectedSpanType: String, Sendable {
    case codeFence = "code_fence"
    case url = "url"
    case email = "email"
    case filePath = "file_path"
    case command = "command"
    case stackTrace = "stack_trace"
}

/// Detects spans that must be protected from LLM modification
struct ProtectedSpanDetector {
    private let codeFencePattern = #"```[\s\S]*?```"#
    private let inlineCodePattern = #"`[^`\n]+`"#
    private let urlPattern = #"https?://[^\s<>"]+|www\.[^\s<>"]+"#
    private let emailPattern = #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#
    private let filePathPattern = #"[/~]?[\w\-./]+/[\w\-./]*[\w\-]+"#
    private let commandPattern = #"(?:^|\s)[\w\-]+(?:[\s\-][\w\-]+)*"#

    func detectProtectedSpans(in text: String) -> [ProtectedSpan] {
        var spans: [ProtectedSpan] = []

        // Code fences (highest priority)
        spans.append(contentsOf: findMatches(in: text, pattern: codeFencePattern, type: .codeFence))

        // Inline code
        spans.append(contentsOf: findMatches(in: text, pattern: inlineCodePattern, type: .codeFence))

        // URLs
        spans.append(contentsOf: findMatches(in: text, pattern: urlPattern, type: .url))

        // Emails
        spans.append(contentsOf: findMatches(in: text, pattern: emailPattern, type: .email))

        // File paths ( Unix and macOS style)
        spans.append(contentsOf: findMatches(in: text, pattern: filePathPattern, type: .filePath))

        return mergeOverlappingSpans(spans, in: text)
    }

    private func findMatches(in text: String, pattern: String, type: ProtectedSpanType) -> [ProtectedSpan] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        var matches: [ProtectedSpan] = []

        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let matchRange = match?.range,
                  let range = Range(matchRange, in: text) else {
                return
            }
            matches.append(ProtectedSpan(range: range, type: type, text: String(text[range])))
        }

        return matches
    }

    private func mergeOverlappingSpans(_ spans: [ProtectedSpan], in text: String) -> [ProtectedSpan] {
        guard !spans.isEmpty else { return [] }

        let sorted = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [ProtectedSpan] = []
        var current = sorted[0]

        for span in sorted.dropFirst() {
            if current.overlaps(span.range) {
                // Merge spans
                let mergedRange = current.range.lowerBound..<max(current.range.upperBound, span.range.upperBound)
                current = ProtectedSpan(
                    range: mergedRange,
                    type: current.type,
                    text: String(text[mergedRange])
                )
            } else {
                merged.append(current)
                current = span
            }
        }

        merged.append(current)
        return merged
    }
}

// MARK: - Diff Application

/// Applies edits as diffs rather than full replacement
struct TranscriptDiffApplier {
    /// Applies a list of edits to the original text
    func applyEdits(_ edits: [TranscriptEdit], to original: String) -> String {
        var result = original

        // Apply edits in reverse order (by end position) to avoid index shifting issues
        let sortedEdits = edits.sorted { lhs, rhs in
            let lhsEnd = original.range(of: lhs.from)?.upperBound ?? original.endIndex
            let rhsEnd = original.range(of: rhs.from)?.upperBound ?? original.endIndex
            return lhsEnd > rhsEnd
        }

        for edit in sortedEdits {
            guard let range = result.range(of: edit.from, options: .literal) else {
                continue
            }
            result.replaceSubrange(range, with: edit.to)
        }

        return result
    }

    /// Extracts just the edits that would actually change the text
    func extractEffectiveEdits(from structured: StructuredFormattingResponse, original: String) -> [TranscriptEdit] {
        structured.edits.filter { edit in
            original.range(of: edit.from, options: .literal) != nil && edit.from != edit.to
        }
    }
}

// MARK: - Style Preferences

enum EmDashStyle: String, Sendable {
    case emDash = "em_dash"
    case comma = "comma"
    case none = "none"
}

enum OxfordCommaStyle: String, Sendable {
    case always = "always"
    case never = "never"
    case asNeeded = "as_needed"
}

enum SentenceCaseStyle: String, Sendable {
    case sentenceCase = "sentence_case"
    case titleCase = "title_case"
    case asSpoken = "as_spoken"
}

enum ListFormattingHint: String, Sendable {
    case none
    case bulleted
    case numbered
}

enum ListFormattingIntentDetector {
    private static let optionNumberRegex = makeRegex(
        pattern: #"\boption\s+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b"#
    )
    private static let ordinalRegex = makeRegex(
        pattern: #"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b"#
    )
    private static let spokenNumberingRegex = makeRegex(
        pattern: #"(?:(?:^|[\s,;:])\d+[\).\:-])"#
    )
    private static let bulletCueRegex = makeRegex(
        pattern: #"\b(bullet point|bullet points|bullet list)\b"#
    )
    private static let delimiterRegex = makeRegex(
        pattern: #"[,;]|\b(and|or)\b"#
    )

    static func hint(
        for transcript: String,
        formattingContext: TranscriptFormattingContext
    ) -> ListFormattingHint {
        guard shouldDetectListIntent(in: formattingContext) else {
            return .none
        }

        let normalized = normalizedForComparison(transcript)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .none
        }

        let numberingSignals = countMatches(optionNumberRegex, in: normalized)
            + countMatches(ordinalRegex, in: normalized)
            + countMatches(spokenNumberingRegex, in: normalized)
        if numberingSignals >= 2 {
            return .numbered
        }

        let hasBulletCue = hasMatch(bulletCueRegex, in: normalized)
        let estimatedItemCount = countMatches(delimiterRegex, in: normalized) + 1
        if hasBulletCue && estimatedItemCount >= 2 {
            return .bulleted
        }

        return .none
    }

    private static func shouldDetectListIntent(in context: TranscriptFormattingContext) -> Bool {
        guard !context.requiresCodeSyntaxPostEdit else {
            return false
        }

        switch context.domain {
        case .code, .terminal:
            return false
        case .general, .messaging, .documents, .email:
            return true
        }
    }

    private static func countMatches(_ regex: NSRegularExpression?, in text: String) -> Int {
        guard let regex else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private static func hasMatch(_ regex: NSRegularExpression?, in text: String) -> Bool {
        countMatches(regex, in: text) > 0
    }

    private static func makeRegex(pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

struct FormattingStylePreferences: Sendable {
    let emDashStyle: EmDashStyle
    let oxfordComma: OxfordCommaStyle
    let sentenceCase: SentenceCaseStyle
    let doubleSpacingAfterSentence: Bool

    static let `default` = FormattingStylePreferences(
        emDashStyle: .emDash,
        oxfordComma: .asNeeded,
        sentenceCase: .sentenceCase,
        doubleSpacingAfterSentence: false
    )

    static func load(from userDefaults: UserDefaults = .standard) -> FormattingStylePreferences {
        let emDashRaw = userDefaults.string(forKey: "emDashStyle") ?? EmDashStyle.emDash.rawValue
        let oxfordCommaRaw = userDefaults.string(forKey: "oxfordCommaStyle") ?? OxfordCommaStyle.asNeeded.rawValue
        let sentenceCaseRaw = userDefaults.string(forKey: "sentenceCaseStyle") ?? SentenceCaseStyle.sentenceCase.rawValue
        let doubleSpace = userDefaults.bool(forKey: "doubleSpacingAfterSentence")

        return FormattingStylePreferences(
            emDashStyle: EmDashStyle(rawValue: emDashRaw) ?? .emDash,
            oxfordComma: OxfordCommaStyle(rawValue: oxfordCommaRaw) ?? .asNeeded,
            sentenceCase: SentenceCaseStyle(rawValue: sentenceCaseRaw) ?? .sentenceCase,
            doubleSpacingAfterSentence: doubleSpace
        )
    }

    func save(to userDefaults: UserDefaults = .standard) {
        userDefaults.set(emDashStyle.rawValue, forKey: "emDashStyle")
        userDefaults.set(oxfordComma.rawValue, forKey: "oxfordCommaStyle")
        userDefaults.set(sentenceCase.rawValue, forKey: "sentenceCaseStyle")
        userDefaults.set(doubleSpacingAfterSentence, forKey: "doubleSpacingAfterSentence")
    }

    func promptInstructions() -> [String] {
        var instructions: [String] = []

        switch emDashStyle {
        case .emDash:
            instructions.append("Use em dashes (—) for abrupt breaks and parenthetical phrases.")
        case .comma:
            instructions.append("Use commas instead of em dashes for breaks and parenthetical phrases.")
        case .none:
            break
        }

        switch oxfordComma {
        case .always:
            instructions.append("Always use the Oxford comma (serial comma) in lists of three or more.")
        case .never:
            instructions.append("Never use the Oxford comma; omit the final comma in lists.")
        case .asNeeded:
            break
        }

        switch sentenceCase {
        case .sentenceCase:
            instructions.append("Use sentence case: only capitalize the first word and proper nouns.")
        case .titleCase:
            instructions.append("Use title case: capitalize the first letter of each word.")
        case .asSpoken:
            break
        }

        if doubleSpacingAfterSentence {
            instructions.append("Use two spaces after sentence-ending punctuation.")
        }

        return instructions
    }
}

// MARK: - Extended Request Context

/// Recent correction pair learned from user edits
struct LearnedCorrection: Codable, Sendable, Equatable {
    let source: String
    let target: String
    let frequency: Int
    let lastUsedAt: Date

    var displayText: String {
        "\(source) → \(target)"
    }
}

/// Extended context for LLM formatting request
struct ExtendedFormattingContext: Sendable {
    let formattingContext: TranscriptFormattingContext
    let previousSentences: [String]
    let recentCorrections: [LearnedCorrection]
    let stylePreferences: FormattingStylePreferences
    let protectedSpans: [ProtectedSpan]
    let clipboardPreview: String?

    var domain: TranscriptFormattingDomain {
        formattingContext.domain
    }

    var appName: String? {
        formattingContext.appName
    }

    var bundleIdentifier: String? {
        formattingContext.bundleIdentifier
    }

    var requiresCodeSyntaxPostEdit: Bool {
        formattingContext.requiresCodeSyntaxPostEdit
    }

    static let empty = ExtendedFormattingContext(
        formattingContext: TranscriptFormattingContext(),
        previousSentences: [],
        recentCorrections: [],
        stylePreferences: .default,
        protectedSpans: [],
        clipboardPreview: nil
    )
}

// MARK: - Correction History Store

/// Stores and retrieves learned corrections for context injection
actor CorrectionHistoryStore {
    private var corrections: [LearnedCorrection] = []
    private let maxCorrections = 50
    private let maxContextCorrections = 8

    func recordCorrection(source: String, target: String) {
        let normalizedSource = CustomVocabularyManager.normalizedLookupKey(source)
        let normalizedTarget = CustomVocabularyManager.normalizedLookupKey(target)

        guard normalizedSource != normalizedTarget else { return }

        // Update existing or add new
        if let index = corrections.firstIndex(where: {
            CustomVocabularyManager.normalizedLookupKey($0.source) == normalizedSource
        }) {
            corrections[index] = LearnedCorrection(
                source: source,
                target: target,
                frequency: corrections[index].frequency + 1,
                lastUsedAt: Date()
            )
        } else {
            corrections.append(LearnedCorrection(
                source: source,
                target: target,
                frequency: 1,
                lastUsedAt: Date()
            ))
        }

        // Keep only recent corrections
        corrections.sort { $0.lastUsedAt > $1.lastUsedAt }
        corrections = Array(corrections.prefix(maxCorrections))
    }

    func relevantCorrections(for text: String) -> [LearnedCorrection] {
        let textWords = Set(normalizedWordTokens(from: text).prefix(20))

        return corrections
            .filter { correction in
                let sourceWords = normalizedWordTokens(from: correction.source)
                return !sourceWords.isEmpty &&
                       sourceWords.contains(where: { textWords.contains($0) })
            }
            .sorted { lhs, rhs in
                if lhs.frequency != rhs.frequency {
                    return lhs.frequency > rhs.frequency
                }
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            .prefix(maxContextCorrections)
            .map { $0 }
    }

    func allCorrections() -> [LearnedCorrection] {
        corrections
    }

    func clear() {
        corrections.removeAll()
    }
}

// MARK: - Sentence History Buffer

/// Tracks recent finalized sentences for context
actor SentenceHistoryBuffer {
    private var sentences: [String] = []
    private let maxSentences = 3
    private let minSentenceLength = 8

    func addSentence(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minSentenceLength else { return }

        sentences.append(trimmed)
        if sentences.count > maxSentences {
            sentences.removeFirst()
        }
    }

    func recentSentences(count: Int = 3) -> [String] {
        let limit = min(count, sentences.count)
        return Array(sentences.suffix(limit))
    }

    func clear() {
        sentences.removeAll()
    }
}
