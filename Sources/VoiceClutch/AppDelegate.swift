import AppKit
import Combine
import Dispatch

// Import core components
@preconcurrency import AVFoundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    @Published private(set) var currentState: VoiceClutchState = .idle
    @Published private(set) var downloadProgress: Double = 0.0
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Components
    private let dictationController = DictationController()
    private let hotkeyManager = HotkeyManager()
    private let mediaPlaybackController = MediaPlaybackController()
    private var statusBarController: StatusBarController?
    private var currentListeningShortcut = ListeningShortcut.load()
    private var permissionCheckTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var isListeningHotkeyHeld = false

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (LSUIElement behavior)
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()
        setupDictationController()
        setupStateObserving()
        setupMemoryPressureMonitoring()

        // Check accessibility permissions - this will start the permission checking loop
        Task {
            await checkAccessibilityPermissions()
        }
    }

    // MARK: - Model Management

    private func checkAndDownloadModels() async {
        let needsDownload = !dictationController.areModelsInstalled()

        if needsDownload {
            // First launch - download models

            if let downloadSizeBytes = await dictationController.requiredDownloadSize() {
                let downloadSizeMB = downloadSizeBytes / 1_048_576
                await showFirstLaunchAlert(sizeMB: downloadSizeMB)
            } else {
                // Fall back to showing alert without size
                await showFirstLaunchAlert(sizeMB: nil)
            }

            dictationController.setState(.downloading)
        }

        do {
            let outcome = try await dictationController.prepareForUse()
            #if DEBUG
            print("✅ VoiceClutch ready")
            #endif

            if outcome == .downloadedModels {
                await showDownloadCompleteNotification()
            }
        } catch {
            print("❌ Model download failed: \(error)")
            dictationController.setState(.idle)
            await showModelDownloadError(error)
        }
    }

    private func showModelDownloadError(_ error: Error) async {
        let alert = NSAlert()
        alert.messageText = "Model Download Failed"
        alert.informativeText = "Failed to download required models: \(error.localizedDescription)\n\nPlease check your internet connection and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            await checkAndDownloadModels()
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func showFirstLaunchAlert(sizeMB: Int64?) async {
        let alert = NSAlert()
        alert.messageText = "Downloading Required Models"

        let sizeText: String
        if let sizeMB = sizeMB {
            sizeText = "\(sizeMB) MB"
        } else {
            sizeText = "approximately 600 MB"
        }

        alert.informativeText = "VoiceClutch needs to download speech recognition models (\(sizeText)). This only happens once."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showDownloadCompleteNotification() async {
        let alert = NSAlert()
        alert.messageText = "Models Downloaded Successfully"
        alert.informativeText = "VoiceClutch is ready to use! Press and hold your selected shortcut to start dictating."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        resumeMediaIfNeeded()
        dictationController.shutdown()
    }

    // MARK: - Setup
    private func setupStatusBar() {
        statusBarController = StatusBarController { [weak self] shortcut in
            self?.applyListeningShortcut(shortcut)
        }
    }

    private func setupDictationController() {
        dictationController.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.currentState = state
            }
            .store(in: &cancellables)

        dictationController.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.downloadProgress = progress
                self?.statusBarController?.updateDownloadProgress(progress)
            }
            .store(in: &cancellables)
    }

    private func setupHotkey() {
        applyListeningShortcut(ListeningShortcut.load(), force: true)
    }

    private func attemptHotkeyRegistration(config: HotkeyConfig, attempt: Int, maxAttempts: Int) {
        let success = hotkeyManager.register(config: config) { [weak self] eventType in
            DispatchQueue.main.async {
                self?.handleHotkeyEvent(eventType)
            }
        }

        if success {
            return
        }

        if attempt < maxAttempts {
            // Retry after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.attemptHotkeyRegistration(config: config, attempt: attempt + 1, maxAttempts: maxAttempts)
            }
            return
        }

        print("❌ Failed to register listening shortcut: \(config.keyCode)")
    }

    func applyListeningShortcut(_ shortcut: ListeningShortcut, force: Bool = false) {
        guard force || shortcut != currentListeningShortcut else { return }

        currentListeningShortcut = shortcut
        attemptHotkeyRegistration(config: shortcut.hotkeyConfig, attempt: 1, maxAttempts: 5)
    }

    private func setupStateObserving() {
        $currentState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.statusBarController?.updateIcon(for: state)
                self?.statusBarController?.updateMenu(for: state)
            }
            .store(in: &cancellables)
    }

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleMemoryPressureEvent()
            }
        }

        source.resume()
        memoryPressureSource = source
    }

    private func handleMemoryPressureEvent() {
        guard let eventMask = memoryPressureSource?.data else { return }
        guard eventMask.contains(.warning) || eventMask.contains(.critical) else { return }
        _ = dictationController.compactMemoryIfIdle()
    }

    // MARK: - Accessibility Permissions
    private func checkAccessibilityPermissions() async {
        // Use a mutable dictionary with proper bridging for concurrency safety
        let options = NSMutableDictionary()
        options.setObject(false, forKey: "AXTrustedCheckOptionPrompt" as NSString)
        let accessibilityEnabled = AXIsProcessTrustedWithOptions(options)

        if accessibilityEnabled {
            // Permissions granted, proceed with initialization
            await onPermissionsGranted()
        } else {
            // Show native permissions request
            let promptOptions = NSMutableDictionary()
            promptOptions.setObject(true, forKey: "AXTrustedCheckOptionPrompt" as NSString)
            AXIsProcessTrustedWithOptions(promptOptions)

            // Start checking loop to wait for user to grant permissions
            startPermissionCheckLoop()
        }
    }

    private func startPermissionCheckLoop() {
        // Start a timer to check permissions every 2 seconds
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkPermissionsPeriodically()
            }
        }
    }

    private func checkPermissionsPeriodically() async {
        let options = NSMutableDictionary()
        options.setObject(false, forKey: "AXTrustedCheckOptionPrompt" as NSString)
        let accessibilityEnabled: Bool = AXIsProcessTrustedWithOptions(options)

        if accessibilityEnabled {
            // Stop the timer
            permissionCheckTimer?.invalidate()
            permissionCheckTimer = nil

            // Proceed with initialization
            await onPermissionsGranted()
        }
    }

    private func onPermissionsGranted() async {
        // Now that we have permissions, complete the initialization
        setupHotkey()
        await checkAndDownloadModels()
    }

    // MARK: - Hotkey Handling
    private func handleHotkeyEvent(_ eventType: HotkeyEventType) {
        switch eventType {
        case .pressed:
            if currentState == .downloading || currentState == .loadingModel {
                showNotReadyNotification()
                return
            }
            guard currentState == .idle else { return }

            isListeningHotkeyHeld = true
            Task { [weak self] in
                await self?.beginListeningFromHotkeyPress()
            }
        case .released:
            isListeningHotkeyHeld = false

            if currentState == .recording {
                stopRecording()
                resumeMediaIfNeeded()
            }
        }
    }

    // MARK: - Recording Actions
    private func beginListeningFromHotkeyPress() async {
        guard currentState == .idle else { return }

        // Check if models are ready
        guard dictationController.isReady else {
            showNotReadyNotification()
            return
        }

        let shouldPauseMedia = ListeningMediaPreference.load()
        let didPauseMedia = shouldPauseMedia
            ? await mediaPlaybackController.pauseIfActive()
            : false

        guard isListeningHotkeyHeld, currentState == .idle else {
            if didPauseMedia {
                resumeMediaIfNeeded()
            }
            return
        }

        let didStartRecording = startRecordingIfReady()

        if !didStartRecording, didPauseMedia {
            resumeMediaIfNeeded()
        }
    }

    @discardableResult
    private func startRecordingIfReady() -> Bool {
        // Check if models are ready
        guard dictationController.isReady else {
            showNotReadyNotification()
            return false
        }

        // Start audio recording
        do {
            try dictationController.startRecording()
            return true
        } catch {
            print("❌ Failed to start recording: \(error)")
            return false
        }
    }

    private func resumeMediaIfNeeded() {
        mediaPlaybackController.resumeIfNeeded()
    }

    private func showNotReadyNotification() {
        let message: String
        switch currentState {
        case .downloading:
            message = "VoiceClutch is downloading models"
        case .loadingModel:
            message = "VoiceClutch is loading model"
        default:
            message = "VoiceClutch is still getting ready"
        }

        statusBarController?.showToolbarNotification(message)
    }

    func stopRecording() {
        dictationController.stopRecording()
    }
}
