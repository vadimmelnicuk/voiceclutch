import AppKit

@MainActor
class PreferencesWindowController: NSWindowController {
    private enum Layout {
        static let contentWidth: CGFloat = 520
        static let contentHeight: CGFloat = 432
        static let rowHeight: CGFloat = 52
        static let interactionRowHeight: CGFloat = 78
    }

    private enum CustomShortcutCapture {
        static let escapeKeyCode: UInt16 = 53
        static let completedResponse = NSApplication.ModalResponse(rawValue: 2_001)
    }

    private let onShortcutChanged: @MainActor (ListeningShortcut) -> Void
    private let onInteractionModeChanged: @MainActor (ListeningInteractionMode) -> Void
    private let holdToTalkRadioButton = NSButton(radioButtonWithTitle: "Hold-to-talk", target: nil, action: nil)
    private let listenToggleRadioButton = NSButton(radioButtonWithTitle: "Press-to-talk", target: nil, action: nil)
    private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clipboardRecoverySwitch = NSSwitch(frame: .zero)
    private let mediaPauseSwitch = NSSwitch(frame: .zero)
    private let microphoneChimeSwitch = NSSwitch(frame: .zero)
    private var customShortcutCaptureMonitor: Any?
    private var capturedShortcutCodes = Set<UInt32>()
    private var isCapturingCustomShortcut = false
    private let listeningShortcutMenuItems: [ListeningShortcut] = [
        .leftOption,
        .rightOption,
        .control,
        .rightControl,
        .rightCommand,
        .rightShift,
        .custom
    ]

    init(
        onShortcutChanged: @escaping @MainActor (ListeningShortcut) -> Void,
        onInteractionModeChanged: @escaping @MainActor (ListeningInteractionMode) -> Void
    ) {
        self.onShortcutChanged = onShortcutChanged
        self.onInteractionModeChanged = onInteractionModeChanged
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

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = preferencesBackgroundColor().cgColor
        window.backgroundColor = preferencesBackgroundColor()

        let settingsCard = NSView()
        settingsCard.translatesAutoresizingMaskIntoConstraints = false
        settingsCard.wantsLayer = true
        settingsCard.layer?.backgroundColor = settingsCardBackgroundColor().cgColor
        settingsCard.layer?.cornerRadius = 12
        settingsCard.layer?.masksToBounds = true

        let interactionModeControl = makeInteractionModeControl()
        syncInteractionModeSelection()

        let interactionModeRow = makeSettingsRow(
            title: "Interaction",
            detail: "Choose whether listening runs only while held or starts and stops with each press.",
            control: interactionModeControl,
            minimumHeight: Layout.interactionRowHeight
        )

        shortcutPopup.translatesAutoresizingMaskIntoConstraints = false
        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChanged(_:))
        shortcutPopup.addItems(withTitles: listeningShortcutMenuItems.map(\.menuTitle))
        for (index, item) in shortcutPopup.itemArray.enumerated() {
            item.tag = index
        }
        syncShortcutSelection()
        shortcutPopup.setContentHuggingPriority(.required, for: .horizontal)
        shortcutPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let shortcutRow = makeSettingsRow(
            title: "Shortcut",
            detail: "Choose which key/combo triggers listening.",
            control: shortcutPopup
        )

        configureToggle(clipboardRecoverySwitch, action: #selector(clipboardRecoveryChanged(_:)))
        syncClipboardRecoveryPreference()

        let clipboardRecoveryRow = makeSettingsRow(
            title: "Clipboard recovery",
            detail: "Restore your previous clipboard contents after dictation ends.",
            control: clipboardRecoverySwitch
        )

        configureToggle(mediaPauseSwitch, action: #selector(mediaPausePreferenceChanged(_:)))
        syncMediaPausePreference()

        let mediaPauseRow = makeSettingsRow(
            title: "Media pause",
            detail: "Pause macOS media on dictation start, resume on end.",
            control: mediaPauseSwitch
        )

        configureToggle(microphoneChimeSwitch, action: #selector(microphoneChimePreferenceChanged(_:)))
        syncMicrophoneChimePreference()

        let microphoneChimeRow = makeSettingsRow(
            title: "Chimes",
            detail: "Play microphone chimes when listening starts and stops.",
            control: microphoneChimeSwitch
        )

        let updateButton = NSButton(title: "Check now", target: self, action: #selector(checkForUpdates))
        updateButton.bezelStyle = .rounded
        let updateRow = makeSettingsRow(
            title: "Software update",
            detail: "Check for new releases.",
            control: updateButton,
            showsSeparator: false
        )

        let rowsStack = NSStackView(views: [
            interactionModeRow,
            shortcutRow,
            clipboardRecoveryRow,
            mediaPauseRow,
            microphoneChimeRow,
            updateRow
        ])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.distribution = .fill
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        settingsCard.addSubview(rowsStack)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closePreferences))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.heightAnchor.constraint(equalToConstant: doneButton.fittingSize.height).isActive = true

        contentView.addSubview(panel)
        panel.addSubview(settingsCard)
        panel.addSubview(doneButton)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: contentView.topAnchor),
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            settingsCard.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            settingsCard.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            settingsCard.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),

            rowsStack.topAnchor.constraint(equalTo: settingsCard.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: settingsCard.leadingAnchor, constant: 16),
            rowsStack.trailingAnchor.constraint(equalTo: settingsCard.trailingAnchor, constant: -16),
            rowsStack.bottomAnchor.constraint(equalTo: settingsCard.bottomAnchor),

            doneButton.topAnchor.constraint(equalTo: settingsCard.bottomAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor),
            doneButton.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16)
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
            separator.layer?.backgroundColor = settingsSeparatorColor().cgColor

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

    private func makeInteractionModeControl() -> NSView {
        configureRadioButton(holdToTalkRadioButton, mode: .holdToTalk, tag: 0)
        configureRadioButton(listenToggleRadioButton, mode: .listenToggle, tag: 1)

        let stack = NSStackView(views: [holdToTalkRadioButton, listenToggleRadioButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    private func configureRadioButton(_ button: NSButton, mode: ListeningInteractionMode, tag: Int) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setButtonType(.radio)
        button.font = NSFont.systemFont(ofSize: 13)
        button.target = self
        button.action = #selector(interactionModeChanged(_:))
        button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
        button.tag = tag
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

    private func preferencesBackgroundColor() -> NSColor {
        return NSColor.windowBackgroundColor
    }

    private func settingsCardBackgroundColor() -> NSColor {
        NSColor.alternatingContentBackgroundColors.last ?? NSColor.controlBackgroundColor
    }

    private func settingsSeparatorColor() -> NSColor {
        NSColor.separatorColor
    }

    private func syncShortcutSelection() {
        let shortcut = ListeningShortcut.load()
        let mappedShortcut = mapStoredShortcutForMenuDisplay(shortcut)

        guard let index = listeningShortcutMenuItems.firstIndex(of: mappedShortcut) else {
            shortcutPopup.selectItem(at: 0)
            return
        }

        shortcutPopup.selectItem(at: index)
        if shortcut == .custom {
            let title = ListeningShortcut.customConfig().displayText
            let menuTitle = "Custom: \(title)"
            shortcutPopup.item(at: index)?.title = menuTitle
            return
        }

        shortcutPopup.item(at: index)?.title = shortcut.menuTitle
    }

    private func syncInteractionModeSelection() {
        let mode = ListeningInteractionMode.load()
        holdToTalkRadioButton.state = mode == .holdToTalk ? .on : .off
        listenToggleRadioButton.state = mode == .listenToggle ? .on : .off
    }

    private func syncClipboardRecoveryPreference() {
        clipboardRecoverySwitch.state = ClipboardRecoveryPreference.load() ? .on : .off
    }

    private func syncMediaPausePreference() {
        mediaPauseSwitch.state = ListeningMediaPreference.load() ? .on : .off
    }

    private func syncMicrophoneChimePreference() {
        microphoneChimeSwitch.state = MicrophoneChimePreference.load() ? .on : .off
    }

    @objc private func shortcutChanged(_ sender: NSPopUpButton) {
        guard
            let selectedItem = sender.selectedItem,
            listeningShortcutMenuItems.indices.contains(selectedItem.tag)
        else {
            syncShortcutSelection()
            return
        }

        let shortcut = listeningShortcutMenuItems[selectedItem.tag]
        if shortcut == .custom {
            beginCustomShortcutCapture()
            return
        }

        shortcut.save()
        onShortcutChanged(shortcut)
    }

    @objc private func interactionModeChanged(_ sender: NSButton) {
        let mode: ListeningInteractionMode
        switch sender.tag {
        case 0:
            mode = .holdToTalk
        case 1:
            mode = .listenToggle
        default:
            syncInteractionModeSelection()
            return
        }

        mode.save()
        syncInteractionModeSelection()
        onInteractionModeChanged(mode)
    }

    private func mapStoredShortcutForMenuDisplay(_ shortcut: ListeningShortcut) -> ListeningShortcut {
        switch shortcut {
        case .shift:
            return .rightShift
        case .command:
            return .rightCommand
        default:
            return shortcut
        }
    }

    private func beginCustomShortcutCapture() {
        guard !isCapturingCustomShortcut else { return }
        guard let hostWindow = window else { return }
        isCapturingCustomShortcut = true
        capturedShortcutCodes.removeAll()
        var snapshotShortcutCodes = Set<UInt32>()
        let captureCompletedResponse = CustomShortcutCapture.completedResponse

        let alert = NSAlert()
        alert.messageText = "Set custom hold-to-talk shortcut"
        alert.informativeText = customShortcutInformativeText()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cancel")

        var shouldStopModal = false
        var shouldPersistShortcut = false

        shortcutPopup.isEnabled = false
        var selectedTextUpdater: (() -> Void)?
        selectedTextUpdater = { [weak self] in
            guard let self = self else { return }
            alert.informativeText = self.customShortcutInformativeText()
        }

        let finishCapture: (NSApplication.ModalResponse, Bool) -> Void = { [weak self] response, persist in
            guard !shouldStopModal else { return }
            shouldStopModal = true
            shouldPersistShortcut = persist
            DispatchQueue.main.async {
                if let monitor = self?.customShortcutCaptureMonitor {
                    NSEvent.removeMonitor(monitor)
                    self?.customShortcutCaptureMonitor = nil
                }
                hostWindow.endSheet(alert.window, returnCode: response)
            }
        }

        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }

            if event.type == .keyDown && event.keyCode == CustomShortcutCapture.escapeKeyCode {
                DispatchQueue.main.async {
                    finishCapture(.cancel, false)
                }
                return event
            }

            if event.type == .keyDown {
                self.capturedShortcutCodes.insert(UInt32(event.keyCode))
                snapshotShortcutCodes = self.capturedShortcutCodes
                DispatchQueue.main.async {
                    selectedTextUpdater?()
                }
                return nil
            }

            if event.type == .keyUp {
                let beforeRelease = self.capturedShortcutCodes
                let changedCode = UInt32(event.keyCode)

                self.capturedShortcutCodes.remove(changedCode)
                DispatchQueue.main.async { selectedTextUpdater?() }

                guard !beforeRelease.isEmpty else { return nil }
                snapshotShortcutCodes = beforeRelease
                DispatchQueue.main.async {
                    finishCapture(captureCompletedResponse, true)
                }
                return nil
            }

            if event.type == .flagsChanged {
                let keyCode = UInt32(event.keyCode)
                guard HotkeyConfig.modifierKeyCodes.contains(keyCode) else {
                    return event
                }
                let beforeRelease = self.capturedShortcutCodes

                if self.isModifierPressed(in: event.modifierFlags, keyCode: keyCode) {
                    self.capturedShortcutCodes.insert(keyCode)
                } else {
                    self.capturedShortcutCodes.remove(keyCode)
                }

                DispatchQueue.main.async { selectedTextUpdater?() }

                snapshotShortcutCodes = beforeRelease
                if !self.isModifierPressed(in: event.modifierFlags, keyCode: keyCode) && !beforeRelease.isEmpty {
                    DispatchQueue.main.async {
                        finishCapture(captureCompletedResponse, true)
                    }
                }
                return nil
            }

            return event
        }
        customShortcutCaptureMonitor = monitor

        DispatchQueue.main.async {
            selectedTextUpdater?()
        }

        // Keep UI responsive while monitoring and allow key events to update the preview.
        alert.beginSheetModal(for: hostWindow) { [weak self] response in
            guard let self = self else { return }

            if let monitor = self.customShortcutCaptureMonitor {
                NSEvent.removeMonitor(monitor)
                self.customShortcutCaptureMonitor = nil
            }
            self.isCapturingCustomShortcut = false
            self.shortcutPopup.isEnabled = true

            guard shouldPersistShortcut,
                  response == captureCompletedResponse,
                  !snapshotShortcutCodes.isEmpty else {
                self.syncShortcutSelection()
                return
            }

            let capturedConfig = HotkeyConfig(keyCodes: Array(snapshotShortcutCodes))
            ListeningShortcut.saveCustomConfig(capturedConfig)
            ListeningShortcut.custom.save()
            self.onShortcutChanged(.custom)
            self.syncShortcutSelection()
        }
    }

    private func customShortcutInformativeText() -> String {
        "Hold keys together, then release to register. Press Escape to cancel.\n\n\(currentCustomShortcutText())"
    }

    private func isModifierPressed(in modifierFlags: NSEvent.ModifierFlags, keyCode: UInt32) -> Bool {
        switch keyCode {
        case HotkeyConfig.commandKey, HotkeyConfig.rightCommandKey:
            return modifierFlags.contains(.command)
        case HotkeyConfig.optionKey, HotkeyConfig.rightOptionKey:
            return modifierFlags.contains(.option)
        case HotkeyConfig.controlKey, HotkeyConfig.rightControlKey:
            return modifierFlags.contains(.control)
        case HotkeyConfig.shiftKey, HotkeyConfig.rightShiftKey:
            return modifierFlags.contains(.shift)
        default:
            return false
        }
    }

    private func currentCustomShortcutText() -> String {
        if capturedShortcutCodes.isEmpty {
            return "Press and hold one or more keys..."
        }

        let names = HotkeyConfig(keyCodes: Array(capturedShortcutCodes)).displayText
        if names.isEmpty {
            return "Press and hold one or more keys..."
        }

        return names
    }

    @objc private func clipboardRecoveryChanged(_ sender: NSSwitch) {
        ClipboardRecoveryPreference.save(sender.state == .on)
    }

    @objc private func mediaPausePreferenceChanged(_ sender: NSSwitch) {
        ListeningMediaPreference.save(sender.state == .on)
    }

    @objc private func microphoneChimePreferenceChanged(_ sender: NSSwitch) {
        MicrophoneChimePreference.save(sender.state == .on)
    }

    @objc private func checkForUpdates() {
        guard let window = window else { return }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

        let alert = NSAlert()
        alert.messageText = "VoiceClutch is up to date"
        alert.informativeText = "You are running the latest release.\nCurrent version: \(currentVersion)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    @objc private func closePreferences() {
        close()
    }
    
    func showWindow() {
        syncInteractionModeSelection()
        syncShortcutSelection()
        syncClipboardRecoveryPreference()
        syncMediaPausePreference()
        syncMicrophoneChimePreference()
        enforceFixedWindowFrame()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
