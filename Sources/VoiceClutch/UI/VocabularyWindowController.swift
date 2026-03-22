import AppKit
import UniformTypeIdentifiers

private enum VocabularyWindowMetrics {
    static let typeInset: CGFloat = 0
    static let textInset: CGFloat = 0
    static let actionInset: CGFloat = 0
    static let actionButtonTrailingInset: CGFloat = 5
    // Compensates for NSTableView per-cell horizontal inset so row content aligns with header labels.
    static let cellLeadingCompensation: CGFloat = -5
}

enum VocabularyBadgeStyle: Equatable {
    case suggestion
    case manual
    case shortcut
    case learned
}

enum VocabularyRowKind: Equatable {
    case suggestion(UUID)
    case manual(String)
    case shortcut(UUID)
    case learned(UUID)
}

struct VocabularyListRow: Equatable {
    let kind: VocabularyRowKind
    let badgeText: String
    let badgeStyle: VocabularyBadgeStyle
    let sourceText: String
    let replacementText: String
    let highlightsSuggestion: Bool
}

enum VocabularyListBuilder {
    static func rows(from snapshot: CustomVocabularySnapshot) -> [VocabularyListRow] {
        var rows: [(
            index: Int,
            sectionRank: Int,
            recencyTimestamp: TimeInterval?,
            primary: String,
            secondary: String,
            tertiary: String,
            row: VocabularyListRow
        )] = []
        var insertionIndex = 0

        for suggestion in snapshot.pendingSuggestions {
            rows.append((
                index: insertionIndex,
                sectionRank: 0,
                recencyTimestamp: suggestion.updatedAt.timeIntervalSince1970,
                primary: normalizedKey(suggestion.target),
                secondary: normalizedKey(suggestion.target),
                tertiary: normalizedKey(suggestion.source),
                row: VocabularyListRow(
                    kind: .suggestion(suggestion.id),
                    badgeText: "Suggestion",
                    badgeStyle: .suggestion,
                    sourceText: suggestion.source,
                    replacementText: suggestion.target,
                    highlightsSuggestion: true
                )
            ))
            insertionIndex += 1
        }

        for entry in snapshot.manualEntries {
            let sourceText = entry.aliases.isEmpty ? entry.canonical : entry.aliases.joined(separator: ", ")
            rows.append((
                index: insertionIndex,
                sectionRank: 1,
                recencyTimestamp: nil,
                primary: normalizedKey(entry.canonical),
                secondary: normalizedKey(sourceText),
                tertiary: "",
                row: VocabularyListRow(
                    kind: .manual(entry.canonical),
                    badgeText: "Manual",
                    badgeStyle: .manual,
                    sourceText: sourceText,
                    replacementText: entry.canonical,
                    highlightsSuggestion: false
                )
            ))
            insertionIndex += 1
        }

        for entry in snapshot.shortcutEntries {
            rows.append((
                index: insertionIndex,
                sectionRank: 1,
                recencyTimestamp: entry.updatedAt.timeIntervalSince1970,
                primary: normalizedKey(entry.replacement),
                secondary: normalizedKey(entry.trigger),
                tertiary: "",
                row: VocabularyListRow(
                    kind: .shortcut(entry.id),
                    badgeText: "Shortcut",
                    badgeStyle: .shortcut,
                    sourceText: entry.trigger,
                    replacementText: entry.replacement,
                    highlightsSuggestion: false
                )
            ))
            insertionIndex += 1
        }

        for rule in snapshot.learnedRules {
            rows.append((
                index: insertionIndex,
                sectionRank: 1,
                recencyTimestamp: rule.updatedAt.timeIntervalSince1970,
                primary: normalizedKey(rule.target),
                secondary: normalizedKey(rule.source),
                tertiary: "",
                row: VocabularyListRow(
                    kind: .learned(rule.id),
                    badgeText: "Learned",
                    badgeStyle: .learned,
                    sourceText: rule.source,
                    replacementText: rule.target,
                    highlightsSuggestion: false
                )
            ))
            insertionIndex += 1
        }

        return rows
            .sorted { lhs, rhs in
                if lhs.sectionRank != rhs.sectionRank {
                    return lhs.sectionRank < rhs.sectionRank
                }
                if let lhsTimestamp = lhs.recencyTimestamp,
                   let rhsTimestamp = rhs.recencyTimestamp,
                   lhsTimestamp != rhsTimestamp {
                    return lhsTimestamp > rhsTimestamp
                }
                if lhs.recencyTimestamp != nil, rhs.recencyTimestamp == nil {
                    return true
                }
                if lhs.recencyTimestamp == nil, rhs.recencyTimestamp != nil {
                    return false
                }
                if lhs.primary != rhs.primary {
                    return lhs.primary < rhs.primary
                }
                if lhs.secondary != rhs.secondary {
                    return lhs.secondary < rhs.secondary
                }
                if lhs.tertiary != rhs.tertiary {
                    return lhs.tertiary < rhs.tertiary
                }
                return lhs.index < rhs.index
            }
            .map(\.row)
    }

    static func pendingSuggestionCount(in snapshot: CustomVocabularySnapshot) -> Int {
        snapshot.pendingSuggestions.count
    }

    static func savedEntryCount(in snapshot: CustomVocabularySnapshot) -> Int {
        snapshot.manualEntries.count + snapshot.shortcutEntries.count + snapshot.learnedRules.count
    }

    private static func normalizedKey(_ value: String) -> String {
        CustomVocabularyManager.normalizedLookupKey(value)
    }
}

@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Layout {
        static let contentWidth: CGFloat = 620
        static let contentHeight: CGFloat = 720
        static let rowHeight: CGFloat = 24
        static let typeColumnWidth: CGFloat = 112
        static let contentColumnWidth: CGFloat = 183
        static let actionColumnWidth: CGFloat = 78
        static let contentInset: CGFloat = 16
        static let cardContentInset: CGFloat = 16
        static let tableMinHeight: CGFloat = 332
        static let inputHeaderSpacing: CGFloat = 4
        static let inputToFieldSpacing: CGFloat = 10
        static let reviewToSeparatorSpacing: CGFloat = 6
        static let separatorToColumnsSpacing: CGFloat = 6
        static let columnsToTableSpacing: CGFloat = 6
    }

    private enum TableColumn {
        static let type = NSUserInterfaceItemIdentifier("type")
        static let original = NSUserInterfaceItemIdentifier("original")
        static let replacement = NSUserInterfaceItemIdentifier("replacement")
        static let actions = NSUserInterfaceItemIdentifier("actions")
    }

    private struct EditingContext {
        let kind: VocabularyRowKind
        let sourceText: String
        let replacementText: String
    }

    private enum EditInputError: LocalizedError {
        case invalidCorrectionPair

        var errorDescription: String? {
            switch self {
            case .invalidCorrectionPair:
                return "Enter a correction as `target, source` (or `target, source1, source2`) or `source => target`."
            }
        }
    }

    private let inputTextField = NSTextField(frame: .zero)
    private let addButton = NSButton(frame: .zero)
    private let vocabularyTableView = NSTableView(frame: .zero)
    private let tableScrollView = NSScrollView(frame: .zero)
    private let tableSummaryLabel = NSTextField(labelWithString: "0 pending, 0 saved")
    private let emptyStateTitleLabel = NSTextField(labelWithString: "No vocabulary yet")
    private let emptyStateDetailLabel = NSTextField(
        wrappingLabelWithString: "Add the spelling you want, then the words or phrases you usually say.\nSuggestions will also appear here when VoiceClutch learns from your edits."
    )
    private lazy var emptyStateView = makeEmptyStateView()
    private var rows: [VocabularyListRow] = []
    private var vocabularyDidChangeObserver: NSObjectProtocol?
    private var editingContext: EditingContext?
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.contentWidth, height: Layout.contentHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vocabulary"
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        setupContent()
        observeVocabularyChanges()
        reloadFromStore()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        reloadFromStore()
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputTextField)
    }

    func presentAsSheet(on parentWindow: NSWindow) {
        reloadFromStore()
        guard let window else { return }

        if let sheetParent = window.sheetParent {
            if sheetParent === parentWindow {
                window.makeFirstResponder(inputTextField)
                return
            }
            sheetParent.endSheet(window)
        }

        parentWindow.beginSheet(window)
        window.makeFirstResponder(inputTextField)
    }

    private func setupContent() {
        guard let window else { return }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: Layout.contentWidth, height: Layout.contentHeight))

        let panel = NSVisualEffectView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        applyLiquidStyle(
            panel,
            overlayColor: backgroundColor(),
            cornerRadius: 0,
            material: .windowBackground,
            blendingMode: .withinWindow
        )

        let inputCard = makeInputCard()
        let tableCard = makeTableCard()
        inputCard.setContentHuggingPriority(.required, for: .vertical)
        inputCard.setContentCompressionResistancePriority(.required, for: .vertical)
        tableCard.setContentHuggingPriority(.defaultLow, for: .vertical)
        tableCard.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let contentStack = NSStackView(views: [inputCard, tableCard])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 12

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded

        let importButton = makeFooterLinkButton(title: "Import", action: #selector(importVocabulary))
        let exportButton = makeFooterLinkButton(title: "Export", action: #selector(exportVocabulary))
        let footerLinksStack = NSStackView(views: [importButton, exportButton])
        footerLinksStack.translatesAutoresizingMaskIntoConstraints = false
        footerLinksStack.orientation = .horizontal
        footerLinksStack.alignment = .centerY
        footerLinksStack.spacing = 12
        footerLinksStack.setContentHuggingPriority(.required, for: .horizontal)
        footerLinksStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentView.addSubview(panel)
        panel.addSubview(contentStack)
        panel.addSubview(footerLinksStack)
        panel.addSubview(doneButton)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: contentView.topAnchor),
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: Layout.contentInset),
            contentStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Layout.contentInset),
            contentStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -Layout.contentInset),
            contentStack.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -12),

            inputCard.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            inputCard.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            tableCard.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            tableCard.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),

            footerLinksStack.leadingAnchor.constraint(
                equalTo: contentStack.leadingAnchor,
                constant: Layout.cardContentInset
            ),
            footerLinksStack.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            footerLinksStack.trailingAnchor.constraint(lessThanOrEqualTo: doneButton.leadingAnchor, constant: -12),

            doneButton.trailingAnchor.constraint(
                equalTo: contentStack.trailingAnchor,
                constant: -Layout.cardContentInset
            ),
            doneButton.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12)
        ])

        window.contentView = contentView
        let fixedContentSize = NSSize(width: Layout.contentWidth, height: Layout.contentHeight)
        window.setContentSize(fixedContentSize)
        window.contentMinSize = fixedContentSize
        window.contentMaxSize = fixedContentSize
    }

    private func makeInputCard() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Add vocabulary")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .left

        let detailLabel = NSTextField(
            wrappingLabelWithString: "Type the spelling you want first, then the words or phrases you usually say, separated by commas."
        )
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.alignment = .left

        inputTextField.translatesAutoresizingMaskIntoConstraints = false
        inputTextField.placeholderString = "VoiceClutch, voice clutch, voiceclutch"
        inputTextField.font = NSFont.systemFont(ofSize: 12)
        inputTextField.target = self
        inputTextField.action = #selector(addVocabularyEntry)

        addButton.title = "Add"
        addButton.target = self
        addButton.action = #selector(addVocabularyEntry)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let inputRow = NSStackView(views: [inputTextField, addButton])
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleLabel)
        content.addSubview(detailLabel)
        content.addSubview(inputRow)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Layout.inputHeaderSpacing),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            inputRow.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: Layout.inputToFieldSpacing),
            inputRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inputRow.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        return makeCard(containing: content)
    }

    private func makeTableCard() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Review vocabulary")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .left

        tableSummaryLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        tableSummaryLabel.textColor = .secondaryLabelColor
        tableSummaryLabel.alignment = .right

        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(titleLabel)
        titleRow.addSubview(tableSummaryLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        tableSummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: titleRow.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: titleRow.bottomAnchor),

            tableSummaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            tableSummaryLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            tableSummaryLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        ])

        let columnHeaderRow = makeColumnHeaderRow()
        let tableContainer = makeTableContainer()
        let headerSeparator = NSView()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.wantsLayer = true
        headerSeparator.layer?.backgroundColor = settingsSeparatorColor().cgColor

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        columnHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleRow)
        content.addSubview(headerSeparator)
        content.addSubview(columnHeaderRow)
        content.addSubview(tableContainer)

        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: content.topAnchor),
            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            headerSeparator.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: Layout.reviewToSeparatorSpacing),
            headerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1 / max(NSScreen.main?.backingScaleFactor ?? 2, 1)),

            columnHeaderRow.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: Layout.separatorToColumnsSpacing),
            columnHeaderRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            columnHeaderRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            tableContainer.topAnchor.constraint(equalTo: columnHeaderRow.bottomAnchor, constant: Layout.columnsToTableSpacing),
            tableContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tableContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tableContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        return makeCard(containing: content)
    }

    private func makeColumnHeaderRow() -> NSView {
        let typeContainer = makeColumnHeaderContainer(text: "Type")
        typeContainer.widthAnchor.constraint(equalToConstant: Layout.typeColumnWidth).isActive = true

        let replacementContainer = makeColumnHeaderContainer(text: "I want to see")
        replacementContainer.widthAnchor.constraint(equalToConstant: Layout.contentColumnWidth).isActive = true
        let sourceContainer = makeColumnHeaderContainer(text: "When I say")
        sourceContainer.widthAnchor.constraint(equalToConstant: Layout.contentColumnWidth).isActive = true
        let actionsContainer = makeColumnHeaderContainer(text: "Actions", alignment: .right)
        actionsContainer.widthAnchor.constraint(equalToConstant: Layout.actionColumnWidth).isActive = true

        let stack = NSStackView(views: [typeContainer, replacementContainer, sourceContainer, actionsContainer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 0
        stack.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return stack
    }

    private func makeColumnHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeColumnHeaderContainer(text: String, alignment: NSTextAlignment = .left) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = makeColumnHeaderLabel(text)
        label.alignment = alignment
        container.addSubview(label)

        if alignment == .right {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -VocabularyWindowMetrics.actionInset),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
        } else {
            let leadingInset = text == "Type" ? VocabularyWindowMetrics.typeInset : VocabularyWindowMetrics.textInset
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -VocabularyWindowMetrics.textInset),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
        }

        return container
    }

    private func makeTableContainer() -> NSView {
        configureTableView()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.tableMinHeight).isActive = true
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
        container.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.borderType = .noBorder
        tableScrollView.drawsBackground = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = false
        tableScrollView.autohidesScrollers = true
        tableScrollView.scrollerStyle = .overlay
        tableScrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tableScrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        if #available(macOS 11.0, *) {
            tableScrollView.automaticallyAdjustsContentInsets = false
        }
        tableScrollView.documentView = vocabularyTableView

        container.addSubview(tableScrollView)
        container.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            tableScrollView.topAnchor.constraint(equalTo: container.topAnchor),
            tableScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyStateView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func configureTableView() {
        vocabularyTableView.translatesAutoresizingMaskIntoConstraints = false
        vocabularyTableView.headerView = nil
        if #available(macOS 11.0, *) {
            vocabularyTableView.style = .fullWidth
        }
        vocabularyTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        vocabularyTableView.usesAlternatingRowBackgroundColors = false
        vocabularyTableView.backgroundColor = .clear
        vocabularyTableView.gridStyleMask = []
        vocabularyTableView.rowHeight = Layout.rowHeight
        vocabularyTableView.intercellSpacing = NSSize(width: 0, height: 1)
        vocabularyTableView.selectionHighlightStyle = .none
        vocabularyTableView.delegate = self
        vocabularyTableView.dataSource = self
        vocabularyTableView.allowsEmptySelection = true
        vocabularyTableView.allowsTypeSelect = false

        if vocabularyTableView.tableColumns.isEmpty {
            let typeColumn = NSTableColumn(identifier: TableColumn.type)
            typeColumn.width = Layout.typeColumnWidth
            typeColumn.minWidth = Layout.typeColumnWidth
            typeColumn.maxWidth = Layout.typeColumnWidth

            let originalColumn = NSTableColumn(identifier: TableColumn.original)
            originalColumn.width = Layout.contentColumnWidth
            originalColumn.minWidth = Layout.contentColumnWidth
            originalColumn.maxWidth = Layout.contentColumnWidth

            let replacementColumn = NSTableColumn(identifier: TableColumn.replacement)
            replacementColumn.width = Layout.contentColumnWidth
            replacementColumn.minWidth = Layout.contentColumnWidth
            replacementColumn.maxWidth = Layout.contentColumnWidth

            let actionsColumn = NSTableColumn(identifier: TableColumn.actions)
            actionsColumn.width = Layout.actionColumnWidth
            actionsColumn.minWidth = Layout.actionColumnWidth
            actionsColumn.maxWidth = Layout.actionColumnWidth

            vocabularyTableView.addTableColumn(typeColumn)
            vocabularyTableView.addTableColumn(originalColumn)
            vocabularyTableView.addTableColumn(replacementColumn)
            vocabularyTableView.addTableColumn(actionsColumn)
        }
    }

    private func makeEmptyStateView() -> NSView {
        emptyStateTitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        emptyStateTitleLabel.alignment = .center

        emptyStateDetailLabel.font = NSFont.systemFont(ofSize: 12)
        emptyStateDetailLabel.textColor = .secondaryLabelColor
        emptyStateDetailLabel.maximumNumberOfLines = 3
        emptyStateDetailLabel.lineBreakMode = .byWordWrapping
        emptyStateDetailLabel.alignment = .center

        let stack = NSStackView(views: [emptyStateTitleLabel, emptyStateDetailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.isHidden = true
        return stack
    }

    private func makeCard(containing content: NSView) -> NSView {
        let card = NSVisualEffectView()
        card.translatesAutoresizingMaskIntoConstraints = false
        applyLiquidStyle(
            card,
            overlayColor: settingsCardBackgroundColor(),
            cornerRadius: 12,
            material: .hudWindow,
            blendingMode: .withinWindow
        )

        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Layout.cardContentInset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Layout.cardContentInset),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])

        return card
    }

    private func observeVocabularyChanges() {
        vocabularyDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .customVocabularyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromStore()
            }
        }
    }

    private func reloadFromStore() {
        applySnapshot(CustomVocabularyManager.shared.snapshot())
    }

    private func applySnapshot(_ snapshot: CustomVocabularySnapshot) {
        rows = VocabularyListBuilder.rows(from: snapshot)
        tableSummaryLabel.stringValue = tableSummaryText(for: snapshot)
        vocabularyTableView.reloadData()
        updateEmptyStateVisibility()
    }

    private func updateEmptyStateVisibility() {
        let isEmpty = rows.isEmpty
        emptyStateView.isHidden = !isEmpty
        tableScrollView.isHidden = isEmpty
    }

    @objc private func addVocabularyEntry() {
        let inputText = inputTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputText.isEmpty else { return }
        let isEditing = editingContext != nil

        do {
            if let editingContext {
                try replaceEntry(editingContext, with: inputText)
                self.editingContext = nil
                addButton.title = "Add"
            } else {
                try applyVocabularyInput(inputText)
            }

            inputTextField.stringValue = ""
            reloadFromStore()
            window?.makeFirstResponder(inputTextField)
        } catch {
            presentAlert(
                messageText: isEditing
                    ? "Couldn't save this vocabulary entry"
                    : "Couldn't add this vocabulary entry",
                informativeText: "Check the entry and try again.\n\n\(error.localizedDescription)"
            )
        }
    }

    private func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]

        do {
            if let editingContext, editingContext.kind == row.kind {
                self.editingContext = nil
                addButton.title = "Add"
            }
            try removeEntry(for: row.kind)
            reloadFromStore()
        } catch {
            presentAlert(
                messageText: "Couldn't remove this vocabulary entry",
                informativeText: error.localizedDescription
            )
        }
    }

    private func approveSuggestion(at index: Int) {
        guard rows.indices.contains(index) else { return }
        guard case .suggestion(let id) = rows[index].kind else { return }

        do {
            _ = try CustomVocabularyManager.shared.approveLLMSuggestion(id: id)
            reloadFromStore()
        } catch {
            presentAlert(
                messageText: "Couldn't save this suggestion",
                informativeText: error.localizedDescription
            )
        }
    }

    private func presentAlert(messageText: String, informativeText: String) {
        presentAlert(messageText: messageText, informativeText: informativeText, style: .warning)
    }

    private func presentAlert(messageText: String, informativeText: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        guard let window else { return }
        alert.beginSheetModal(for: window)
    }

    private func makeFooterLinkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .linkColor
        button.setButtonType(.momentaryPushIn)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: titleAttributes)
        return button
    }

    @objc private func importVocabulary() {
        guard let window else { return }

        let openPanel = NSOpenPanel()
        openPanel.title = "Import Vocabulary"
        openPanel.message = "Choose a VoiceClutch vocabulary JSON file."
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.resolvesAliases = true
        if #available(macOS 11.0, *) {
            openPanel.allowedContentTypes = [.json]
        } else {
            openPanel.allowedFileTypes = ["json"]
        }

        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let selectedURL = openPanel.url else { return }
            self.performImport(from: selectedURL)
        }
    }

    @objc private func exportVocabulary() {
        guard let window else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Vocabulary"
        savePanel.message = "Save your VoiceClutch vocabulary as a JSON file."
        savePanel.nameFieldStringValue = "voiceclutch-vocabulary.json"
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        if #available(macOS 11.0, *) {
            savePanel.allowedContentTypes = [.json]
        } else {
            savePanel.allowedFileTypes = ["json"]
        }

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let destinationURL = savePanel.url else { return }
            self.performExport(to: destinationURL)
        }
    }

    private func performImport(from fileURL: URL) {
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try CustomVocabularyManager.shared.importPortableVocabulary(data)
            applySnapshot(snapshot)
            presentAlert(
                messageText: "Vocabulary imported",
                informativeText: "Loaded \(snapshot.manualEntries.count) manual, \(snapshot.shortcutEntries.count) shortcut, and \(snapshot.learnedRules.count) learned entries.",
                style: .informational
            )
        } catch {
            presentAlert(
                messageText: "Couldn't import vocabulary",
                informativeText: "Check the file and try again.\n\n\(error.localizedDescription)"
            )
        }
    }

    private func performExport(to fileURL: URL) {
        do {
            let data = try CustomVocabularyManager.shared.exportPortableVocabulary()
            try data.write(to: fileURL, options: .atomic)
            presentAlert(
                messageText: "Vocabulary exported",
                informativeText: "Saved to:\n\(fileURL.path)",
                style: .informational
            )
        } catch {
            presentAlert(
                messageText: "Couldn't export vocabulary",
                informativeText: "Try a different location and try again.\n\n\(error.localizedDescription)"
            )
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Layout.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard rows.indices.contains(row) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("VocabularyRowView")
        let rowView: VocabularyTableRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? VocabularyTableRowView {
            rowView = reused
        } else {
            rowView = VocabularyTableRowView()
            rowView.identifier = identifier
        }

        rowView.separatorColor = settingsSeparatorColor()
        rowView.highlightColor = nil
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let rowData = rows[row]

        switch tableColumn.identifier {
        case TableColumn.type:
            return makeBadgeCell(for: rowData)
        case TableColumn.original:
            return makeTextCell(
                identifier: tableColumn.identifier,
                text: rowData.replacementText,
                font: NSFont.systemFont(ofSize: 11, weight: .medium)
            )
        case TableColumn.replacement:
            return makeTextCell(
                identifier: tableColumn.identifier,
                text: rowData.sourceText,
                font: NSFont.systemFont(ofSize: 11)
            )
        case TableColumn.actions:
            return makeActionsCell(for: rowData, at: row, identifier: tableColumn.identifier)
        default:
            return nil
        }
    }

    private func makeBadgeCell(for row: VocabularyListRow) -> NSView {
        let identifier = TableColumn.type
        let cellView: VocabularyBadgeCellView
        if let reused = vocabularyTableView.makeView(withIdentifier: identifier, owner: self) as? VocabularyBadgeCellView {
            cellView = reused
        } else {
            cellView = VocabularyBadgeCellView()
            cellView.identifier = identifier
        }
        cellView.configure(text: row.badgeText, palette: badgePalette(for: row.badgeStyle))
        return cellView
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier, text: String, font: NSFont) -> NSView {
        let cellView: VocabularyTextCellView
        if let reused = vocabularyTableView.makeView(withIdentifier: identifier, owner: self) as? VocabularyTextCellView {
            cellView = reused
        } else {
            cellView = VocabularyTextCellView()
            cellView.identifier = identifier
        }
        cellView.configure(text: text, font: font)
        return cellView
    }

    private func makeActionsCell(for row: VocabularyListRow, at index: Int, identifier: NSUserInterfaceItemIdentifier) -> NSView {
        let cellView = NSView(frame: .zero)
        cellView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8

        switch row.kind {
        case .suggestion:
            let approveButton = makeActionButton(
                symbolName: "checkmark.circle.fill",
                color: .systemGreen,
                toolTip: "Save suggestion"
            ) {
                self.approveSuggestion(at: index)
            }
            let dismissButton = makeActionButton(
                symbolName: "xmark.circle.fill",
                color: .secondaryLabelColor,
                toolTip: "Dismiss suggestion"
            ) {
                self.removeRow(at: index)
            }
            stackView.addArrangedSubview(approveButton)
            stackView.addArrangedSubview(dismissButton)

        case .manual, .shortcut, .learned:
            let editButton = makeActionButton(
                symbolName: "pencil.tip.crop.circle.fill",
                color: .systemBlue,
                toolTip: "Edit"
            ) {
                self.beginEditingRow(at: index)
            }
            let removeButton = makeActionButton(
                symbolName: "xmark.circle.fill",
                color: .secondaryLabelColor,
                toolTip: "Remove"
            ) {
                self.removeRow(at: index)
            }
            stackView.addArrangedSubview(editButton)
            stackView.addArrangedSubview(removeButton)
        }

        cellView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.trailingAnchor.constraint(
                equalTo: cellView.trailingAnchor,
                constant: -VocabularyWindowMetrics.actionButtonTrailingInset
            ),
            stackView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        cellView.identifier = identifier
        return cellView
    }

    private func makeActionButton(
        symbolName: String,
        color: NSColor,
        toolTip: String,
        size: CGFloat = 18,
        action: @escaping () -> Void
    ) -> NSButton {
        let button = VocabularyActionButton(action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.contentTintColor = color
        button.toolTip = toolTip
        if #available(macOS 10.10, *) {
            button.setAccessibilityLabel(toolTip)
        }
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true

        return button
    }

    @objc private func closeWindow() {
        guard let window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
            return
        }
        close()
    }

    private func tableSummaryText(for snapshot: CustomVocabularySnapshot) -> String {
        let pending = VocabularyListBuilder.pendingSuggestionCount(in: snapshot)
        let saved = VocabularyListBuilder.savedEntryCount(in: snapshot)
        return "\(pending) pending, \(saved) saved"
    }

    private func beginEditingRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        switch row.kind {
        case .suggestion:
            return
        case .manual, .shortcut, .learned:
            let context = EditingContext(
                kind: row.kind,
                sourceText: row.sourceText,
                replacementText: row.replacementText
            )
            editingContext = context
            addButton.title = "Save"
            inputTextField.stringValue = editableInputText(for: context)
            window?.makeFirstResponder(inputTextField)
            inputTextField.selectText(nil)
        }
    }

    private func editableInputText(for context: EditingContext) -> String {
        let normalizedSource = CustomVocabularyManager.normalizedLookupKey(context.sourceText)
        let normalizedReplacement = CustomVocabularyManager.normalizedLookupKey(context.replacementText)

        switch context.kind {
        case .manual:
            if normalizedSource == normalizedReplacement {
                return context.replacementText
            }
            return "\(context.replacementText), \(context.sourceText)"
        case .shortcut, .learned:
            return "\(context.replacementText), \(context.sourceText)"
        case .suggestion:
            return ""
        }
    }

    private func applyVocabularyInput(_ inputText: String) throws {
        if inputText.contains("=>") {
            _ = try CustomVocabularyManager.shared.addShortcutEntry(from: inputText)
            return
        }

        let parts = inputText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if parts.count == 1 {
            _ = try CustomVocabularyManager.shared.addManualEntry(from: parts[0])
            return
        }

        if parts.count >= 2 {
            let canonical = parts[0]
            let aliases = Array(parts[1...])
            _ = try CustomVocabularyManager.shared.addManualRule(
                originalText: aliases.joined(separator: ", "),
                replacementText: canonical
            )
        }
    }

    private func replaceEntry(_ context: EditingContext, with inputText: String) throws {
        try applyEditedVocabularyInput(inputText, context: context)
    }

    private func applyEditedVocabularyInput(
        _ inputText: String,
        context: EditingContext
    ) throws {
        switch context.kind {
        case .suggestion:
            try applyVocabularyInput(inputText)

        case .manual(let canonical):
            let (updatedCanonical, aliases) = try parseManualAliasInput(inputText)
            _ = try CustomVocabularyManager.shared.updateManualEntry(
                existingCanonical: canonical,
                canonical: updatedCanonical,
                aliases: aliases
            )

        case .shortcut(let id):
            let (source, target) = try parseCorrectionPairInput(inputText)
            _ = try CustomVocabularyManager.shared.updateShortcutEntry(
                id: id,
                trigger: source,
                replacement: target
            )

        case .learned(let id):
            let (source, target) = try parseCorrectionPairInput(inputText)
            _ = try CustomVocabularyManager.shared.updateLearnedRule(
                id: id,
                source: source,
                target: target
            )
        }
    }

    private func parseManualAliasInput(_ inputText: String) throws -> (canonical: String, aliases: [String]) {
        if inputText.contains("=>") {
            throw CustomVocabularyError.invalidManualEntry
        }

        let parts = inputText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let canonical = parts.first else {
            throw CustomVocabularyError.invalidManualEntry
        }
        return (canonical: canonical, aliases: Array(parts.dropFirst()))
    }

    private func parseCorrectionPairInput(_ inputText: String) throws -> (source: String, target: String) {
        if inputText.contains("=>") {
            let components = inputText.components(separatedBy: "=>")
            guard components.count == 2 else {
                throw EditInputError.invalidCorrectionPair
            }
            let source = CustomVocabularyManager.sanitizedTerm(components[0])
            let target = CustomVocabularyManager.sanitizedTerm(components[1])
            guard !source.isEmpty, !target.isEmpty else {
                throw EditInputError.invalidCorrectionPair
            }
            return (source: source, target: target)
        }

        let parts = inputText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { CustomVocabularyManager.sanitizedTerm(String($0)) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            throw EditInputError.invalidCorrectionPair
        }

        let target = parts[0]
        let source = parts.dropFirst().joined(separator: ", ")
        return (source: source, target: target)
    }

    private func removeEntry(for kind: VocabularyRowKind) throws {
        switch kind {
        case .suggestion(let id):
            _ = try CustomVocabularyManager.shared.dismissLLMSuggestion(id: id)
        case .manual(let canonical):
            _ = try CustomVocabularyManager.shared.removeManualEntry(canonical: canonical)
        case .shortcut(let id):
            _ = try CustomVocabularyManager.shared.removeShortcutEntry(id: id)
        case .learned(let id):
            _ = try CustomVocabularyManager.shared.removeLearnedRule(id: id)
        }
    }

    private func badgePalette(for style: VocabularyBadgeStyle) -> VocabularyBadgePalette {
        switch style {
        case .suggestion:
            return VocabularyBadgePalette(
                textColor: .systemGreen,
                fillColor: NSColor.systemGreen.withAlphaComponent(0.16)
            )
        case .manual:
            return VocabularyBadgePalette(
                textColor: .systemBlue,
                fillColor: NSColor.systemBlue.withAlphaComponent(0.16)
            )
        case .shortcut:
            return VocabularyBadgePalette(
                textColor: .systemPurple,
                fillColor: NSColor.systemPurple.withAlphaComponent(0.16)
            )
        case .learned:
            return VocabularyBadgePalette(
                textColor: .systemOrange,
                fillColor: NSColor.systemOrange.withAlphaComponent(0.16)
            )
        }
    }

    private func suggestionHighlightColor() -> NSColor {
        NSColor.systemGreen.withAlphaComponent(0.08)
    }

    private func backgroundColor() -> NSColor {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDarkMode
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.82)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.9)
    }

    private func settingsCardBackgroundColor() -> NSColor {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDarkMode {
            return NSColor.white.withAlphaComponent(0.035)
        }
        return NSColor.black.withAlphaComponent(0.04)
    }

    private func settingsSeparatorColor() -> NSColor {
        NSColor.separatorColor.withAlphaComponent(0.1)
    }

    private func applyLiquidStyle(
        _ effectView: NSVisualEffectView,
        overlayColor: NSColor,
        cornerRadius: CGFloat,
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode
    ) {
        effectView.material = material
        effectView.state = .active
        effectView.blendingMode = blendingMode
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = overlayColor.cgColor
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = cornerRadius > 0
    }
}

private struct VocabularyBadgePalette {
    let textColor: NSColor
    let fillColor: NSColor
}

private final class VocabularyBadgeCellView: NSTableCellView {
    private let badgeBackgroundView = NSView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let leadingConstraintInset = VocabularyWindowMetrics.typeInset + VocabularyWindowMetrics.cellLeadingCompensation

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, palette: VocabularyBadgePalette) {
        titleLabel.stringValue = text
        titleLabel.textColor = palette.textColor
        badgeBackgroundView.layer?.backgroundColor = palette.fillColor.cgColor
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        badgeBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        badgeBackgroundView.wantsLayer = true
        badgeBackgroundView.layer?.cornerRadius = 7

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.alignment = .center

        addSubview(badgeBackgroundView)
        badgeBackgroundView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            badgeBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingConstraintInset),
            badgeBackgroundView.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: badgeBackgroundView.leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: badgeBackgroundView.trailingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: badgeBackgroundView.topAnchor, constant: 2),
            titleLabel.bottomAnchor.constraint(equalTo: badgeBackgroundView.bottomAnchor, constant: -2)
        ])
    }
}

private final class VocabularyTextCellView: NSTableCellView {
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, font: NSFont) {
        valueLabel.stringValue = text
        valueLabel.font = font
        valueLabel.toolTip = text
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.usesSingleLineMode = true

        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: VocabularyWindowMetrics.textInset + VocabularyWindowMetrics.cellLeadingCompensation
            ),
            valueLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -VocabularyWindowMetrics.textInset
            ),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class VocabularyTableRowView: NSTableRowView {
    var highlightColor: NSColor?
    var separatorColor: NSColor?

    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        if let highlightColor {
            highlightColor.setFill()
            let insetRect = bounds.insetBy(dx: 2, dy: 1)
            let path = NSBezierPath(roundedRect: insetRect, xRadius: 8, yRadius: 8)
            path.fill()
        }

        if let separatorColor {
            separatorColor.setFill()
            let separatorRect = NSRect(x: 0, y: 0, width: bounds.width, height: 1 / max(NSScreen.main?.backingScaleFactor ?? 2, 1))
            separatorRect.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
    }
}

private final class VocabularyActionButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(runAction)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runAction() {
        handler()
    }
}
