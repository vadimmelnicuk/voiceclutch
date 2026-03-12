import Foundation

extension Notification.Name {
    static let customVocabularyDidChange = Notification.Name("dev.vm.voiceclutch.customVocabularyDidChange")
}

struct ManualVocabularyEntry: Codable, Hashable, Sendable {
    let canonical: String
    let aliases: [String]
}

struct LearnedCorrectionRule: Codable, Hashable, Sendable {
    let source: String
    let target: String
    var count: Int
    var createdAt: Date
    var updatedAt: Date
}

struct CustomVocabularySnapshot: Sendable {
    let editorText: String
    let manualEntries: [ManualVocabularyEntry]
    let learnedRules: [LearnedCorrectionRule]
}

final class CustomVocabularyManager: @unchecked Sendable {
    static let shared = CustomVocabularyManager()

    private struct PersistedState: Codable {
        var manualEntries: [ManualVocabularyEntry]
        var learnedRules: [LearnedCorrectionRule]
    }

    private struct RewriteRule {
        let source: String
        let replacement: String
    }

    private static let fileName = "custom-vocabulary.json"

    private let lock = NSLock()
    private let logger = AppLogger(category: "CustomVocabularyManager")
    private var state: PersistedState

    private init() {
        self.state = Self.loadState()
    }

    func snapshot() -> CustomVocabularySnapshot {
        lock.lock()
        defer { lock.unlock() }

        return CustomVocabularySnapshot(
            editorText: Self.editorText(from: state.manualEntries),
            manualEntries: state.manualEntries,
            learnedRules: state.learnedRules.sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.count > rhs.count
            }
        )
    }

    @discardableResult
    func saveEditorText(_ text: String) throws -> CustomVocabularySnapshot {
        let parsedEntries = Self.parseEditorText(text)
        let snapshot = try mutateState { state in
            state.manualEntries = parsedEntries
        }
        logger.info("Saved \(parsedEntries.count) manual vocabulary entries")
        return snapshot
    }

    @discardableResult
    func clearLearnedRules() throws -> CustomVocabularySnapshot {
        let snapshot = try mutateState { state in
            state.learnedRules.removeAll()
        }
        logger.info("Cleared learned correction rules")
        return snapshot
    }

    @discardableResult
    func recordLearnedRule(from source: String, to target: String) throws -> CustomVocabularySnapshot {
        let normalizedSource = Self.normalizedLookupKey(source)
        let normalizedTarget = Self.normalizedLookupKey(target)
        guard
            !normalizedSource.isEmpty,
            !normalizedTarget.isEmpty,
            normalizedSource != normalizedTarget,
            Self.containsSubstantiveContent(normalizedSource),
            Self.containsSubstantiveContent(normalizedTarget)
        else {
            return snapshot()
        }

        let snapshot = try mutateState { state in
            let now = Date()
            if let index = state.learnedRules.firstIndex(where: {
                Self.normalizedLookupKey($0.source) == normalizedSource
                    && Self.normalizedLookupKey($0.target) == normalizedTarget
            }) {
                state.learnedRules[index].count += 1
                state.learnedRules[index].updatedAt = now
            } else {
                state.learnedRules.append(
                    LearnedCorrectionRule(
                        source: source,
                        target: target,
                        count: 1,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }
        logger.info("Learned correction '\(source)' -> '\(target)'")
        return snapshot
    }

    func applyRewriteRules(to text: String) -> String {
        let baseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else { return text }

        let snapshot = snapshot()
        let rewriteRules = Self.makeRewriteRules(from: snapshot)
        guard !rewriteRules.isEmpty else { return text }

        var rewritten = baseText
        for rule in rewriteRules {
            rewritten = Self.replacingOccurrences(of: rule.source, with: rule.replacement, in: rewritten)
        }
        return rewritten
    }

    func boostCandidates() -> [String] {
        let snapshot = snapshot()
        var values: [String] = snapshot.manualEntries.map(\.canonical)
        values.append(contentsOf: snapshot.learnedRules.map(\.target))

        var deduped: [String] = []
        var seen = Set<String>()
        for value in values {
            let normalized = Self.normalizedLookupKey(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            deduped.append(value)
        }
        return deduped
    }

    private func mutateState(
        _ mutation: (inout PersistedState) throws -> Void
    ) throws -> CustomVocabularySnapshot {
        lock.lock()
        defer { lock.unlock() }

        var nextState = state
        try mutation(&nextState)
        try Self.persist(nextState)
        state = nextState
        NotificationCenter.default.post(name: .customVocabularyDidChange, object: nil)
        return CustomVocabularySnapshot(
            editorText: Self.editorText(from: nextState.manualEntries),
            manualEntries: nextState.manualEntries,
            learnedRules: nextState.learnedRules.sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.count > rhs.count
            }
        )
    }

    private static func loadState() -> PersistedState {
        let fileURL = storageURL()
        guard let data = try? Data(contentsOf: fileURL) else {
            return PersistedState(manualEntries: [], learnedRules: [])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PersistedState.self, from: data) else {
            return PersistedState(manualEntries: [], learnedRules: [])
        }

        return decoded
    }

    private static func persist(_ state: PersistedState) throws {
        let fileURL = storageURL()
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func storageURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return applicationSupportDirectory
            .appendingPathComponent("voiceclutch", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func parseEditorText(_ text: String) -> [ManualVocabularyEntry] {
        var mergedEntries: [String: Set<String>] = [:]
        var canonicalForms: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { continue }

            let components = trimmedLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let rawCanonical = String(components[0])
            let canonical = sanitizedTerm(rawCanonical)
            guard !canonical.isEmpty else { continue }

            let normalizedCanonical = normalizedLookupKey(canonical)
            guard !normalizedCanonical.isEmpty else { continue }

            canonicalForms[normalizedCanonical] = canonical
            var aliases = mergedEntries[normalizedCanonical] ?? Set<String>()

            if components.count == 2 {
                let aliasString = String(components[1])
                for rawAlias in aliasString.split(separator: ",") {
                    let alias = sanitizedTerm(String(rawAlias))
                    let normalizedAlias = normalizedLookupKey(alias)
                    guard !alias.isEmpty, !normalizedAlias.isEmpty, normalizedAlias != normalizedCanonical else {
                        continue
                    }
                    aliases.insert(alias)
                }
            }

            mergedEntries[normalizedCanonical] = aliases
        }

        return mergedEntries.keys.sorted().compactMap { normalizedCanonical in
            guard let canonical = canonicalForms[normalizedCanonical] else { return nil }
            let aliases = Array(mergedEntries[normalizedCanonical] ?? []).sorted()
            return ManualVocabularyEntry(canonical: canonical, aliases: aliases)
        }
    }

    private static func editorText(from entries: [ManualVocabularyEntry]) -> String {
        entries.map { entry in
            guard !entry.aliases.isEmpty else {
                return entry.canonical
            }
            return "\(entry.canonical): \(entry.aliases.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    private static func makeRewriteRules(from snapshot: CustomVocabularySnapshot) -> [RewriteRule] {
        var rules: [RewriteRule] = []
        for entry in snapshot.manualEntries {
            for alias in entry.aliases {
                let normalizedAlias = normalizedLookupKey(alias)
                let normalizedCanonical = normalizedLookupKey(entry.canonical)
                guard !normalizedAlias.isEmpty, normalizedAlias != normalizedCanonical else { continue }
                rules.append(RewriteRule(source: alias, replacement: entry.canonical))
            }
        }

        for learnedRule in snapshot.learnedRules where learnedRule.count >= 1 {
            let normalizedSource = normalizedLookupKey(learnedRule.source)
            let normalizedTarget = normalizedLookupKey(learnedRule.target)
            guard !normalizedSource.isEmpty, normalizedSource != normalizedTarget else { continue }
            rules.append(RewriteRule(source: learnedRule.source, replacement: learnedRule.target))
        }

        return rules.sorted { lhs, rhs in
            let lhsWords = lhs.source.split(whereSeparator: \.isWhitespace).count
            let rhsWords = rhs.source.split(whereSeparator: \.isWhitespace).count
            if lhsWords == rhsWords {
                return lhs.source.count > rhs.source.count
            }
            return lhsWords > rhsWords
        }
    }

    private static func replacingOccurrences(of source: String, with replacement: String, in text: String) -> String {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty else { return text }

        let tokens = normalizedSource.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty else { return text }

        let pattern = "(?<![\\\\p{L}\\\\p{N}])" + tokens.joined(separator: "\\\\s+") + "(?![\\\\p{L}\\\\p{N}])"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    static func sanitizedTerm(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    static func normalizedLookupKey(_ text: String) -> String {
        sanitizedTerm(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func containsSubstantiveContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
