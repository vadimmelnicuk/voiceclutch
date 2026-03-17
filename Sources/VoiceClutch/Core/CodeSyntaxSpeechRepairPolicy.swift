import Foundation

enum CodeSyntaxSpeechRepairPolicy {
    private struct RegexReplacement {
        let regex: NSRegularExpression
        let replacement: String
    }

    static let verbalToSymbolReplacements: [String: String] = [
        "brain open brace": "{",
        "open brace": "{",
        "open curly": "{",
        "close brace": "}",
        "close curly": "}",
        "open bracket": "[",
        "close bracket": "]",
        "open parentheses": "(",
        "close parentheses": ")",
        "open parenthesis": "(",
        "close parenthesis": ")",
        "open paren": "(",
        "close paren": ")",
        "open parens": "(",
        "close parens": ")",
        "closed paren": ")",
        "closed parenthesis": ")",
        "closed parentheses": ")",
        "double quote": "\"",
        "single quote": "'",
        "single quotation mark": "'",
        "back tick": "`",
        "backslash": "\\",
        "forward slash": "/",
        "colon": ":",
        "semicolon": ";",
        "comma": ",",
        "period": ".",
        "question mark": "?",
        "exclamation mark": "!",
        "equals": "=",
        "is equal": "=",
        "plus": "+",
        "minus": "-",
        "times": "*",
        "asterisk": "*",
        "divide": "/",
        "greater than": ">",
        "less than": "<"
    ]

    static func normalizedCodeSpeech(_ text: String, requiresCodeSyntaxPostEdit: Bool) -> String {
        guard requiresCodeSyntaxPostEdit else { return text }

        var result = text
        for entry in verbalToSymbolRegexReplacements {
            let range = NSRange(result.startIndex..., in: result)
            result = entry.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: entry.replacement
            )
        }

        result = scrubCodePausePunctuation(result)
        result = cleanupCodeSymbolWhitespace(result)
        return stripTrailingSentenceStopIfLikelyCode(result)
    }

    static func verbalToSymbolPromptLines() -> [String] {
        let phrasePairs = sortedReplacementPhrases
            .map { phrase in
                let replacement = verbalToSymbolReplacements[phrase] ?? ""
                let symbolForPrompt = replacement.replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(phrase)\" -> \"\(symbolForPrompt)\""
            }

        let maxPairsPerLine = 4
        return stride(from: 0, to: phrasePairs.count, by: maxPairsPerLine).map { start in
            let end = min(start + maxPairsPerLine, phrasePairs.count)
            let chunk = phrasePairs[start..<end]
            let joined = chunk.joined(separator: ", ")
            return "- \(joined)"
        }
    }

    private static var sortedReplacementPhrases: [String] {
        verbalToSymbolReplacements.keys
            .sorted {
                let lhsWordCount = $0.split(whereSeparator: \.isWhitespace).count
                let rhsWordCount = $1.split(whereSeparator: \.isWhitespace).count

                if lhsWordCount == rhsWordCount {
                    return $0 < $1
                }
                return lhsWordCount > rhsWordCount
            }
    }

    private static func cleanupCodeSymbolWhitespace(_ text: String) -> String {
        var result = text
        for entry in cleanupRegexReplacements {
            let range = NSRange(result.startIndex..., in: result)
            result = entry.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: entry.replacement
            )
        }

        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scrubCodePausePunctuation(_ text: String) -> String {
        var result = text
        for replacement in pauseScrubRegexReplacements {
            let range = NSRange(result.startIndex..., in: result)
            result = replacement.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: replacement.replacement
            )
        }

        return result
    }

    private static func stripTrailingSentenceStopIfLikelyCode(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = result.last, ".!?".contains(last) else {
            return result
        }
        guard isLikelyCodeFragment(result) else {
            return result
        }

        while let tail = result.last, ".!?".contains(tail) {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyCodeFragment(_ text: String) -> Bool {
        let codeSymbolSet = CharacterSet(charactersIn: "{}()[]<>+=-*/_%")
        let hasCodeSymbols = text.unicodeScalars.contains { codeSymbolSet.contains($0) }
        if hasCodeSymbols {
            return true
        }

        let lowered = text.lowercased()
        let codeKeywords = [
            "if", "for", "while", "switch", "case", "else", "guard", "return",
            "func", "let", "var", "class", "struct", "enum", "print", "import", "where", "in"
        ]

        return codeKeywords.contains { keyword in
            lowered.range(of: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b", options: .regularExpression) != nil
        }
    }

    private static let verbalToSymbolRegexReplacements: [RegexReplacement] = {
        sortedReplacementPhrases.compactMap { phrase in
            guard let replacement = verbalToSymbolReplacements[phrase] else {
                return nil
            }
            let pattern = #"(?i)(?<![\w])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?!(?:\w))"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            return RegexReplacement(regex: regex, replacement: " \(replacement) ")
        }
    }()

    private static let cleanupRegexReplacements: [RegexReplacement] = [
        (#"\s+([,.;:!?]|\)|\]|\})"#, "$1"),
        (#"(\(|\{|\[)\s+"#, "$1")
    ].compactMap { pattern, replacement in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        return RegexReplacement(regex: regex, replacement: replacement)
    }

    private static let pauseScrubRegexReplacements: [RegexReplacement] = {
        let pauseKeywordPattern =
            "(if|for|while|switch|case|else|guard|return|print|let|var|func|class|struct|enum|try|catch|do|where|in)\\b"
        let patterns: [(String, String, NSRegularExpression.Options)] = [
            (#",\s*(\)|\]|\})"#, "$1", []),
            (#"(\(|\{|\[)\s*,\s*"#, "$1", []),
            (#"(\)|\]|\})\s*,\s*(?=\#(pauseKeywordPattern))"#, "$1 ", [.caseInsensitive]),
        ]

        return patterns.compactMap { pattern, replacement, options in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return nil
            }
            return RegexReplacement(regex: regex, replacement: replacement)
        }
    }()
}
