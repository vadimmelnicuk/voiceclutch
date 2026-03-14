import Foundation

extension Notification.Name {
    static let customVocabularyDidChange = Notification.Name("dev.vm.voiceclutch.customVocabularyDidChange")
}

struct ManualVocabularyEntry: Codable, Hashable, Sendable {
    let canonical: String
    let aliases: [String]
}

struct ShortcutVocabularyEntry: Codable, Hashable, Sendable {
    let id: UUID
    let trigger: String
    let replacement: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        trigger: String,
        replacement: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct LearnedCorrectionRule: Codable, Hashable, Sendable {
    static let promotionThreshold = 1

    let id: UUID
    let source: String
    let target: String
    var count: Int
    let createdAt: Date
    var updatedAt: Date

    var isPromoted: Bool {
        count >= Self.promotionThreshold
    }

    init(
        id: UUID = UUID(),
        source: String,
        target: String,
        count: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.count = count
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct CustomVocabularySnapshot: Sendable {
    let editorText: String
    let manualEntries: [ManualVocabularyEntry]
    let shortcutEntries: [ShortcutVocabularyEntry]
    let learnedRules: [LearnedCorrectionRule]

    init(
        editorText: String = "",
        manualEntries: [ManualVocabularyEntry] = [],
        shortcutEntries: [ShortcutVocabularyEntry] = [],
        learnedRules: [LearnedCorrectionRule] = []
    ) {
        self.editorText = editorText
        self.manualEntries = manualEntries
        self.shortcutEntries = shortcutEntries
        self.learnedRules = learnedRules
    }
}

struct VocabularyRewriteRule: Hashable, Sendable {
    let source: String
    let replacement: String
}

struct VocabularyFuzzyCandidate: Hashable, Sendable {
    let source: String
    let replacement: String
}

struct VocabularyGlossaryEntry: Hashable, Sendable {
    let preferred: String
    let hints: [String]
}

enum CustomVocabularyError: LocalizedError {
    case invalidManualEntry
    case invalidOriginalText
    case invalidReplacementText
    case invalidShortcutEntry

    var errorDescription: String? {
        switch self {
        case .invalidManualEntry:
            return "Enter one vocabulary item using `canonical` or `canonical: alias1, alias2`."
        case .invalidOriginalText:
            return "Enter one or more original words/phrases (comma-separated)."
        case .invalidReplacementText:
            return "Enter a replacement word/phrase."
        case .invalidShortcutEntry:
            return "Enter one shortcut using `trigger => replacement`."
        }
    }
}

final class CustomVocabularyManager: @unchecked Sendable {
    static let shared = CustomVocabularyManager()

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var manualEntries: [ManualVocabularyEntry]
        var shortcutEntries: [ShortcutVocabularyEntry]
        var learnedRules: [LearnedCorrectionRule]
        let createdAt: Date
        var updatedAt: Date

        static func empty(now: Date = Date()) -> PersistedState {
            PersistedState(
                schemaVersion: Self.currentSchemaVersion,
                manualEntries: [],
                shortcutEntries: [],
                learnedRules: [],
                createdAt: now,
                updatedAt: now
            )
        }

        static let currentSchemaVersion = 2
    }

    private enum RewritePriority: Int {
        case manual = 0
        case shortcut = 1
        case learned = 2
    }

    private struct PrioritizedRewriteRule {
        let source: String
        let replacement: String
        let priority: RewritePriority
    }

    private static let legacyFileName = "custom-vocabulary.json"
    private static let fileName = "custom-vocabulary-v2.json"

    private let lock = NSLock()
    private let logger = AppLogger(category: "CustomVocabularyManager")
    private let storageURL: URL
    private let legacyStorageURL: URL
    private var state: PersistedState

    init(
        storageURL: URL = CustomVocabularyManager.defaultStorageURL(),
        legacyStorageURL: URL = CustomVocabularyManager.defaultLegacyStorageURL()
    ) {
        self.storageURL = storageURL
        self.legacyStorageURL = legacyStorageURL
        self.state = PersistedState.empty()
        deleteLegacyStoreIfNeeded()
        self.state = loadState()
    }

    func snapshot() -> CustomVocabularySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return Self.snapshot(from: state)
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
    func addManualEntry(from line: String) throws -> CustomVocabularySnapshot {
        let parsedEntries = Self.parseEditorText(line)
        guard parsedEntries.count == 1 else {
            throw CustomVocabularyError.invalidManualEntry
        }

        let snapshot = try mutateState { state in
            state.manualEntries = Self.mergedManualEntries(
                existing: state.manualEntries,
                additions: parsedEntries
            )
        }
        logger.info("Added manual vocabulary entry '\(parsedEntries[0].canonical)'")
        return snapshot
    }

    @discardableResult
    func addShortcutEntry(from line: String) throws -> CustomVocabularySnapshot {
        let parsedEntry = try Self.parseShortcutLine(line)
        return try upsertShortcutEntries(triggers: [parsedEntry.trigger], replacement: parsedEntry.replacement)
    }

    @discardableResult
    func addManualRule(originalText: String, replacementText: String) throws -> CustomVocabularySnapshot {
        let replacement = Self.sanitizedTerm(replacementText)
        guard !replacement.isEmpty else {
            throw CustomVocabularyError.invalidReplacementText
        }

        let triggers = Self.parseCommaSeparatedTerms(originalText)
        guard !triggers.isEmpty else {
            throw CustomVocabularyError.invalidOriginalText
        }

        return try upsertShortcutEntries(triggers: triggers, replacement: replacement)
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
    func removeLearnedRule(id: UUID) throws -> CustomVocabularySnapshot {
        let snapshot = try mutateState { state in
            state.learnedRules.removeAll { $0.id == id }
        }
        logger.info("Removed learned correction rule id=\(id.uuidString)")
        return snapshot
    }

    @discardableResult
    func recordLearnedRule(from source: String, to target: String) throws -> CustomVocabularySnapshot {
        guard AutoAddCorrectionsPreference.load() else {
            return snapshot()
        }

        let sanitizedSource = Self.sanitizedTerm(source)
        let sanitizedTarget = Self.sanitizedTerm(target)
        guard !sanitizedSource.isEmpty, !sanitizedTarget.isEmpty else {
            return snapshot()
        }

        let normalizedSource = Self.normalizedLookupKey(sanitizedSource)
        let normalizedTarget = Self.normalizedLookupKey(sanitizedTarget)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty else {
            return snapshot()
        }

        let isCaseOnlyVariant = normalizedSource == normalizedTarget && sanitizedSource != sanitizedTarget
        if normalizedSource == normalizedTarget && !isCaseOnlyVariant {
            return snapshot()
        }

        guard Self.isAutoAddEligibleTarget(sanitizedTarget) else {
            return snapshot()
        }

        let snapshot = try mutateState { state in
            let now = Date()
            if let index = state.learnedRules.firstIndex(where: {
                Self.normalizedLookupKey($0.source) == normalizedSource
                    && Self.normalizedLookupKey($0.target) == normalizedTarget
                    && Self.sanitizedTerm($0.source) == sanitizedSource
                    && Self.sanitizedTerm($0.target) == sanitizedTarget
            }) {
                state.learnedRules[index].count += 1
                state.learnedRules[index].updatedAt = now
            } else {
                state.learnedRules.append(
                    LearnedCorrectionRule(
                        source: sanitizedSource,
                        target: sanitizedTarget,
                        count: 1,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }
        logger.info("Learned correction '\(sanitizedSource)' -> '\(sanitizedTarget)'")
        return snapshot
    }

    func applyRewriteRules(to text: String) -> String {
        Self.applyRewriteRules(to: text, snapshot: snapshot())
    }

    func rewriteRules() -> [VocabularyRewriteRule] {
        Self.rewriteRules(from: snapshot())
    }

    func fuzzyCandidates() -> [VocabularyFuzzyCandidate] {
        Self.fuzzyCandidates(from: snapshot())
    }

    func glossaryEntries(limit: Int = 24) -> [VocabularyGlossaryEntry] {
        Self.glossaryEntries(from: snapshot(), limit: limit)
    }

    static func applyRewriteRules(to text: String, snapshot: CustomVocabularySnapshot) -> String {
        let baseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else { return text }

        let rewriteRules = rewriteRules(from: snapshot)
        guard !rewriteRules.isEmpty else { return baseText }

        var rewritten = baseText
        for rule in rewriteRules {
            rewritten = replacingOccurrences(of: rule.source, with: rule.replacement, in: rewritten)
        }
        return rewritten
    }

    static func rewriteRules(from snapshot: CustomVocabularySnapshot) -> [VocabularyRewriteRule] {
        var prioritizedBySource: [String: PrioritizedRewriteRule] = [:]

        func registerRule(source: String, replacement: String, priority: RewritePriority) {
            let normalizedSource = normalizedLookupKey(source)
            let normalizedReplacement = normalizedLookupKey(replacement)
            guard !normalizedSource.isEmpty, !normalizedReplacement.isEmpty else { return }
            guard normalizedSource != normalizedReplacement || source != replacement else { return }

            if prioritizedBySource[normalizedSource] == nil {
                prioritizedBySource[normalizedSource] = PrioritizedRewriteRule(
                    source: source,
                    replacement: replacement,
                    priority: priority
                )
            }
        }

        for entry in snapshot.manualEntries {
            for alias in entry.aliases {
                registerRule(source: alias, replacement: entry.canonical, priority: .manual)
            }
        }

        for entry in snapshot.shortcutEntries {
            registerRule(source: entry.trigger, replacement: entry.replacement, priority: .shortcut)
        }

        let promotedLearnedRules = snapshot.learnedRules
            .filter(\.isPromoted)
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.count > rhs.count
            }

        for learnedRule in promotedLearnedRules {
            registerRule(source: learnedRule.source, replacement: learnedRule.target, priority: .learned)
        }

        return prioritizedBySource.values
            .sorted { lhs, rhs in
                let lhsWordCount = lhs.source.split(whereSeparator: \.isWhitespace).count
                let rhsWordCount = rhs.source.split(whereSeparator: \.isWhitespace).count
                if lhsWordCount != rhsWordCount {
                    return lhsWordCount > rhsWordCount
                }
                if lhs.source.count != rhs.source.count {
                    return lhs.source.count > rhs.source.count
                }
                return lhs.priority.rawValue < rhs.priority.rawValue
            }
            .map { VocabularyRewriteRule(source: $0.source, replacement: $0.replacement) }
    }

    static func fuzzyCandidates(from snapshot: CustomVocabularySnapshot) -> [VocabularyFuzzyCandidate] {
        var candidates: [VocabularyFuzzyCandidate] = []
        var seen = Set<String>()

        func appendCandidate(source: String, replacement: String) {
            let normalizedSource = normalizedLookupKey(source)
            let normalizedReplacement = normalizedLookupKey(replacement)
            guard
                !normalizedSource.isEmpty,
                !normalizedReplacement.isEmpty,
                containsSubstantiveContent(normalizedSource)
            else {
                return
            }

            let dedupeKey = normalizedSource + "->" + normalizedReplacement
            guard seen.insert(dedupeKey).inserted else { return }
            candidates.append(VocabularyFuzzyCandidate(source: source, replacement: replacement))
        }

        for entry in snapshot.manualEntries {
            appendCandidate(source: entry.canonical, replacement: entry.canonical)
            for alias in entry.aliases {
                appendCandidate(source: alias, replacement: entry.canonical)
            }
        }

        return candidates.sorted { lhs, rhs in
            let lhsWords = lhs.source.split(whereSeparator: \.isWhitespace).count
            let rhsWords = rhs.source.split(whereSeparator: \.isWhitespace).count
            if lhsWords == rhsWords {
                return lhs.source.count > rhs.source.count
            }
            return lhsWords > rhsWords
        }
    }

    static func glossaryEntries(from snapshot: CustomVocabularySnapshot, limit: Int = 24) -> [VocabularyGlossaryEntry] {
        var mergedHints: [String: Set<String>] = [:]
        var preferredForms: [String: String] = [:]

        func addGlossary(preferred: String, hint: String?) {
            let normalizedPreferred = normalizedLookupKey(preferred)
            guard !normalizedPreferred.isEmpty else { return }

            preferredForms[normalizedPreferred] = preferredForms[normalizedPreferred] ?? preferred
            guard let hint, !hint.isEmpty else { return }
            var hints = mergedHints[normalizedPreferred] ?? Set<String>()
            hints.insert(hint)
            mergedHints[normalizedPreferred] = hints
        }

        for entry in snapshot.manualEntries {
            addGlossary(preferred: entry.canonical, hint: nil)
            for alias in entry.aliases {
                addGlossary(preferred: entry.canonical, hint: alias)
            }
        }

        for entry in snapshot.shortcutEntries {
            addGlossary(preferred: entry.replacement, hint: entry.trigger)
        }

        for learnedRule in snapshot.learnedRules where learnedRule.isPromoted {
            addGlossary(preferred: learnedRule.target, hint: learnedRule.source)
        }

        let entries = preferredForms.keys.sorted().compactMap { normalizedPreferred -> VocabularyGlossaryEntry? in
            guard let preferred = preferredForms[normalizedPreferred] else { return nil }
            let hints = Array(mergedHints[normalizedPreferred] ?? []).sorted()
            return VocabularyGlossaryEntry(preferred: preferred, hints: hints)
        }

        guard limit > 0 else { return [] }
        return Array(entries.prefix(limit))
    }

    static func mergedManualEntries(
        existing: [ManualVocabularyEntry],
        additions: [ManualVocabularyEntry]
    ) -> [ManualVocabularyEntry] {
        mergeManualEntries(existing + additions)
    }

    private func mutateState(
        _ mutation: (inout PersistedState) throws -> Void
    ) throws -> CustomVocabularySnapshot {
        lock.lock()
        defer { lock.unlock() }

        var nextState = state
        try mutation(&nextState)
        nextState.updatedAt = Date()
        try persist(nextState)
        state = nextState
        NotificationCenter.default.post(name: .customVocabularyDidChange, object: nil)
        return Self.snapshot(from: nextState)
    }

    private static func snapshot(from state: PersistedState) -> CustomVocabularySnapshot {
        let sortedLearnedRules = state.learnedRules.sorted { lhs, rhs in
            if lhs.isPromoted != rhs.isPromoted {
                return lhs.isPromoted && !rhs.isPromoted
            }
            if lhs.count == rhs.count {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.count > rhs.count
        }

        let sortedShortcuts = state.shortcutEntries.sorted { lhs, rhs in
            let lhsKey = normalizedLookupKey(lhs.trigger)
            let rhsKey = normalizedLookupKey(rhs.trigger)
            if lhsKey == rhsKey {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhsKey < rhsKey
        }

        return CustomVocabularySnapshot(
            editorText: editorText(from: state.manualEntries),
            manualEntries: state.manualEntries,
            shortcutEntries: sortedShortcuts,
            learnedRules: sortedLearnedRules
        )
    }

    private func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: storageURL) else {
            return PersistedState.empty()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PersistedState.self, from: data) else {
            return PersistedState.empty()
        }

        guard decoded.schemaVersion == PersistedState.currentSchemaVersion else {
            return PersistedState.empty()
        }

        return decoded
    }

    private func persist(_ state: PersistedState) throws {
        let directoryURL = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: storageURL, options: .atomic)
    }

    private func deleteLegacyStoreIfNeeded() {
        guard legacyStorageURL != storageURL else { return }
        guard FileManager.default.fileExists(atPath: legacyStorageURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: legacyStorageURL)
            logger.info("Deleted legacy vocabulary store '\(legacyStorageURL.path)'")
        } catch {
            logger.warning("Failed to delete legacy vocabulary store: \(error.localizedDescription)")
        }
    }

    private static func defaultStorageURL() -> URL {
        baseDirectoryURL().appendingPathComponent(fileName, isDirectory: false)
    }

    private static func defaultLegacyStorageURL() -> URL {
        baseDirectoryURL().appendingPathComponent(legacyFileName, isDirectory: false)
    }

    private static func baseDirectoryURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return applicationSupportDirectory
            .appendingPathComponent("voiceclutch", isDirectory: true)
    }

    private func upsertShortcutEntries(triggers: [String], replacement: String) throws -> CustomVocabularySnapshot {
        let normalizedReplacement = Self.normalizedLookupKey(replacement)
        let normalizedTriggers = triggers
            .map { (original: $0, normalized: Self.normalizedLookupKey($0)) }
            .filter { !$0.normalized.isEmpty && $0.normalized != normalizedReplacement }

        guard !normalizedTriggers.isEmpty else {
            throw CustomVocabularyError.invalidOriginalText
        }

        let snapshot = try mutateState { state in
            let now = Date()
            for trigger in normalizedTriggers {
                if let existingIndex = state.shortcutEntries.firstIndex(where: {
                    Self.normalizedLookupKey($0.trigger) == trigger.normalized
                }) {
                    state.shortcutEntries[existingIndex].updatedAt = now
                    state.shortcutEntries[existingIndex] = ShortcutVocabularyEntry(
                        id: state.shortcutEntries[existingIndex].id,
                        trigger: trigger.original,
                        replacement: replacement,
                        createdAt: state.shortcutEntries[existingIndex].createdAt,
                        updatedAt: now
                    )
                } else {
                    state.shortcutEntries.append(
                        ShortcutVocabularyEntry(
                            trigger: trigger.original,
                            replacement: replacement,
                            createdAt: now,
                            updatedAt: now
                        )
                    )
                }
            }
        }
        logger.info("Added shortcut replacement '\(triggers.joined(separator: ", "))' -> '\(replacement)'")
        return snapshot
    }

    private static func parseShortcutLine(_ text: String) throws -> (trigger: String, replacement: String) {
        let parts = text.components(separatedBy: "=>")
        guard parts.count == 2 else {
            throw CustomVocabularyError.invalidShortcutEntry
        }

        let trigger = sanitizedTerm(parts[0])
        let replacement = sanitizedTerm(parts[1])
        guard !trigger.isEmpty else {
            throw CustomVocabularyError.invalidOriginalText
        }
        guard !replacement.isEmpty else {
            throw CustomVocabularyError.invalidReplacementText
        }
        return (trigger, replacement)
    }

    private static func parseEditorText(_ text: String) -> [ManualVocabularyEntry] {
        var parsedEntries: [ManualVocabularyEntry] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { continue }

            let components = trimmedLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let rawCanonical = String(components[0])
            let canonical = sanitizedTerm(rawCanonical)
            guard !canonical.isEmpty else { continue }

            let normalizedCanonical = normalizedLookupKey(canonical)
            guard !normalizedCanonical.isEmpty else { continue }

            var aliases: [String] = []

            if components.count == 2 {
                let aliasString = String(components[1])
                for rawAlias in aliasString.split(separator: ",") {
                    let alias = sanitizedTerm(String(rawAlias))
                    let normalizedAlias = normalizedLookupKey(alias)
                    guard !alias.isEmpty, !normalizedAlias.isEmpty, normalizedAlias != normalizedCanonical else {
                        continue
                    }
                    aliases.append(alias)
                }
            }

            parsedEntries.append(ManualVocabularyEntry(canonical: canonical, aliases: aliases))
        }

        return mergeManualEntries(parsedEntries)
    }

    private static func mergeManualEntries(_ entries: [ManualVocabularyEntry]) -> [ManualVocabularyEntry] {
        var mergedEntries: [String: Set<String>] = [:]
        var canonicalForms: [String: String] = [:]

        for entry in entries {
            let canonical = sanitizedTerm(entry.canonical)
            let normalizedCanonical = normalizedLookupKey(canonical)
            guard !canonical.isEmpty, !normalizedCanonical.isEmpty else { continue }

            canonicalForms[normalizedCanonical] = canonical
            var aliases = mergedEntries[normalizedCanonical] ?? Set<String>()

            for rawAlias in entry.aliases {
                let alias = sanitizedTerm(rawAlias)
                let normalizedAlias = normalizedLookupKey(alias)
                guard !alias.isEmpty, !normalizedAlias.isEmpty, normalizedAlias != normalizedCanonical else {
                    continue
                }
                aliases.insert(alias)
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

    private static func replacingOccurrences(of source: String, with replacement: String, in text: String) -> String {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty else { return text }

        let tokens = normalizedSource.split(whereSeparator: \.isWhitespace).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard !tokens.isEmpty else { return text }

        let pattern = "(?<![\\p{L}\\p{N}])" + tokens.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    static func sanitizedTerm(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseCommaSeparatedTerms(_ text: String) -> [String] {
        var deduped: [String] = []
        var seen = Set<String>()

        for rawTerm in text.split(separator: ",", omittingEmptySubsequences: false) {
            let term = sanitizedTerm(String(rawTerm))
            let normalized = normalizedLookupKey(term)
            guard !term.isEmpty, !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            deduped.append(term)
        }

        return deduped
    }

    static func normalizedLookupKey(_ text: String) -> String {
        sanitizedTerm(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    static func normalizedCollapsedKey(_ text: String) -> String {
        normalizedLookupKey(text)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func containsSubstantiveContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isAutoAddEligibleTarget(_ text: String) -> Bool {
        let words = sanitizedTerm(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return false }

        if words.contains(where: isAcronymLikeToken) {
            return true
        }

        if words.contains(where: isCamelCaseLikeToken) {
            return true
        }

        if words.contains(where: isAlphaNumericBrandToken) {
            return true
        }

        if words.count == 1, let word = words.first {
            return isCapitalizedWord(word)
        }

        let capitalizedCount = words.filter(isCapitalizedWord).count
        return capitalizedCount >= 2
    }

    private static func isAcronymLikeToken(_ token: String) -> Bool {
        let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return false }
        let asString = String(String.UnicodeScalarView(letters))
        return asString == asString.uppercased()
    }

    private static func isCamelCaseLikeToken(_ token: String) -> Bool {
        let letters = Array(token.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        guard letters.count >= 3 else { return false }

        let hasUpper = letters.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasLower = letters.contains { CharacterSet.lowercaseLetters.contains($0) }
        guard hasUpper, hasLower else { return false }

        guard letters.count > 1 else { return false }
        return letters.dropFirst().contains { CharacterSet.uppercaseLetters.contains($0) }
    }

    private static func isAlphaNumericBrandToken(_ token: String) -> Bool {
        let scalars = token.unicodeScalars
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        let hasNumber = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        return hasLetter && hasNumber
    }

    private static func isCapitalizedWord(_ token: String) -> Bool {
        guard let first = token.unicodeScalars.first else { return false }
        guard CharacterSet.uppercaseLetters.contains(first) else { return false }
        return token.unicodeScalars.dropFirst().contains { CharacterSet.lowercaseLetters.contains($0) }
    }
}
