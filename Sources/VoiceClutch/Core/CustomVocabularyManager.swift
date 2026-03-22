import Foundation

extension Notification.Name {
    static let customVocabularyDidChange = Notification.Name("dev.vm.voiceclutch.customVocabularyDidChange")
    static let customVocabularySuggestionAdded = Notification.Name("dev.vm.voiceclutch.customVocabularySuggestionAdded")
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
    let id: UUID
    let source: String
    let target: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        source: String,
        target: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum LLMSuggestionEvidence: String, Codable, Hashable, Sendable {
    case transcriptOnly = "transcript_only"
    case userEdit = "user_edit"
    case mixed
}

enum LLMSuggestionStatus: String, Codable, Hashable, Sendable {
    case pending
    case approved
    case dismissed
}

enum LLMSuggestionTargetTermStatus: String, Codable, Hashable, Sendable {
    case existing
    case new
}

struct LLMVocabularySuggestion: Codable, Hashable, Sendable {
    let id: UUID
    let source: String
    let target: String
    var evidence: LLMSuggestionEvidence
    private(set) var normalizedSource: String
    private(set) var normalizedTarget: String
    var confidence: Double
    var targetTermStatus: LLMSuggestionTargetTermStatus
    var status: LLMSuggestionStatus
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        source: String,
        target: String,
        evidence: LLMSuggestionEvidence,
        confidence: Double,
        targetTermStatus: LLMSuggestionTargetTermStatus,
        status: LLMSuggestionStatus = .pending,
        normalizedSource: String? = nil,
        normalizedTarget: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.evidence = evidence
        self.confidence = confidence
        self.targetTermStatus = targetTermStatus
        self.normalizedSource = normalizedSource ?? CustomVocabularyManager.normalizedLookupKey(source)
        self.normalizedTarget = normalizedTarget ?? CustomVocabularyManager.normalizedLookupKey(target)
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct CustomVocabularySnapshot: Sendable {
    let editorText: String
    let manualEntries: [ManualVocabularyEntry]
    let shortcutEntries: [ShortcutVocabularyEntry]
    let learnedRules: [LearnedCorrectionRule]
    let pendingSuggestions: [LLMVocabularySuggestion]

    init(
        editorText: String = "",
        manualEntries: [ManualVocabularyEntry] = [],
        shortcutEntries: [ShortcutVocabularyEntry] = [],
        learnedRules: [LearnedCorrectionRule] = [],
        pendingSuggestions: [LLMVocabularySuggestion] = []
    ) {
        self.editorText = editorText
        self.manualEntries = manualEntries
        self.shortcutEntries = shortcutEntries
        self.learnedRules = learnedRules
        self.pendingSuggestions = pendingSuggestions
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
    case entryNotFound
    case invalidImportDocument
    case unsupportedImportDocumentVersion(Int)

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
        case .entryNotFound:
            return "This vocabulary entry no longer exists."
        case .invalidImportDocument:
            return "Choose a valid VoiceClutch vocabulary export file."
        case .unsupportedImportDocumentVersion(let version):
            return "This vocabulary file uses unsupported schema version \(version)."
        }
    }
}

final class CustomVocabularyManager: @unchecked Sendable {
    static let shared = CustomVocabularyManager()

    enum NotificationUserInfoKey {
        static let source = "source"
        static let target = "target"
    }

    private struct PortableVocabularyDocument: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let manualEntries: [PortableManualEntry]
        let shortcutEntries: [PortableShortcutEntry]
        let learnedRules: [PortableLearnedRule]
    }

    private struct PortableManualEntry: Codable {
        let canonical: String
        let aliases: [String]
    }

    private struct PortableShortcutEntry: Codable {
        let trigger: String
        let replacement: String
    }

    private struct PortableLearnedRule: Codable {
        let source: String
        let target: String
    }

    private struct PortableShortcutRecord {
        let key: String
        let trigger: String
        let replacement: String
    }

    private struct PortableLearnedRecord {
        struct Key: Hashable {
            let source: String
            let target: String
        }

        let key: Key
        let source: String
        let target: String
    }

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var manualEntries: [ManualVocabularyEntry]
        var shortcutEntries: [ShortcutVocabularyEntry]
        var learnedRules: [LearnedCorrectionRule]
        var llmSuggestions: [LLMVocabularySuggestion]
        let createdAt: Date
        var updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case manualEntries
            case shortcutEntries
            case learnedRules
            case llmSuggestions
            case createdAt
            case updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            manualEntries = try container.decode([ManualVocabularyEntry].self, forKey: .manualEntries)
            shortcutEntries = try container.decode([ShortcutVocabularyEntry].self, forKey: .shortcutEntries)
            learnedRules = try container.decode([LearnedCorrectionRule].self, forKey: .learnedRules)
            llmSuggestions = try container.decodeIfPresent([LLMVocabularySuggestion].self, forKey: .llmSuggestions) ?? []
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }

        init(
            schemaVersion: Int,
            manualEntries: [ManualVocabularyEntry],
            shortcutEntries: [ShortcutVocabularyEntry],
            learnedRules: [LearnedCorrectionRule],
            llmSuggestions: [LLMVocabularySuggestion],
            createdAt: Date,
            updatedAt: Date
        ) {
            self.schemaVersion = schemaVersion
            self.manualEntries = manualEntries
            self.shortcutEntries = shortcutEntries
            self.learnedRules = learnedRules
            self.llmSuggestions = llmSuggestions
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        static func empty(now: Date = Date()) -> PersistedState {
            PersistedState(
                schemaVersion: Self.currentSchemaVersion,
                manualEntries: CustomVocabularyManager.defaultManualEntries,
                shortcutEntries: [],
                learnedRules: [],
                llmSuggestions: [],
                createdAt: now,
                updatedAt: now
            )
        }

        static let currentSchemaVersion = 3
    }

    private struct PersistedStateV2: Codable {
        var schemaVersion: Int
        var manualEntries: [ManualVocabularyEntry]
        var shortcutEntries: [ShortcutVocabularyEntry]
        var learnedRules: [LearnedCorrectionRule]
        let createdAt: Date
        var updatedAt: Date
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
    private static let maxSuggestionHistoryCount = 240
    private static let defaultManualEntries: [ManualVocabularyEntry] = mergeManualEntries([
        ManualVocabularyEntry(canonical: "VoiceClutch", aliases: ["voice clutch"])
    ])

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

    func exportPortableVocabulary() throws -> Data {
        let currentSnapshot = snapshot()
        let document = PortableVocabularyDocument(
            schemaVersion: PortableVocabularyDocument.currentSchemaVersion,
            manualEntries: currentSnapshot.manualEntries.map { entry in
                PortableManualEntry(canonical: entry.canonical, aliases: entry.aliases)
            },
            shortcutEntries: currentSnapshot.shortcutEntries.map { entry in
                PortableShortcutEntry(trigger: entry.trigger, replacement: entry.replacement)
            },
            learnedRules: currentSnapshot.learnedRules.map { rule in
                PortableLearnedRule(source: rule.source, target: rule.target)
            }
        )
        let json = try Self.formattedPortableJSONString(for: document)
        return Data(json.utf8)
    }

    @discardableResult
    func importPortableVocabulary(_ data: Data) throws -> CustomVocabularySnapshot {
        let decoder = JSONDecoder()
        let document: PortableVocabularyDocument
        do {
            document = try decoder.decode(PortableVocabularyDocument.self, from: data)
        } catch {
            throw CustomVocabularyError.invalidImportDocument
        }

        guard document.schemaVersion == PortableVocabularyDocument.currentSchemaVersion else {
            throw CustomVocabularyError.unsupportedImportDocumentVersion(document.schemaVersion)
        }

        let importedManualEntries = Self.sanitizedPortableManualEntries(document.manualEntries)
        let importedShortcuts = Self.sanitizedPortableShortcutRecords(document.shortcutEntries)
        let importedLearnedRules = Self.sanitizedPortableLearnedRecords(document.learnedRules)

        let snapshot = try mutateState { state in
            let now = Date()

            var manualByKey: [String: ManualVocabularyEntry] = [:]
            for entry in state.manualEntries {
                let normalizedCanonical = Self.normalizedLookupKey(entry.canonical)
                guard !normalizedCanonical.isEmpty else { continue }
                manualByKey[normalizedCanonical] = entry
            }
            for entry in importedManualEntries {
                let normalizedCanonical = Self.normalizedLookupKey(entry.canonical)
                guard !normalizedCanonical.isEmpty else { continue }
                manualByKey[normalizedCanonical] = entry
            }
            state.manualEntries = Self.mergeManualEntries(Array(manualByKey.values))

            let importedShortcutsByKey = Dictionary(
                uniqueKeysWithValues: importedShortcuts.map { ($0.key, $0) }
            )
            var matchedShortcutKeys = Set<String>()
            var mergedShortcuts: [ShortcutVocabularyEntry] = []
            for existingEntry in state.shortcutEntries {
                let key = Self.normalizedLookupKey(existingEntry.trigger)
                if let importedEntry = importedShortcutsByKey[key] {
                    mergedShortcuts.append(
                        ShortcutVocabularyEntry(
                            id: existingEntry.id,
                            trigger: importedEntry.trigger,
                            replacement: importedEntry.replacement,
                            createdAt: existingEntry.createdAt,
                            updatedAt: now
                        )
                    )
                    matchedShortcutKeys.insert(key)
                } else {
                    mergedShortcuts.append(existingEntry)
                }
            }
            for importedEntry in importedShortcuts where !matchedShortcutKeys.contains(importedEntry.key) {
                mergedShortcuts.append(
                    ShortcutVocabularyEntry(
                        trigger: importedEntry.trigger,
                        replacement: importedEntry.replacement,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
            state.shortcutEntries = mergedShortcuts

            let importedLearnedByKey = Dictionary(
                uniqueKeysWithValues: importedLearnedRules.map { ($0.key, $0) }
            )
            var matchedLearnedKeys = Set<PortableLearnedRecord.Key>()
            var mergedLearnedRules: [LearnedCorrectionRule] = []
            for existingRule in state.learnedRules {
                let sourceKey = Self.normalizedLookupKey(existingRule.source)
                let targetKey = Self.normalizedLookupKey(existingRule.target)
                let key = PortableLearnedRecord.Key(source: sourceKey, target: targetKey)
                if let importedRule = importedLearnedByKey[key] {
                    mergedLearnedRules.append(
                        LearnedCorrectionRule(
                            id: existingRule.id,
                            source: importedRule.source,
                            target: importedRule.target,
                            createdAt: existingRule.createdAt,
                            updatedAt: now
                        )
                    )
                    matchedLearnedKeys.insert(key)
                } else {
                    mergedLearnedRules.append(existingRule)
                }
            }
            for importedRule in importedLearnedRules where !matchedLearnedKeys.contains(importedRule.key) {
                mergedLearnedRules.append(
                    LearnedCorrectionRule(
                        source: importedRule.source,
                        target: importedRule.target,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
            state.learnedRules = mergedLearnedRules
        }
        logger.info(
            "Imported portable vocabulary (\(importedManualEntries.count) manual, \(importedShortcuts.count) shortcut, \(importedLearnedRules.count) learned)"
        )
        return snapshot
    }

    private static func formattedPortableJSONString(for document: PortableVocabularyDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let manualJSON = try encodePortableArrayOnSeparateLines(document.manualEntries, using: encoder)
        let shortcutJSON = try encodePortableArrayOnSeparateLines(document.shortcutEntries, using: encoder)
        let learnedJSON = try encodePortableArrayOnSeparateLines(document.learnedRules, using: encoder)

        return """
        {
          "schemaVersion": \(document.schemaVersion),
          "manualEntries": \(manualJSON),
          "shortcutEntries": \(shortcutJSON),
          "learnedRules": \(learnedJSON)
        }
        """
    }

    private static func encodePortableArrayOnSeparateLines<T: Encodable>(
        _ values: [T],
        using encoder: JSONEncoder
    ) throws -> String {
        guard !values.isEmpty else { return "[]" }

        let lines = try values.map { value in
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        return """
        [
        \(lines.map { "    \($0)" }.joined(separator: ",\n"))
          ]
        """
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
    func removeManualEntry(canonical: String) throws -> CustomVocabularySnapshot {
        let normalizedKey = Self.normalizedLookupKey(canonical)
        let snapshot = try mutateState { state in
            state.manualEntries.removeAll { entry in
                Self.normalizedLookupKey(entry.canonical) == normalizedKey
            }
        }
        logger.info("Removed manual vocabulary entry '\(canonical)'")
        return snapshot
    }

    @discardableResult
    func removeShortcutEntry(id: UUID) throws -> CustomVocabularySnapshot {
        let snapshot = try mutateState { state in
            state.shortcutEntries.removeAll { $0.id == id }
        }
        logger.info("Removed shortcut vocabulary entry id=\(id.uuidString)")
        return snapshot
    }

    @discardableResult
    func updateManualEntry(
        existingCanonical: String,
        canonical: String,
        aliases: [String]
    ) throws -> CustomVocabularySnapshot {
        let normalizedExisting = Self.normalizedLookupKey(existingCanonical)
        guard !normalizedExisting.isEmpty else {
            throw CustomVocabularyError.entryNotFound
        }

        let sanitizedCanonical = Self.sanitizedTerm(canonical)
        let normalizedCanonical = Self.normalizedLookupKey(sanitizedCanonical)
        guard !sanitizedCanonical.isEmpty, !normalizedCanonical.isEmpty else {
            throw CustomVocabularyError.invalidManualEntry
        }

        let sanitizedAliases = aliases
            .map(Self.sanitizedTerm)
            .filter { alias in
                let normalizedAlias = Self.normalizedLookupKey(alias)
                return !alias.isEmpty && !normalizedAlias.isEmpty && normalizedAlias != normalizedCanonical
            }

        let snapshot = try mutateState { state in
            guard let index = state.manualEntries.firstIndex(where: {
                Self.normalizedLookupKey($0.canonical) == normalizedExisting
            }) else {
                throw CustomVocabularyError.entryNotFound
            }

            state.manualEntries[index] = ManualVocabularyEntry(
                canonical: sanitizedCanonical,
                aliases: sanitizedAliases
            )
            state.manualEntries = Self.mergeManualEntries(state.manualEntries)
        }
        logger.info("Updated manual vocabulary entry '\(existingCanonical)' -> '\(sanitizedCanonical)'")
        return snapshot
    }

    @discardableResult
    func updateShortcutEntry(id: UUID, trigger: String, replacement: String) throws -> CustomVocabularySnapshot {
        let sanitizedTrigger = Self.sanitizedTerm(trigger)
        let sanitizedReplacement = Self.sanitizedTerm(replacement)
        let normalizedTrigger = Self.normalizedLookupKey(sanitizedTrigger)
        let normalizedReplacement = Self.normalizedLookupKey(sanitizedReplacement)
        guard !normalizedTrigger.isEmpty else {
            throw CustomVocabularyError.invalidOriginalText
        }
        guard !normalizedReplacement.isEmpty else {
            throw CustomVocabularyError.invalidReplacementText
        }
        guard normalizedTrigger != normalizedReplacement else {
            throw CustomVocabularyError.invalidShortcutEntry
        }

        let snapshot = try mutateState { state in
            guard let index = state.shortcutEntries.firstIndex(where: { $0.id == id }) else {
                throw CustomVocabularyError.entryNotFound
            }
            let now = Date()
            state.shortcutEntries[index] = ShortcutVocabularyEntry(
                id: id,
                trigger: sanitizedTrigger,
                replacement: sanitizedReplacement,
                createdAt: state.shortcutEntries[index].createdAt,
                updatedAt: now
            )
        }
        logger.info("Updated shortcut vocabulary entry id=\(id.uuidString)")
        return snapshot
    }

    @discardableResult
    func updateLearnedRule(id: UUID, source: String, target: String) throws -> CustomVocabularySnapshot {
        let sanitizedSource = Self.sanitizedTerm(source)
        let sanitizedTarget = Self.sanitizedTerm(target)
        let normalizedSource = Self.normalizedLookupKey(sanitizedSource)
        let normalizedTarget = Self.normalizedLookupKey(sanitizedTarget)
        guard !normalizedSource.isEmpty else {
            throw CustomVocabularyError.invalidOriginalText
        }
        guard !normalizedTarget.isEmpty else {
            throw CustomVocabularyError.invalidReplacementText
        }
        guard normalizedSource != normalizedTarget else {
            throw CustomVocabularyError.invalidShortcutEntry
        }

        let snapshot = try mutateState { state in
            guard let index = state.learnedRules.firstIndex(where: { $0.id == id }) else {
                throw CustomVocabularyError.entryNotFound
            }
            let now = Date()
            state.learnedRules[index] = LearnedCorrectionRule(
                id: id,
                source: sanitizedSource,
                target: sanitizedTarget,
                createdAt: state.learnedRules[index].createdAt,
                updatedAt: now
            )
        }
        logger.info("Updated learned correction rule id=\(id.uuidString)")
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
                state.learnedRules[index].updatedAt = now
            } else {
                state.learnedRules.append(
                    LearnedCorrectionRule(
                        source: sanitizedSource,
                        target: sanitizedTarget,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }
        logger.info("Learned correction '\(sanitizedSource)' -> '\(sanitizedTarget)'")
        return snapshot
    }

    @discardableResult
    func recordUserEditSuggestion(source: String, target: String) -> CustomVocabularySnapshot {
        guard AutoAddCorrectionsPreference.load() else {
            return snapshot()
        }

        let sanitizedSource = Self.sanitizedTerm(source)
        let sanitizedTarget = Self.sanitizedTerm(target)
        let normalizedSource = Self.normalizedLookupKey(sanitizedSource)
        let normalizedTarget = Self.normalizedLookupKey(sanitizedTarget)
        guard
            !sanitizedSource.isEmpty,
            !sanitizedTarget.isEmpty,
            !normalizedSource.isEmpty,
            !normalizedTarget.isEmpty,
            normalizedSource != normalizedTarget
        else {
            return snapshot()
        }

        var didPersist = false

        do {
            let snapshot = try mutateState { state in
                let targetStatus = Self.targetTermStatus(for: sanitizedTarget, state: state)
                guard targetStatus != .existing else {
                    return
                }

                guard !state.llmSuggestions.contains(where: {
                    $0.status == .pending && $0.normalizedTarget == normalizedTarget
                }) else {
                    return
                }

                let now = Date()
                trimSuggestionHistory(in: &state, now: now)
                state.llmSuggestions.append(
                    LLMVocabularySuggestion(
                        source: sanitizedSource,
                        target: sanitizedTarget,
                        evidence: .userEdit,
                        confidence: 0.99,
                        targetTermStatus: targetStatus,
                        status: .pending,
                        normalizedSource: normalizedSource,
                        normalizedTarget: normalizedTarget,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                trimSuggestionHistory(in: &state, now: now)
                didPersist = true
            }

            if didPersist {
                NotificationCenter.default.post(
                    name: .customVocabularySuggestionAdded,
                    object: nil,
                    userInfo: [
                        NotificationUserInfoKey.source: sanitizedSource,
                        NotificationUserInfoKey.target: sanitizedTarget,
                    ]
                )
            }
            return snapshot
        } catch {
            logger.warning("Failed to persist manual-edit suggestion: \(error.localizedDescription)")
            return snapshot()
        }
    }

    @discardableResult
    func upsertLearnedRule(
        source: String,
        target: String
    ) throws -> CustomVocabularySnapshot {
        let sanitizedSource = Self.sanitizedTerm(source)
        let sanitizedTarget = Self.sanitizedTerm(target)
        guard !sanitizedSource.isEmpty, !sanitizedTarget.isEmpty else {
            return snapshot()
        }

        let normalizedSource = Self.normalizedLookupKey(sanitizedSource)
        let normalizedTarget = Self.normalizedLookupKey(sanitizedTarget)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty, normalizedSource != normalizedTarget else {
            return snapshot()
        }

        let snapshot = try mutateState { state in
            let now = Date()
            if let index = state.learnedRules.firstIndex(where: {
                Self.normalizedLookupKey($0.source) == normalizedSource
                    && Self.normalizedLookupKey($0.target) == normalizedTarget
            }) {
                state.learnedRules[index].updatedAt = now
            } else {
                state.learnedRules.append(
                    LearnedCorrectionRule(
                        source: sanitizedSource,
                        target: sanitizedTarget,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }
        logger.info("Upserted learned correction '\(sanitizedSource)' -> '\(sanitizedTarget)'")
        return snapshot
    }

    func llmSuggestions(status: LLMSuggestionStatus? = nil) -> [LLMVocabularySuggestion] {
        lock.lock()
        defer { lock.unlock() }

        let suggestions = state.llmSuggestions
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .pending
                }
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        if let status {
            return suggestions.filter { $0.status == status }
        }
        return suggestions
    }

    @discardableResult
    func addLLMSuggestions(_ suggestions: [LLMVocabularySuggestion]) throws -> CustomVocabularySnapshot {
        guard !suggestions.isEmpty else {
            return snapshot()
        }

        let sanitizedSuggestions = suggestions.compactMap(sanitizeSuggestion)
        guard !sanitizedSuggestions.isEmpty else {
            return snapshot()
        }

        let snapshot = try mutateState { state in
            let now = Date()
            trimSuggestionHistory(in: &state, now: now)

            for incoming in sanitizedSuggestions {
                let incomingSource = incoming.normalizedSource
                let incomingTarget = incoming.normalizedTarget

                if let pendingIndex = state.llmSuggestions.firstIndex(where: { suggestion in
                    suggestion.status == .pending &&
                        suggestion.normalizedSource == incomingSource &&
                        suggestion.normalizedTarget == incomingTarget
                }) {
                    state.llmSuggestions[pendingIndex].updatedAt = now
                    state.llmSuggestions[pendingIndex].confidence = max(
                        state.llmSuggestions[pendingIndex].confidence,
                        incoming.confidence
                    )
                    state.llmSuggestions[pendingIndex].evidence = mergeEvidence(
                        state.llmSuggestions[pendingIndex].evidence,
                        incoming.evidence
                    )
                    state.llmSuggestions[pendingIndex].targetTermStatus = incoming.targetTermStatus
                    continue
                }

                state.llmSuggestions.append(
                    LLMVocabularySuggestion(
                        source: incoming.source,
                        target: incoming.target,
                        evidence: incoming.evidence,
                        confidence: incoming.confidence,
                        targetTermStatus: incoming.targetTermStatus,
                        status: .pending,
                        normalizedSource: incomingSource,
                        normalizedTarget: incomingTarget,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }

            trimSuggestionHistory(in: &state, now: now)
        }
        logger.info("Added \(sanitizedSuggestions.count) LLM vocabulary suggestion(s)")
        return snapshot
    }

    @discardableResult
    func approveLLMSuggestion(id: UUID) throws -> CustomVocabularySnapshot {
        let snapshot = try mutateState { state in
            guard let suggestionIndex = state.llmSuggestions.firstIndex(where: { $0.id == id }),
                  state.llmSuggestions[suggestionIndex].status == .pending else {
                return
            }

            let now = Date()
            let suggestion = state.llmSuggestions[suggestionIndex]
            state.llmSuggestions[suggestionIndex].status = .approved
            state.llmSuggestions[suggestionIndex].updatedAt = now

            let source = Self.sanitizedTerm(suggestion.source)
            let target = Self.sanitizedTerm(suggestion.target)
            let normalizedSource = Self.normalizedLookupKey(source)
            let normalizedTarget = Self.normalizedLookupKey(target)
            guard
                !source.isEmpty,
                !target.isEmpty,
                !normalizedSource.isEmpty,
                !normalizedTarget.isEmpty,
                normalizedSource != normalizedTarget
            else {
                return
            }

            if let learnedIndex = state.learnedRules.firstIndex(where: {
                Self.normalizedLookupKey($0.source) == normalizedSource &&
                    Self.normalizedLookupKey($0.target) == normalizedTarget
            }) {
                state.learnedRules[learnedIndex].updatedAt = now
            } else {
                state.learnedRules.append(
                    LearnedCorrectionRule(
                        source: source,
                        target: target,
                        createdAt: now,
                        updatedAt: now
                    )
                )
            }
        }
        logger.info("Approved LLM suggestion id=\(id.uuidString)")
        return snapshot
    }

    @discardableResult
    func dismissLLMSuggestion(id: UUID) throws -> CustomVocabularySnapshot {
        let snapshot = try mutateState { state in
            guard let suggestionIndex = state.llmSuggestions.firstIndex(where: { $0.id == id }),
                  state.llmSuggestions[suggestionIndex].status == .pending else {
                return
            }

            state.llmSuggestions[suggestionIndex].status = .dismissed
            state.llmSuggestions[suggestionIndex].updatedAt = Date()
        }
        logger.info("Dismissed LLM suggestion id=\(id.uuidString)")
        return snapshot
    }

    @discardableResult
    func clearDismissedAndOldSuggestions(maxAgeDays: Int = 30) throws -> CustomVocabularySnapshot {
        let maxAge = max(1, maxAgeDays)
        let now = Date()
        let cutoff = now.addingTimeInterval(-TimeInterval(maxAge * 86_400))

        lock.lock()
        let hasRemovableSuggestions = state.llmSuggestions.contains { suggestion in
            suggestion.status != .pending || suggestion.updatedAt < cutoff
        }
        lock.unlock()

        guard hasRemovableSuggestions else {
            return snapshot()
        }

        let snapshot = try mutateState { state in
            state.llmSuggestions.removeAll { suggestion in
                suggestion.status != .pending || suggestion.updatedAt < cutoff
            }
        }
        logger.info("Cleared dismissed/old LLM suggestions")
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

    func targetTermStatus(for target: String) -> LLMSuggestionTargetTermStatus {
        Self.targetTermStatus(for: target, snapshot: snapshot())
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
            let triggers = parseCommaSeparatedTerms(entry.trigger)
            if triggers.isEmpty {
                registerRule(source: entry.trigger, replacement: entry.replacement, priority: .shortcut)
            } else {
                for trigger in triggers {
                    registerRule(source: trigger, replacement: entry.replacement, priority: .shortcut)
                }
            }
        }

        for learnedRule in snapshot.learnedRules.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let sources = parseCommaSeparatedTerms(learnedRule.source)
            if sources.isEmpty {
                registerRule(source: learnedRule.source, replacement: learnedRule.target, priority: .learned)
            } else {
                for source in sources {
                    registerRule(source: source, replacement: learnedRule.target, priority: .learned)
                }
            }
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

        for learnedRule in snapshot.learnedRules {
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

    static func targetTermStatus(
        for target: String,
        snapshot: CustomVocabularySnapshot
    ) -> LLMSuggestionTargetTermStatus {
        let normalizedTarget = normalizedLookupKey(target)
        guard !normalizedTarget.isEmpty else {
            return .new
        }

        for entry in snapshot.manualEntries {
            if normalizedLookupKey(entry.canonical) == normalizedTarget {
                return .existing
            }
            if entry.aliases.contains(where: { normalizedLookupKey($0) == normalizedTarget }) {
                return .existing
            }
        }

        if snapshot.shortcutEntries.contains(where: { normalizedLookupKey($0.replacement) == normalizedTarget }) {
            return .existing
        }

        if snapshot.learnedRules.contains(where: { normalizedLookupKey($0.target) == normalizedTarget }) {
            return .existing
        }

        return .new
    }

    func hasLearnedRule(source: String, target: String) -> Bool {
        let normalizedSource = Self.normalizedLookupKey(source)
        let normalizedTarget = Self.normalizedLookupKey(target)
        guard !normalizedSource.isEmpty, !normalizedTarget.isEmpty else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }
        return state.learnedRules.contains { rule in
            Self.normalizedLookupKey(rule.source) == normalizedSource &&
                Self.normalizedLookupKey(rule.target) == normalizedTarget
        }
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
        let snapshot: CustomVocabularySnapshot
        do {
            var nextState = state
            try mutation(&nextState)
            nextState.updatedAt = Date()
            try persist(nextState)
            state = nextState
            snapshot = Self.snapshot(from: nextState)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        NotificationCenter.default.post(name: .customVocabularyDidChange, object: nil)
        return snapshot
    }

    private static func snapshot(from state: PersistedState) -> CustomVocabularySnapshot {
        let sortedLearnedRules = state.learnedRules.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            let lhsKey = normalizedLookupKey(lhs.source) + "->" + normalizedLookupKey(lhs.target)
            let rhsKey = normalizedLookupKey(rhs.source) + "->" + normalizedLookupKey(rhs.target)
            return lhsKey < rhsKey
        }

        let sortedShortcuts = state.shortcutEntries.sorted { lhs, rhs in
            let lhsKey = normalizedLookupKey(lhs.trigger)
            let rhsKey = normalizedLookupKey(rhs.trigger)
            if lhsKey == rhsKey {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhsKey < rhsKey
        }

        let pendingSuggestions = state.llmSuggestions
            .filter { $0.status == .pending }
            .sorted { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        return CustomVocabularySnapshot(
            editorText: editorText(from: state.manualEntries),
            manualEntries: state.manualEntries,
            shortcutEntries: sortedShortcuts,
            learnedRules: sortedLearnedRules,
            pendingSuggestions: pendingSuggestions
        )
    }

    private static func targetTermStatus(
        for target: String,
        state: PersistedState
    ) -> LLMSuggestionTargetTermStatus {
        let normalizedTarget = normalizedLookupKey(target)
        guard !normalizedTarget.isEmpty else {
            return .new
        }

        for entry in state.manualEntries {
            if normalizedLookupKey(entry.canonical) == normalizedTarget {
                return .existing
            }
            if entry.aliases.contains(where: { normalizedLookupKey($0) == normalizedTarget }) {
                return .existing
            }
        }

        if state.shortcutEntries.contains(where: { normalizedLookupKey($0.replacement) == normalizedTarget }) {
            return .existing
        }

        if state.learnedRules.contains(where: { normalizedLookupKey($0.target) == normalizedTarget }) {
            return .existing
        }

        return .new
    }

    private func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: storageURL) else {
            return PersistedState.empty()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(PersistedState.self, from: data),
           decoded.schemaVersion == PersistedState.currentSchemaVersion {
            return decoded
        }

        if let legacy = try? decoder.decode(PersistedStateV2.self, from: data),
           legacy.schemaVersion == 2 {
            logger.info("Migrated custom vocabulary store from schema v2 to v3")
            return PersistedState(
                schemaVersion: PersistedState.currentSchemaVersion,
                manualEntries: legacy.manualEntries,
                shortcutEntries: legacy.shortcutEntries,
                learnedRules: legacy.learnedRules,
                llmSuggestions: [],
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt
            )
        }

        return PersistedState.empty()
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

    private func sanitizeSuggestion(_ suggestion: LLMVocabularySuggestion) -> LLMVocabularySuggestion? {
        let source = Self.sanitizedTerm(suggestion.source)
        let target = Self.sanitizedTerm(suggestion.target)
        let normalizedSource = Self.normalizedLookupKey(source)
        let normalizedTarget = Self.normalizedLookupKey(target)
        guard
            !source.isEmpty,
            !target.isEmpty,
            !normalizedSource.isEmpty,
            !normalizedTarget.isEmpty,
            normalizedSource != normalizedTarget,
            Self.containsSubstantiveContent(source),
            Self.containsSubstantiveContent(target)
        else {
            return nil
        }

        if source.count > 80 || target.count > 80 {
            return nil
        }
        if source.contains("\n") || target.contains("\n") {
            return nil
        }

        return LLMVocabularySuggestion(
            id: suggestion.id,
            source: source,
            target: target,
            evidence: suggestion.evidence,
            confidence: min(1, max(0, suggestion.confidence)),
            targetTermStatus: suggestion.targetTermStatus,
            status: .pending,
            createdAt: suggestion.createdAt,
            updatedAt: suggestion.updatedAt
        )
    }

    private func mergeEvidence(_ lhs: LLMSuggestionEvidence, _ rhs: LLMSuggestionEvidence) -> LLMSuggestionEvidence {
        if lhs == rhs {
            return lhs
        }
        return .mixed
    }

    private func trimSuggestionHistory(in state: inout PersistedState, now: Date) {
        let cutoff = now.addingTimeInterval(-TimeInterval(60 * 86_400))
        state.llmSuggestions.removeAll { suggestion in
            suggestion.status != .pending && suggestion.updatedAt < cutoff
        }

        if state.llmSuggestions.count <= Self.maxSuggestionHistoryCount {
            return
        }

        state.llmSuggestions = state.llmSuggestions
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .pending
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(Self.maxSuggestionHistoryCount)
            .map { $0 }
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

    private static func sanitizedPortableManualEntries(
        _ entries: [PortableManualEntry]
    ) -> [ManualVocabularyEntry] {
        let sanitized = entries.compactMap { entry -> ManualVocabularyEntry? in
            let canonical = sanitizedTerm(entry.canonical)
            let normalizedCanonical = normalizedLookupKey(canonical)
            guard !canonical.isEmpty, !normalizedCanonical.isEmpty else {
                return nil
            }

            var dedupedAliases: [String] = []
            var seenAliasKeys = Set<String>()
            for alias in entry.aliases {
                let sanitizedAlias = sanitizedTerm(alias)
                let normalizedAlias = normalizedLookupKey(sanitizedAlias)
                guard
                    !sanitizedAlias.isEmpty,
                    !normalizedAlias.isEmpty,
                    normalizedAlias != normalizedCanonical,
                    seenAliasKeys.insert(normalizedAlias).inserted
                else {
                    continue
                }
                dedupedAliases.append(sanitizedAlias)
            }

            return ManualVocabularyEntry(canonical: canonical, aliases: dedupedAliases)
        }
        return mergeManualEntries(sanitized)
    }

    private static func sanitizedPortableShortcutRecords(
        _ entries: [PortableShortcutEntry]
    ) -> [PortableShortcutRecord] {
        var records: [PortableShortcutRecord] = []
        var indexByKey: [String: Int] = [:]

        for entry in entries {
            let trigger = sanitizedTerm(entry.trigger)
            let replacement = sanitizedTerm(entry.replacement)
            let normalizedTrigger = normalizedLookupKey(trigger)
            let normalizedReplacement = normalizedLookupKey(replacement)
            guard
                !normalizedTrigger.isEmpty,
                !normalizedReplacement.isEmpty,
                normalizedTrigger != normalizedReplacement
            else {
                continue
            }

            let record = PortableShortcutRecord(
                key: normalizedTrigger,
                trigger: trigger,
                replacement: replacement
            )

            if let existingIndex = indexByKey[normalizedTrigger] {
                records[existingIndex] = record
            } else {
                indexByKey[normalizedTrigger] = records.count
                records.append(record)
            }
        }

        return records
    }

    private static func sanitizedPortableLearnedRecords(
        _ entries: [PortableLearnedRule]
    ) -> [PortableLearnedRecord] {
        var records: [PortableLearnedRecord] = []
        var indexByKey: [PortableLearnedRecord.Key: Int] = [:]

        for entry in entries {
            let source = sanitizedTerm(entry.source)
            let target = sanitizedTerm(entry.target)
            let normalizedSource = normalizedLookupKey(source)
            let normalizedTarget = normalizedLookupKey(target)
            guard
                !normalizedSource.isEmpty,
                !normalizedTarget.isEmpty,
                normalizedSource != normalizedTarget
            else {
                continue
            }

            let key = PortableLearnedRecord.Key(source: normalizedSource, target: normalizedTarget)
            let record = PortableLearnedRecord(
                key: key,
                source: source,
                target: target
            )

            if let existingIndex = indexByKey[key] {
                records[existingIndex] = record
            } else {
                indexByKey[key] = records.count
                records.append(record)
            }
        }

        return records
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
