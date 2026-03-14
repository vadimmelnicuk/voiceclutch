import AppKit

@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Layout {
        static let contentWidth: CGFloat = 580
        static let contentHeight: CGFloat = 540
        static let listHeight: CGFloat = 300
    }

    private enum TableColumn {
        static let source = NSUserInterfaceItemIdentifier("source")
        static let original = NSUserInterfaceItemIdentifier("original")
        static let replacement = NSUserInterfaceItemIdentifier("replacement")
    }

    private enum RowKind {
        case manual
        case shortcut
        case learned(UUID)
    }

    private struct VocabularyListRow {
        let kind: RowKind
        let source: String
        let original: String
        let replacement: String
        let sortKey: String
    }

    private let inputTextField = NSTextField(frame: .zero)
    private let replacementTextField = NSTextField(frame: .zero)
    private let vocabularyTableView = NSTableView(frame: .zero)
    private let removeSelectedLearnedButton = NSButton(title: "Remove Selected", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var listRows: [VocabularyListRow] = []
    private var vocabularyDidChangeObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.contentWidth, height: Layout.contentHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Custom Vocabulary"
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
        statusLabel.stringValue = ""
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputTextField)
    }

    func presentAsSheet(on parentWindow: NSWindow) {
        reloadFromStore()
        statusLabel.stringValue = ""
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

        let introLabel = NSTextField(
            wrappingLabelWithString: "Use `canonical` or `canonical: alias1, alias2` for terms, or use `original => replacement` / Original+Replacement fields for shortcuts. Learned corrections activate after 1 match."
        )
        introLabel.translatesAutoresizingMaskIntoConstraints = false
        introLabel.font = NSFont.systemFont(ofSize: 12)
        introLabel.textColor = .secondaryLabelColor
        introLabel.maximumNumberOfLines = 4

        inputTextField.translatesAutoresizingMaskIntoConstraints = false
        inputTextField.placeholderString = "Term or original text"
        inputTextField.font = NSFont.systemFont(ofSize: 12)
        inputTextField.target = self
        inputTextField.action = #selector(addVocabularyRule)

        let arrowLabel = NSTextField(labelWithString: "\u{2192}")
        arrowLabel.translatesAutoresizingMaskIntoConstraints = false
        arrowLabel.textColor = .secondaryLabelColor
        arrowLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        arrowLabel.setContentHuggingPriority(.required, for: .horizontal)

        replacementTextField.translatesAutoresizingMaskIntoConstraints = false
        replacementTextField.placeholderString = "Replacement (optional)"
        replacementTextField.font = NSFont.systemFont(ofSize: 12)
        replacementTextField.target = self
        replacementTextField.action = #selector(addVocabularyRule)

        let addButton = NSButton(title: "Add", target: self, action: #selector(addVocabularyRule))
        addButton.bezelStyle = .rounded
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        let inputRow = NSStackView(views: [inputTextField, arrowLabel, replacementTextField, addButton])
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10

        NSLayoutConstraint.activate([
            inputTextField.widthAnchor.constraint(equalTo: replacementTextField.widthAnchor),
        ])

        let tableScrollView = makeTableScrollView(height: Layout.listHeight)

        removeSelectedLearnedButton.target = self
        removeSelectedLearnedButton.action = #selector(removeSelectedLearnedRule)
        removeSelectedLearnedButton.bezelStyle = .rounded
        removeSelectedLearnedButton.isEnabled = false
        removeSelectedLearnedButton.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(title: "Clear Learned", target: self, action: #selector(clearLearnedRules))
        clearButton.bezelStyle = .rounded

        let actionRow = NSStackView(views: [removeSelectedLearnedButton, clearButton])
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let vocabularyContent = NSStackView(views: [inputRow, tableScrollView])
        vocabularyContent.translatesAutoresizingMaskIntoConstraints = false
        vocabularyContent.orientation = .vertical
        vocabularyContent.alignment = .width
        vocabularyContent.spacing = 10

        let vocabularySection = makeSection(
            title: "Vocabulary List",
            detail: "Manual terms, shortcuts, and learned corrections are combined here.",
            content: vocabularyContent,
            actionView: actionRow
        )

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = ""

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let stackView = NSStackView(views: [
            introLabel,
            vocabularySection,
            statusLabel,
        ])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.distribution = .fill
        stackView.spacing = 10

        contentView.addSubview(panel)
        panel.addSubview(stackView)
        panel.addSubview(doneButton)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: contentView.topAnchor),
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),

            doneButton.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
            doneButton.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        ])

        window.contentView = contentView
        window.setContentSize(NSSize(width: Layout.contentWidth, height: Layout.contentHeight))
    }

    private func makeTableScrollView(height: CGFloat) -> NSScrollView {
        vocabularyTableView.translatesAutoresizingMaskIntoConstraints = false
        vocabularyTableView.headerView = NSTableHeaderView()
        vocabularyTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        vocabularyTableView.usesAlternatingRowBackgroundColors = false
        vocabularyTableView.backgroundColor = .clear
        vocabularyTableView.gridStyleMask = []
        vocabularyTableView.rowHeight = 26
        vocabularyTableView.intercellSpacing = NSSize(width: 6, height: 2)
        vocabularyTableView.selectionHighlightStyle = .regular
        vocabularyTableView.delegate = self
        vocabularyTableView.dataSource = self
        vocabularyTableView.allowsEmptySelection = true

        let sourceColumn = NSTableColumn(identifier: TableColumn.source)
        sourceColumn.title = "Source"
        sourceColumn.width = 130
        sourceColumn.minWidth = 110
        sourceColumn.maxWidth = 150

        let originalColumn = NSTableColumn(identifier: TableColumn.original)
        originalColumn.title = "Original"
        originalColumn.width = 200
        originalColumn.minWidth = 160
        originalColumn.resizingMask = .autoresizingMask

        let replacementColumn = NSTableColumn(identifier: TableColumn.replacement)
        replacementColumn.title = "Replacement"
        replacementColumn.width = 200
        replacementColumn.minWidth = 160
        replacementColumn.resizingMask = .autoresizingMask

        vocabularyTableView.addTableColumn(sourceColumn)
        vocabularyTableView.addTableColumn(originalColumn)
        vocabularyTableView.addTableColumn(replacementColumn)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = vocabularyTableView
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scrollView
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
        let snapshot = CustomVocabularyManager.shared.snapshot()
        listRows = combinedVocabularyRows(from: snapshot)
        vocabularyTableView.reloadData()
        syncRemoveButtonState()
    }

    private func combinedVocabularyRows(from snapshot: CustomVocabularySnapshot) -> [VocabularyListRow] {
        var rows: [VocabularyListRow] = snapshot.manualEntries.map { entry in
            let original = entry.aliases.isEmpty ? entry.canonical : entry.aliases.joined(separator: ", ")
            return VocabularyListRow(
                kind: .manual,
                source: "Manual",
                original: original,
                replacement: entry.canonical,
                sortKey: "0|" + CustomVocabularyManager.normalizedLookupKey(entry.canonical) + "|" + CustomVocabularyManager.normalizedLookupKey(original)
            )
        }

        rows += snapshot.shortcutEntries.map { entry in
            VocabularyListRow(
                kind: .shortcut,
                source: "Shortcut",
                original: entry.trigger,
                replacement: entry.replacement,
                sortKey: "1|" + CustomVocabularyManager.normalizedLookupKey(entry.replacement) + "|" + CustomVocabularyManager.normalizedLookupKey(entry.trigger)
            )
        }

        rows += snapshot.learnedRules.map { rule in
            let status = rule.isPromoted ? "active" : "pending"
            return VocabularyListRow(
                kind: .learned(rule.id),
                source: "Learned \(status) \(rule.count)x",
                original: rule.source,
                replacement: rule.target,
                sortKey: "2|" + CustomVocabularyManager.normalizedLookupKey(rule.target) + "|" + CustomVocabularyManager.normalizedLookupKey(rule.source)
            )
        }

        return rows.sorted { $0.sortKey < $1.sortKey }
    }

    private func makeSection(
        title: String,
        detail: String,
        content: NSView,
        actionView: NSView
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        let headerTextStack = NSStackView(views: [titleLabel, detailLabel])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 2
        headerTextStack.translatesAutoresizingMaskIntoConstraints = false

        actionView.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSStackView(views: [headerTextStack, actionView])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let sectionStack = NSStackView(views: [headerRow, content])
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        sectionStack.orientation = .vertical
        sectionStack.alignment = .width
        sectionStack.spacing = 10

        let group = NSVisualEffectView()
        group.translatesAutoresizingMaskIntoConstraints = false
        applyLiquidStyle(
            group,
            overlayColor: cardBackgroundColor(),
            cornerRadius: 12,
            material: .hudWindow,
            blendingMode: .withinWindow
        )
        group.addSubview(sectionStack)

        NSLayoutConstraint.activate([
            sectionStack.topAnchor.constraint(equalTo: group.topAnchor, constant: 14),
            sectionStack.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            sectionStack.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
            sectionStack.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -14),
        ])

        return group
    }

    @objc private func addVocabularyRule() {
        let inputText = inputTextField.stringValue
        let replacementText = replacementTextField.stringValue

        do {
            if replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if inputText.contains("=>") {
                    _ = try CustomVocabularyManager.shared.addShortcutEntry(from: inputText)
                    statusLabel.stringValue = "Shortcut added."
                } else {
                    _ = try CustomVocabularyManager.shared.addManualEntry(from: inputText)
                    statusLabel.stringValue = "Manual vocabulary added."
                }
            } else {
                _ = try CustomVocabularyManager.shared.addManualRule(
                    originalText: inputText,
                    replacementText: replacementText
                )
                statusLabel.stringValue = "Shortcut replacement added."
            }

            inputTextField.stringValue = ""
            replacementTextField.stringValue = ""
            reloadFromStore()
            statusLabel.textColor = .secondaryLabelColor
            window?.makeFirstResponder(inputTextField)
        } catch {
            statusLabel.stringValue = "Failed to add vocabulary entry: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func clearLearnedRules() {
        do {
            _ = try CustomVocabularyManager.shared.clearLearnedRules()
            reloadFromStore()
            statusLabel.stringValue = "Learned corrections cleared."
            statusLabel.textColor = .secondaryLabelColor
        } catch {
            statusLabel.stringValue = "Failed to clear learned corrections: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func removeSelectedLearnedRule() {
        let selectedRow = vocabularyTableView.selectedRow
        guard selectedRow >= 0, selectedRow < listRows.count else {
            statusLabel.stringValue = "Select a learned correction to remove."
            statusLabel.textColor = .systemRed
            return
        }

        guard case .learned(let id) = listRows[selectedRow].kind else {
            statusLabel.stringValue = "Select a learned correction to remove."
            statusLabel.textColor = .systemRed
            return
        }

        do {
            _ = try CustomVocabularyManager.shared.removeLearnedRule(id: id)
            reloadFromStore()
            statusLabel.stringValue = "Learned correction removed."
            statusLabel.textColor = .secondaryLabelColor
        } catch {
            statusLabel.stringValue = "Failed to remove learned correction: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    private func syncRemoveButtonState() {
        let selectedRow = vocabularyTableView.selectedRow
        guard selectedRow >= 0, selectedRow < listRows.count else {
            removeSelectedLearnedButton.isEnabled = false
            return
        }

        if case .learned = listRows[selectedRow].kind {
            removeSelectedLearnedButton.isEnabled = true
        } else {
            removeSelectedLearnedButton.isEnabled = false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        listRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < listRows.count, let tableColumn else { return nil }

        let textField: NSTextField
        let identifier = tableColumn.identifier
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            textField = reused
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.lineBreakMode = .byTruncatingTail
            textField.font = NSFont.systemFont(ofSize: 12)
        }

        let rowData = listRows[row]
        switch identifier {
        case TableColumn.source:
            textField.stringValue = rowData.source
        case TableColumn.original:
            textField.stringValue = rowData.original
        case TableColumn.replacement:
            textField.stringValue = rowData.replacement
        default:
            textField.stringValue = ""
        }

        return textField
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        syncRemoveButtonState()
    }

    @objc private func closeWindow() {
        guard let window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
            return
        }
        close()
    }

    private func backgroundColor() -> NSColor {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDarkMode
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.82)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.9)
    }

    private func cardBackgroundColor() -> NSColor {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDarkMode
            ? NSColor.white.withAlphaComponent(0.035)
            : NSColor.black.withAlphaComponent(0.04)
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
