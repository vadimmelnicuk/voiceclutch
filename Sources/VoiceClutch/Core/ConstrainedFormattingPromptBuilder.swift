import Foundation

struct ConstrainedFormattingPromptBuilder {
    func buildPrompt(
        for request: LocalLLMRequest,
        extendedContext: ExtendedFormattingContext
    ) -> String {
        let inputJSON = #"{"transcript":\#(jsonStringLiteral(request.deterministicTranscript))}"#

        return """
        \(systemContract(codeMode: extendedContext.requiresCodeSyntaxPostEdit))

        Input JSON:
        \(inputJSON)
        """
    }

    private func systemContract(codeMode: Bool) -> String {
        if codeMode {
            return """
            Minimize edits to dictated code and preserve meaning.
            Fix only obvious punctuation, spacing, brackets, quotes, operators, and spoken symbols.
            Keep identifiers, strings, literals, URLs, paths, and flags unless clearly wrong.
            If uncertain, keep the original text.
            Output exactly one JSON object: {"final_text":"..."}. No markdown, no extra keys, no extra text.
            """
        } else {
            return """
            Preserve the dictated transcript's wording and meaning.
            Do not paraphrase, summarize, add/remove facts, or change speaker perspective, tense, or claims.
            Fix only punctuation, capitalization, spacing, paragraph breaks, and spoken punctuation words.
            Allow local wording fixes for obvious high-confidence ASR mistakes (for example clear homophone/tokenization/malformed-word errors).
            You may remove accidental immediate duplicate filler words.
            Keep sentence order and structure; avoid clause rewrites.
            Keep names, code, URLs, paths, and technical terms unless clearly wrong.
            Do not copy instruction text into final_text.
            If uncertain, keep the original text.
            Output exactly one JSON object: {"final_text":"..."}. No markdown, no extra keys, no extra text.
            """
        }
    }

    private func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

struct StructuredResponseParser {
    private static let finalTextRegex = try? NSRegularExpression(
        pattern: #""(?:final_text|finalText)"\s*:\s*"((?:\\.|[^"\\])*)""#,
        options: [.caseInsensitive]
    )

    func parse(_ raw: String) -> StructuredFormattingResponse? {
        let text = sanitize(raw)
        guard !text.isEmpty else { return nil }

        if let structured = decodeStructuredJson(from: text) {
            return structured
        }

        if let json = extractJsonObject(from: text),
           let structured = decodeStructuredJson(from: json) {
            return structured
        }

        if let extracted = extractFinalText(from: text) {
            return StructuredFormattingResponse(finalText: extracted, edits: [])
        }

        return nil
    }

    private func decodeStructuredJson(from text: String) -> StructuredFormattingResponse? {
        guard let data = text.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(StructuredFormattingResponse.self, from: data)
    }

    private func sanitize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("```json") {
            value = String(value.dropFirst(7))
        } else if value.hasPrefix("```") {
            value = String(value.dropFirst(3))
        }

        if value.hasSuffix("```") {
            value = String(value.dropLast(3))
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJsonObject(from text: String) -> String? {
        guard let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}") else {
            return nil
        }

        let candidate = String(text[first...last])
        guard candidate.contains("\"final_text\"") || candidate.contains("\"finalText\"") else {
            return nil
        }

        return candidate
    }

    private func extractFinalText(from text: String) -> String? {
        guard let regex = Self.finalTextRegex else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let escaped = String(text[captured])
        return decodeJSONStringLiteral(escaped)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeJSONStringLiteral(_ escaped: String) -> String? {
        let wrapped = "\"\(escaped)\""
        guard let data = wrapped.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
}

struct StructuredResponseValidator {
    private let validationEngine = TranscriptValidationEngine()

    func validate(
        response: StructuredFormattingResponse,
        original: String,
        vocabulary: CustomVocabularySnapshot,
        requiresCodeSyntaxPostEdit: Bool = false,
        protectedSpans: [ProtectedSpan] = []
    ) -> LocalLLMValidationDecision {
        let candidate = response.finalText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return validationEngine.validate(
            candidate: candidate.isEmpty ? original : candidate,
            reference: original,
            vocabulary: vocabulary,
            requiresCodeSyntaxPostEdit: requiresCodeSyntaxPostEdit,
            protectedSpans: protectedSpans
        )
    }
}
