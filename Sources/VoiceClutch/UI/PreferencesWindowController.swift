import AppKit

@MainActor
class PreferencesWindowController: NSWindowController {
    private enum Layout {
        static let contentWidth: CGFloat = 520
        static let contentHeight: CGFloat = 320
        static let rowHeight: CGFloat = 52
        static let tallRowHeight: CGFloat = 64
    }

    private let onShortcutChanged: @MainActor (ListeningShortcut) -> Void
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clipboardRecoverySwitch = NSSwitch(frame: .zero)
    private let mediaPauseSwitch = NSSwitch(frame: .zero)

    init(onShortcutChanged: @escaping @MainActor (ListeningShortcut) -> Void) {
        self.onShortcutChanged = onShortcutChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.contentWidth, height: Layout.contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceClutch Preferences"
        window.backgroundColor = .windowBackgroundColor
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        
        setupContent()
        enforceFixedWindowFrame()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupContent() {
        guard let window = window else { return }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: Layout.contentWidth, height: Layout.contentHeight))

        let panel = NSVisualEffectView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.material = .windowBackground
        panel.state = .active
        panel.blendingMode = .withinWindow
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true

        shortcutPopup.translatesAutoresizingMaskIntoConstraints = false
        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChanged(_:))
        shortcutPopup.addItems(withTitles: ListeningShortcut.allCases.map(\.menuTitle))
        for (index, item) in shortcutPopup.itemArray.enumerated() {
            item.tag = index
        }
        syncShortcutSelection()
        shortcutPopup.setContentHuggingPriority(.required, for: .horizontal)
        shortcutPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let shortcutRow = makeSettingsRow(
            title: "Push-to-talk shortcut",
            detail: "Choose which key starts recording when held.",
            control: shortcutPopup
        )

        configureToggle(clipboardRecoverySwitch, action: #selector(clipboardRecoveryChanged(_:)))
        syncClipboardRecoveryPreference()

        let clipboardRecoveryRow = makeSettingsRow(
            title: "Clipboard recovery",
            detail: "Restore your previous clipboard contents after dictation pastes text.",
            control: clipboardRecoverySwitch
        )

        configureToggle(mediaPauseSwitch, action: #selector(mediaPausePreferenceChanged(_:)))
        syncMediaPausePreference()

        let mediaPauseRow = makeSettingsRow(
            title: "Pause media while listening",
            detail: "Pause the active macOS media source when dictation starts, then resume it when you release the key.",
            control: mediaPauseSwitch,
            minimumHeight: Layout.tallRowHeight
        )

        let updateButton = NSButton(title: "Check Now…", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        let updateRow = makeSettingsRow(
            title: "Software Update",
            detail: "Check for new VoiceClutch releases manually.",
            control: updateButton,
            showsSeparator: false
        )

        let rowsStack = NSStackView(views: [
            shortcutRow,
            clipboardRecoveryRow,
            mediaPauseRow,
            updateRow
        ])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.distribution = .fill
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(rowsStack)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closePreferences))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.heightAnchor.constraint(equalToConstant: doneButton.fittingSize.height).isActive = true

        contentView.addSubview(panel)
        contentView.addSubview(doneButton)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            rowsStack.topAnchor.constraint(equalTo: panel.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            rowsStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            rowsStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            doneButton.topAnchor.constraint(equalTo: panel.bottomAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            doneButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])

        window.contentView = contentView
        let fixedContentSize = NSSize(width: Layout.contentWidth, height: Layout.contentHeight)
        window.setContentSize(fixedContentSize)
        window.contentMinSize = fixedContentSize
        window.contentMaxSize = fixedContentSize
    }

    private func enforceFixedWindowFrame() {
        guard let window = window else { return }

        let fixedContentRect = NSRect(x: 0, y: 0, width: Layout.contentWidth, height: Layout.contentHeight)
        let targetFrame = window.frameRect(forContentRect: fixedContentRect)
        let origin = NSPoint(
            x: window.frame.origin.x,
            y: window.frame.maxY - targetFrame.height
        )

        window.setFrame(NSRect(origin: origin, size: targetFrame.size), display: false)
    }

    private func makeSettingsRow(
        title: String,
        detail: String,
        control: NSView,
        minimumHeight: CGFloat = Layout.rowHeight,
        showsSeparator: Bool = true
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: minimumHeight).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addSubview(textStack)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7),

            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 16),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        if showsSeparator {
            let separator = NSView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor

            row.addSubview(separator)

            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                separator.heightAnchor.constraint(equalToConstant: 1 / max(NSScreen.main?.backingScaleFactor ?? 2, 1)),
                separator.bottomAnchor.constraint(equalTo: row.bottomAnchor)
            ])
        }

        return row
    }

    private func configureToggle(_ toggle: NSSwitch, action: Selector) {
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = action

        let toggleSize = toggle.fittingSize
        toggle.widthAnchor.constraint(equalToConstant: toggleSize.width).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: toggleSize.height).isActive = true
    }

    private func syncShortcutSelection() {
        let shortcut = ListeningShortcut.load()

        guard let index = ListeningShortcut.allCases.firstIndex(of: shortcut) else {
            shortcutPopup.selectItem(at: 0)
            return
        }

        shortcutPopup.selectItem(at: index)
    }

    private func syncClipboardRecoveryPreference() {
        clipboardRecoverySwitch.state = ClipboardRecoveryPreference.load() ? .on : .off
    }

    private func syncMediaPausePreference() {
        mediaPauseSwitch.state = ListeningMediaPreference.load() ? .on : .off
    }

    @objc private func shortcutChanged(_ sender: NSPopUpButton) {
        guard
            let selectedItem = sender.selectedItem,
            ListeningShortcut.allCases.indices.contains(selectedItem.tag)
        else {
            syncShortcutSelection()
            return
        }

        let shortcut = ListeningShortcut.allCases[selectedItem.tag]
        shortcut.save()
        onShortcutChanged(shortcut)
    }

    @objc private func clipboardRecoveryChanged(_ sender: NSSwitch) {
        ClipboardRecoveryPreference.save(sender.state == .on)
    }

    @objc private func mediaPausePreferenceChanged(_ sender: NSSwitch) {
        ListeningMediaPreference.save(sender.state == .on)
    }

    @objc private func checkForUpdates() {
        guard let window = window else { return }

        let alert = NSAlert()
        alert.messageText = "VoiceClutch is up to date!"
        alert.informativeText = "You are running the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    @objc private func closePreferences() {
        close()
    }
    
    func showWindow() {
        syncShortcutSelection()
        syncClipboardRecoveryPreference()
        syncMediaPausePreference()
        enforceFixedWindowFrame()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
