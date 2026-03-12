import AppKit
import QuartzCore

@MainActor
class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private var menu: NSMenu
    private var statusMenuItem: NSMenuItem?
    private weak var statusMenuLabel: NSTextField?
    private weak var statusMenuIndicator: NSView?
    private let preferencesWindowController: PreferencesWindowController
    private let toolbarIcon: NSImage?
    private let activeListeningToolbarIcon: NSImage?
    private var isShowingActiveListeningIcon: Bool?
    private var pendingToolbarIconTransitionWorkItem: DispatchWorkItem?
    private var previousState: VoiceClutchState?
    private var notificationPopover: NSPopover?
    private var notificationDismissWorkItem: DispatchWorkItem?
    private var currentMenuState: VoiceClutchState = .idle
    private var hasMissingPermissions = false
    private var previousHasMissingPermissions = false
    private var currentDownloadProgress: Double?
    private var isStatusMenuOpen = false
    private var pendingPreferencesOpen = false

    init(
        onShortcutChanged: @escaping @MainActor (ListeningShortcut) -> Void,
        onInteractionModeChanged: @escaping @MainActor (ListeningInteractionMode) -> Void,
        permissionsCoordinator: PermissionsCoordinator
    ) {
        // Use a square status item when showing an icon.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Setup menu
        menu = NSMenu()
        preferencesWindowController = PreferencesWindowController(
            onShortcutChanged: onShortcutChanged,
            onInteractionModeChanged: onInteractionModeChanged,
            permissionsCoordinator: permissionsCoordinator
        )
        toolbarIcon = Self.loadToolbarIcon()
        activeListeningToolbarIcon = toolbarIcon.flatMap {
            Self.maskedToolbarIcon(from: $0, color: NSColor(srgbRed: 1.0, green: 0.6, blue: 0.0, alpha: 1.0))
        }
        hasMissingPermissions =
            !permissionsCoordinator.accessibilityGranted ||
            permissionsCoordinator.microphoneStatus != .authorized
        previousHasMissingPermissions = hasMissingPermissions

        super.init()

        setupMenu()
        updateIcon(for: .idle)
    }

    private func setupMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        // Status item (non-interactive, shows current state)
        let initialTitle = hasMissingPermissions ? "Permissions missing" : "Ready"
        let initialColor: NSColor = hasMissingPermissions ? .systemOrange : .systemGreen

        let statusMenuItem = NSMenuItem(
            title: initialTitle,
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        statusMenuItem.view = makeStatusMenuItemView(title: initialTitle, color: initialColor)
        self.statusMenuItem = statusMenuItem
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let prefsItem = NSMenuItem(
            title: "Preferences",
            action: #selector(showPreferences),
            keyEquivalent: ""
        )
        prefsItem.target = self
        prefsItem.isEnabled = true
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    // MARK: - Icon & Menu Updates

    func updateIcon(for state: VoiceClutchState) {
        guard let button = statusItem.button else { return }

        if let toolbarIcon {
            button.title = ""
            button.imagePosition = .imageOnly

            let wantsActiveListeningIcon = state == .recording
            let targetImage = wantsActiveListeningIcon
                ? (activeListeningToolbarIcon ?? toolbarIcon)
                : toolbarIcon
            let shouldAnimateTransition = activeListeningToolbarIcon != nil &&
                isShowingActiveListeningIcon != nil &&
                isShowingActiveListeningIcon != wantsActiveListeningIcon
            updateToolbarButtonImage(
                targetImage,
                wantsActiveListeningIcon: wantsActiveListeningIcon,
                on: button,
                animated: shouldAnimateTransition
            )
        } else {
            pendingToolbarIconTransitionWorkItem?.cancel()
            pendingToolbarIconTransitionWorkItem = nil
            isShowingActiveListeningIcon = nil
            button.image = nil
            button.imagePosition = .noImage
            button.title = fallbackEmoji(for: state)
        }

        applyToolbarOpacity(for: state, on: button)
        previousState = state
        button.toolTip = tooltip(for: state)
    }

    func updateMenu(for state: VoiceClutchState) {
        currentMenuState = state
        let title: String
        let color: NSColor
        if hasMissingPermissions {
            title = "Permissions missing"
            color = .systemOrange
        } else {
            switch state {
            case .idle:
                title = "Ready"
                color = .systemGreen
            case .recording:
                title = "Recording"
                color = NSColor(srgbRed: 1.0, green: 0.6, blue: 0.0, alpha: 1.0)
            case .processing:
                title = "Processing"
                color = .systemBlue
            case .downloading:
                if let currentDownloadProgress {
                    let percent = Int((currentDownloadProgress * 100).rounded())
                    let clampedPercent = max(0, min(100, percent))
                    title = "Downloading model \(clampedPercent)%"
                } else {
                    title = "Downloading model"
                }
                color = .systemGray
            case .loadingModel:
                title = "Loading model"
                color = .systemGray
            }
        }

        setStatusMenuLabel(title: title, color: color)
    }

    func updatePermissionStatus(accessibilityGranted: Bool, microphoneGranted: Bool) {
        let missingPermissions = !accessibilityGranted || !microphoneGranted
        guard missingPermissions != hasMissingPermissions else {
            return
        }

        hasMissingPermissions = missingPermissions
        updateMenu(for: currentMenuState)
        updateIcon(for: currentMenuState)
    }

    func updateDownloadProgress(_ progress: Double) {
        currentDownloadProgress = progress

        guard currentMenuState == .downloading, !hasMissingPermissions else {
            return
        }

        let progressPercent = Int((progress * 100).rounded())
        let clampedPercent = max(0, min(100, progressPercent))
        setStatusMenuLabel(title: "Downloading model \(clampedPercent)%", color: .systemGray)
    }

    func showToolbarNotification(_ message: String, duration: TimeInterval = 3.0) {
        guard let button = statusItem.button else { return }

        notificationDismissWorkItem?.cancel()
        notificationPopover?.close()

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        let viewController = makeNotificationViewController(message: message)
        popover.contentViewController = viewController
        popover.contentSize = viewController.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)

        notificationPopover = popover

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            self?.notificationPopover?.close()
            self?.notificationPopover = nil
            self?.notificationDismissWorkItem = nil
        }
        notificationDismissWorkItem = dismissWorkItem

        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissWorkItem)
    }

    private func makeNotificationViewController(message: String) -> NSViewController {
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 10

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false

        let labelSize = label.intrinsicContentSize
        let containerSize = NSSize(
            width: ceil(labelSize.width + (horizontalPadding * 2)),
            height: ceil(labelSize.height + (verticalPadding * 2))
        )

        let container = NSView(frame: NSRect(origin: .zero, size: containerSize))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalPadding),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontalPadding),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalPadding)
        ])

        let viewController = NSViewController()
        viewController.view = container
        viewController.preferredContentSize = containerSize
        return viewController
    }

    // MARK: - Actions

    @objc private func showPreferences() {
        // Defer until menu tracking ends so the preferences window can become key.
        pendingPreferencesOpen = true
        DispatchQueue.main.async { [weak self] in
            self?.openPendingPreferencesIfMenuClosed()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isStatusMenuOpen = false
        openPendingPreferencesIfMenuClosed()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isStatusMenuOpen = true
    }

    private func openPendingPreferencesIfMenuClosed() {
        guard pendingPreferencesOpen else { return }
        guard !isStatusMenuOpen else { return }
        pendingPreferencesOpen = false
        preferencesWindowController.showWindow()
    }

    private func makeStatusMenuItemView(title: String, color: NSColor) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 22))
        container.translatesAutoresizingMaskIntoConstraints = false

        let indicator = NSView()
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 4
        indicator.layer?.backgroundColor = color.cgColor
        indicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(indicator)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 210),
            container.heightAnchor.constraint(equalToConstant: 22),
            indicator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 8),
            indicator.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        statusMenuLabel = label
        statusMenuIndicator = indicator
        return container
    }

    private func setStatusMenuLabel(title: String, color: NSColor) {
        statusMenuItem?.title = title
        statusMenuLabel?.stringValue = title
        statusMenuLabel?.textColor = .labelColor
        statusMenuIndicator?.layer?.backgroundColor = color.cgColor
    }

    private static func loadToolbarIcon() -> NSImage? {
        let iconFileNames = [
            "logo@1x.png",
            "logo@2x.png",
            "logo@3x.png",
        ]

        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
            .deletingLastPathComponent()
        let projectRootFromBuildOutput = executableDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let searchDirectories: [URL?] = [
            Bundle.main.resourceURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true),
            executableDirectory
                .appendingPathComponent("Resources", isDirectory: true),
            projectRootFromBuildOutput
                .appendingPathComponent("Resources", isDirectory: true),
        ]

        for directory in searchDirectories.compactMap({ $0 }) {
            let image = NSImage(size: NSSize(width: 18, height: 18))
            var hasRepresentation = false

            for fileName in iconFileNames {
                let fileURL = directory.appendingPathComponent(fileName)
                if let sourceImage = NSImage(contentsOf: fileURL) {
                    for representation in sourceImage.representations {
                        image.addRepresentation(representation)
                    }
                    hasRepresentation = true
                }
            }

            if hasRepresentation {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = false
                return image
            }
        }

        return nil
    }

    private static func maskedToolbarIcon(from sourceImage: NSImage, color: NSColor) -> NSImage? {
        let imageSize = sourceImage.size.width > 0 && sourceImage.size.height > 0
            ? sourceImage.size
            : NSSize(width: 18, height: 18)
        let rect = NSRect(origin: .zero, size: imageSize)

        let tintedImage = NSImage(size: imageSize)
        tintedImage.lockFocus()
        color.setFill()
        rect.fill()
        sourceImage.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
        tintedImage.unlockFocus()
        tintedImage.isTemplate = false
        return tintedImage
    }

    private func setToolbarButtonImage(_ image: NSImage, on button: NSStatusBarButton, animated: Bool) {
        guard animated else {
            button.image = image
            return
        }

        button.wantsLayer = true
        if let layer = button.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.58, 1.0)
            layer.add(fade, forKey: "voiceclutchToolbarIconFade")
        }

        button.image = image
    }

    private func updateToolbarButtonImage(
        _ image: NSImage,
        wantsActiveListeningIcon: Bool,
        on button: NSStatusBarButton,
        animated: Bool
    ) {
        pendingToolbarIconTransitionWorkItem?.cancel()
        pendingToolbarIconTransitionWorkItem = nil

        let isTransitioningOffActiveListening = (isShowingActiveListeningIcon == true) &&
            !wantsActiveListeningIcon &&
            animated
        guard isTransitioningOffActiveListening else {
            setToolbarButtonImage(image, on: button, animated: animated)
            isShowingActiveListeningIcon = wantsActiveListeningIcon
            return
        }

        let workItem = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button else { return }
            self.setToolbarButtonImage(image, on: button, animated: true)
            self.isShowingActiveListeningIcon = wantsActiveListeningIcon
            self.pendingToolbarIconTransitionWorkItem = nil
        }
        pendingToolbarIconTransitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AudioManager.postReleaseCaptureDuration,
            execute: workItem
        )
    }

    private func applyToolbarOpacity(for state: VoiceClutchState, on button: NSStatusBarButton) {
        let isDimmedState = state == .downloading || state == .loadingModel || hasMissingPermissions
        let targetOpacity: CGFloat = isDimmedState ? 0.5 : 1.0
        let wasDimmedState = previousState == .downloading || previousState == .loadingModel || previousHasMissingPermissions
        let isExitingDimmedState = wasDimmedState && !isDimmedState

        if isExitingDimmedState {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().alphaValue = targetOpacity
            }
        } else {
            button.alphaValue = targetOpacity
        }

        previousHasMissingPermissions = hasMissingPermissions
    }

    private func fallbackEmoji(for state: VoiceClutchState) -> String {
        switch state {
        case .idle, .downloading, .loadingModel:
            return "⚫"
        case .recording:
            return "🔴"
        case .processing:
            return "🔵"
        }
    }

    private func tooltip(for state: VoiceClutchState) -> String {
        switch state {
        case .idle:
            return "VoiceClutch: Ready"
        case .recording:
            return "VoiceClutch: Recording"
        case .processing:
            return "VoiceClutch: Processing"
        case .downloading:
            return "VoiceClutch: Downloading model"
        case .loadingModel:
            return "VoiceClutch: Loading model"
        }
    }
}
