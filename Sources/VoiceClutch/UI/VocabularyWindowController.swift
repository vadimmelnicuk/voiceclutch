import AppKit

@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let contentWidth: CGFloat = 560
        static let contentHeight: CGFloat = 540
        static let editorHeight: CGFloat = 180
        static let learnedHeight: CGFloat = 120
    }

    private let manualTextView = NSTextView(frame: .zero)
    private let learnedTextView = NSTextView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private var shouldRestoreAccessoryActivationPolicy = false
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
        beginActivationContext()
        guard let window else { return }
        activate(window)
    }

    func windowWillClose(_ notification: Notification) {
        endActivationContext()
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

        let introLabel = NSTextField(wrappingLabelWithString: "Manual entries use one rule per line. Use `canonical` or `canonical: alias1, alias2`. Learned corrections are listed below and apply globally.")
        introLabel.translatesAutoresizingMaskIntoConstraints = false
        introLabel.font = NSFont.systemFont(ofSize: 12)
        introLabel.textColor = .secondaryLabelColor
        introLabel.maximumNumberOfLines = 3

        configureTextView(manualTextView, editable: true)
        let manualScrollView = makeScrollView(for: manualTextView, height: Layout.editorHeight)
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveChanges))
        saveButton.bezelStyle = .rounded
        let manualSection = makeSection(
            title: "Manual Vocabulary",
            detail: "Entries here are used for final-text rewrites and Nemotron biasing when they can be tokenized cleanly.",
            content: manualScrollView,
            actionButton: saveButton
        )

        configureTextView(learnedTextView, editable: false)
        let learnedScrollView = makeScrollView(for: learnedTextView, height: Layout.learnedHeight)
        let clearButton = NSButton(title: "Clear Learned", target: self, action: #selector(clearLearnedRules))
        clearButton.bezelStyle = .rounded
        let learnedSection = makeSection(
            title: "Learned Corrections",
            detail: "VoiceClutch captures simple immediate post-dictation fixes and turns them into active global rewrite rules.",
            content: learnedScrollView,
            actionButton: clearButton
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
            manualSection,
            learnedSection,
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

    private func reloadFromStore() {
        let snapshot = CustomVocabularyManager.shared.snapshot()
        manualTextView.string = snapshot.editorText

        if snapshot.learnedRules.isEmpty {
            learnedTextView.string = "No learned corrections yet."
        } else {
            learnedTextView.string = snapshot.learnedRules.map { rule in
                "\(rule.source) -> \(rule.target) (\(rule.count)x)"
            }.joined(separator: "\n")
        }

        statusLabel.stringValue = ""
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

    private func configureTextView(_ textView: NSTextView, editable: Bool) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.backgroundColor = .clear
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
    }

    private func makeScrollView(for textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scrollView
    }

    private func makeSection(
        title: String,
        detail: String,
        content: NSView,
        actionButton: NSButton
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

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSStackView(views: [headerTextStack, actionButton])
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

    @objc private func saveChanges() {
        do {
            _ = try CustomVocabularyManager.shared.saveEditorText(manualTextView.string)
            statusLabel.stringValue = "Saved."
            statusLabel.textColor = .secondaryLabelColor
            reloadFromStore()
        } catch {
            statusLabel.stringValue = "Failed to save: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func clearLearnedRules() {
        do {
            _ = try CustomVocabularyManager.shared.clearLearnedRules()
            reloadFromStore()
            statusLabel.stringValue = "Learned corrections cleared."
        } catch {
            statusLabel.stringValue = "Failed to clear learned corrections: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func closeWindow() {
        close()
    }

    private func beginActivationContext() {
        guard NSApp.activationPolicy() == .accessory else { return }
        if NSApp.setActivationPolicy(.regular) {
            shouldRestoreAccessoryActivationPolicy = true
        }
    }

    private func endActivationContext() {
        guard shouldRestoreAccessoryActivationPolicy else { return }
        _ = NSApp.setActivationPolicy(.accessory)
        shouldRestoreAccessoryActivationPolicy = false
    }

    private func activate(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
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
