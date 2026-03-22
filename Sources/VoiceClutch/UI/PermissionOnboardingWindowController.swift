import AppKit
import Combine
@preconcurrency import AVFoundation

@MainActor
final class PermissionOnboardingWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let contentWidth: CGFloat = 520
        static let permissionRowHeight: CGFloat = 52
    }

    private let permissionsCoordinator: PermissionsCoordinator
    private var cancellables = Set<AnyCancellable>()

    private let accessibilityStatusIndicator = NSView()
    private let accessibilityActionButton = NSButton(title: "", target: nil, action: nil)

    private let microphoneStatusIndicator = NSView()
    private let microphoneActionButton = NSButton(title: "", target: nil, action: nil)

    private var latestSnapshot: PermissionSnapshot
    private var shouldRestoreAccessoryActivationPolicy = false
    private var shouldAutoCloseWhenPermissionsGranted = false
    private var didAutoCloseAfterCompletion = false

    var onDismissedWhileMissingPermissions: (() -> Void)?
    var onPermissionsCompleted: (() -> Void)?

    init(permissionsCoordinator: PermissionsCoordinator) {
        self.permissionsCoordinator = permissionsCoordinator
        latestSnapshot = permissionsCoordinator.snapshot

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.contentWidth, height: 1),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceClutch"
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        setupContent()
        bindPermissionUpdates()
        applyPermissionSnapshot(latestSnapshot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func showWindow() {
        permissionsCoordinator.refreshNow()
        let snapshot = permissionsCoordinator.snapshot
        latestSnapshot = snapshot
        applyPermissionSnapshot(snapshot)

        shouldAutoCloseWhenPermissionsGranted = hasMissingPermissions(snapshot)
        didAutoCloseAfterCompletion = false

        beginActivationContextIfNeeded()
        guard let window else { return }
        activateWindow(window)

        guard !window.isKeyWindow else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let window = self.window else { return }
            guard !window.isKeyWindow else { return }
            self.activateWindow(window)
        }
    }

    private func setupContent() {
        guard let window else { return }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: Layout.contentWidth, height: 1))

        let panel = NSVisualEffectView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        applyLiquidStyle(
            panel,
            overlayColor: windowBackgroundOverlayColor(),
            cornerRadius: 0,
            material: .windowBackground,
            blendingMode: .withinWindow
        )

        let titleLabel = NSTextField(labelWithString: "Permissions")
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(wrappingLabelWithString: "To get started, VoiceClutch requires accessibility and microphone permissions.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2

        let disclaimerLabel = NSTextField(
            wrappingLabelWithString: "• All processing runs offline and locally on your device.\n• Your voice and transcribed text never leaves your device.\n• VoiceClutch never collects analytics or usage data."
        )
        disclaimerLabel.font = NSFont.systemFont(ofSize: 12)
        disclaimerLabel.textColor = .secondaryLabelColor
        disclaimerLabel.maximumNumberOfLines = 3

        configurePermissionStatusIndicator(accessibilityStatusIndicator)
        configurePermissionActionButton(accessibilityActionButton, action: #selector(accessibilityActionPressed))

        configurePermissionStatusIndicator(microphoneStatusIndicator)
        configurePermissionActionButton(microphoneActionButton, action: #selector(microphoneActionPressed))

        let accessibilityRow = makePermissionRow(
            title: "Accessibility",
            detail: "Required for dictation keyboard shortcut to work.",
            statusIndicator: accessibilityStatusIndicator,
            actionButton: accessibilityActionButton,
            showsSeparator: true
        )

        let microphoneRow = makePermissionRow(
            title: "Microphone",
            detail: "Required to capture your speech.",
            statusIndicator: microphoneStatusIndicator,
            actionButton: microphoneActionButton,
            showsSeparator: false
        )

        let permissionsGroup = makePermissionGroup(rows: [accessibilityRow, microphoneRow])

        panel.addSubview(titleLabel)
        panel.addSubview(subtitleLabel)
        panel.addSubview(disclaimerLabel)
        panel.addSubview(permissionsGroup)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        disclaimerLabel.translatesAutoresizingMaskIntoConstraints = false
        permissionsGroup.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(panel)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: contentView.topAnchor),
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            disclaimerLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            disclaimerLabel.leadingAnchor.constraint(equalTo: subtitleLabel.leadingAnchor),
            disclaimerLabel.trailingAnchor.constraint(equalTo: subtitleLabel.trailingAnchor),

            permissionsGroup.topAnchor.constraint(equalTo: disclaimerLabel.bottomAnchor, constant: 14),
            permissionsGroup.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            permissionsGroup.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            permissionsGroup.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20)
        ])

        window.contentView = contentView
        contentView.layoutSubtreeIfNeeded()
        let fittedHeight = ceil(contentView.fittingSize.height)
        let fixedContentSize = NSSize(width: Layout.contentWidth, height: fittedHeight)
        window.setContentSize(fixedContentSize)
        window.contentMinSize = fixedContentSize
        window.contentMaxSize = fixedContentSize
    }

    private func makePermissionRow(
        title: String,
        detail: String,
        statusIndicator: NSView,
        actionButton: NSButton,
        showsSeparator: Bool
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let statusStack = NSStackView(views: [statusIndicator, actionButton])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 10
        statusStack.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: Layout.permissionRowHeight).isActive = true

        row.addSubview(textStack)
        row.addSubview(statusStack)

        if showsSeparator {
            let separator = NSView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.wantsLayer = true
            separator.layer?.backgroundColor = separatorColor().cgColor
            row.addSubview(separator)

            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                separator.heightAnchor.constraint(equalToConstant: 1 / max(NSScreen.main?.backingScaleFactor ?? 2, 1))
            ])
        }

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 16),
            statusStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            statusStack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    private func makePermissionGroup(rows: [NSView]) -> NSView {
        let group = NSVisualEffectView()
        applyLiquidStyle(
            group,
            overlayColor: cardBackgroundOverlayColor(),
            cornerRadius: 12,
            material: .hudWindow,
            blendingMode: .withinWindow
        )

        let rowsStack = NSStackView(views: rows)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.distribution = .fill
        rowsStack.spacing = 0

        group.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: group.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            rowsStack.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
            rowsStack.bottomAnchor.constraint(equalTo: group.bottomAnchor)
        ])

        return group
    }

    private func configurePermissionStatusIndicator(_ indicator: NSView) {
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 4
        indicator.layer?.backgroundColor = NSColor.systemOrange.cgColor
        indicator.widthAnchor.constraint(equalToConstant: 8).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    private func configurePermissionActionButton(_ button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    private func bindPermissionUpdates() {
        permissionsCoordinator.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.latestSnapshot = snapshot
                self?.applyPermissionSnapshot(snapshot)
            }
            .store(in: &cancellables)
    }

    private func applyPermissionSnapshot(_ snapshot: PermissionSnapshot) {
        let accessibilityGranted = snapshot.accessibilityGranted
        accessibilityStatusIndicator.layer?.backgroundColor = accessibilityGranted
            ? NSColor.systemGreen.cgColor
            : NSColor.systemOrange.cgColor
        accessibilityActionButton.title = accessibilityGranted ? "Enabled" : "Grant"
        accessibilityActionButton.isEnabled = !accessibilityGranted

        let microphoneGranted = snapshot.microphoneStatus == .authorized
        microphoneStatusIndicator.layer?.backgroundColor = microphoneGranted
            ? NSColor.systemGreen.cgColor
            : NSColor.systemOrange.cgColor

        if microphoneGranted {
            microphoneActionButton.title = "Enabled"
            microphoneActionButton.isEnabled = false
        } else {
            switch snapshot.microphoneStatus {
            case .authorized:
                microphoneActionButton.title = "Enabled"
                microphoneActionButton.isEnabled = false
            case .notDetermined:
                microphoneActionButton.title = "Grant"
                microphoneActionButton.isEnabled = true
            case .denied, .restricted:
                microphoneActionButton.title = "Grant"
                microphoneActionButton.isEnabled = true
            @unknown default:
                microphoneActionButton.title = "Grant"
                microphoneActionButton.isEnabled = true
            }
        }

        guard shouldAutoCloseWhenPermissionsGranted, !hasMissingPermissions(snapshot) else {
            return
        }

        shouldAutoCloseWhenPermissionsGranted = false
        didAutoCloseAfterCompletion = true
        onPermissionsCompleted?()
        close()
    }

    @objc private func accessibilityActionPressed() {
        guard !latestSnapshot.accessibilityGranted else { return }
        permissionsCoordinator.promptAccessibility()
    }

    @objc private func microphoneActionPressed() {
        switch latestSnapshot.microphoneStatus {
        case .notDetermined:
            Task { [weak self] in
                _ = await self?.permissionsCoordinator.requestMicrophoneAccessIfNeeded()
            }
        case .denied, .restricted:
            permissionsCoordinator.openMicrophoneSettings()
        case .authorized:
            return
        @unknown default:
            permissionsCoordinator.openMicrophoneSettings()
        }
    }

    func windowWillClose(_ notification: Notification) {
        endActivationContextIfNeeded()

        let closedWhileMissingPermissions = hasMissingPermissions(latestSnapshot)
        if closedWhileMissingPermissions && !didAutoCloseAfterCompletion {
            onDismissedWhileMissingPermissions?()
        }

        didAutoCloseAfterCompletion = false
        shouldAutoCloseWhenPermissionsGranted = false
    }

    private func hasMissingPermissions(_ snapshot: PermissionSnapshot) -> Bool {
        !snapshot.accessibilityGranted || snapshot.microphoneStatus != .authorized
    }

    private func beginActivationContextIfNeeded() {
        guard NSApp.activationPolicy() == .accessory else { return }
        if NSApp.setActivationPolicy(.regular) {
            shouldRestoreAccessoryActivationPolicy = true
        }
    }

    private func endActivationContextIfNeeded() {
        guard shouldRestoreAccessoryActivationPolicy else { return }
        _ = NSApp.setActivationPolicy(.accessory)
        shouldRestoreAccessoryActivationPolicy = false
    }

    private func activateWindow(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
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

    private func windowBackgroundOverlayColor() -> NSColor {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDarkMode {
            return NSColor.windowBackgroundColor.withAlphaComponent(0.82)
        }
        return NSColor.windowBackgroundColor.withAlphaComponent(0.9)
    }

    private func cardBackgroundOverlayColor() -> NSColor {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDarkMode {
            return NSColor.white.withAlphaComponent(0.035)
        }
        return NSColor.black.withAlphaComponent(0.04)
    }

    private func separatorColor() -> NSColor {
        NSColor.separatorColor.withAlphaComponent(0.1)
    }
}
