import AppKit
import Combine
import CoreGraphics
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
    private let permissionsCoordinator = PermissionsCoordinator()
    private var statusBarController: StatusBarController?
    private let vocabularyWindowController = VocabularyWindowController()
    private var currentInteractionMode = ListeningInteractionMode.load()
    private var currentListeningShortcut = ListeningShortcut.load()
    private var currentListeningShortcutConfig: HotkeyConfig = ListeningShortcut.load().hotkeyConfig
    private var lastPermissionSnapshot: PermissionSnapshot?
    private var hotkeyRecoveryTimer: Timer?
    private var missingPermissionShortcutFeedbackTimer: Timer?
    private var isMissingPermissionShortcutCurrentlyPressed = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var isListeningHotkeyHeld = false
    private var shouldPlayStopChimeForCurrentSession = false
    private var hasCompletedInitialPreparation = false
    private var hasShownHotkeyRecoveryNotification = false

    private enum DefaultsKeys {
        static let didRequestInitialPermissions = "dev.vm.voiceclutch.didRequestInitialPermissions"
    }

    private enum NotificationMessage {
        static let hotkeyActivationReady = "Listening shortcut is active."
        static let hotkeyWaitingForAccessibility = "Waiting for Accessibility permission. VoiceClutch will retry automatically."
        static let hotkeyRevoked = "Accessibility permission revoked. Listening shortcut is disabled."
        static let hotkeyNeedsAccessibility = "Enable Accessibility permission to activate the listening shortcut."
        static let hotkeyRequiresAccessibility = "Accessibility permission is required for global hotkeys."
        static let hotkeyInvalidShortcut = "Could not register listening shortcut. Choose another key combination."
        static let permissionsMissing = "Permissions missing. Open Preferences > Permissions."
        static let micPermissionPending = "Microphone permission is pending. Open Preferences > Permissions."
        static let micPermissionDenied = "Microphone permission is denied. Open Preferences > Permissions."
        static let micPermissionUnknown = "Microphone permission status is unknown."
    }

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (LSUIElement behavior)
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()
        setupCorrectionLearning()
        setupDictationController()
        setupStateObserving()
        setupMemoryPressureMonitoring()
        setupPermissionMonitoring()

        Task { [weak self] in
            await self?.runInitialPermissionOnboardingIfNeeded()
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
        alert.messageText = "Model download failed"
        alert.informativeText = "Failed to download required model: \(error.localizedDescription)\n\nPlease check your internet connection and try again."
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
        alert.messageText = "Downloading required model"

        let sizeText: String
        if let sizeMB = sizeMB {
            sizeText = "\(sizeMB) MB"
        } else {
            sizeText = "600 MB"
        }

        alert.informativeText = "VoiceClutch needs to download speech recognition model (\(sizeText)). This only happens once."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showDownloadCompleteNotification() async {
        let alert = NSAlert()
        alert.messageText = "Model downloaded successfully"
        alert.informativeText = "VoiceClutch will be ready to use once the model is loaded into memory."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        hotkeyRecoveryTimer?.invalidate()
        hotkeyRecoveryTimer = nil
        missingPermissionShortcutFeedbackTimer?.invalidate()
        missingPermissionShortcutFeedbackTimer = nil
        permissionsCoordinator.stopMonitoring()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        resumeMediaIfNeeded()
        dictationController.shutdown()
        CorrectionLearningMonitor.shared.cancel()
        CorrectionLearningMonitor.shared.uninstallEventMonitors()
    }

    // MARK: - Setup
    private func setupStatusBar() {
        statusBarController = StatusBarController(
            onShortcutChanged: { [weak self] shortcut in
                self?.applyListeningShortcut(shortcut)
            },
            onInteractionModeChanged: { [weak self] mode in
                self?.applyListeningInteractionMode(mode)
            },
            onManageVocabulary: { [weak self] in
                self?.showVocabularyWindow()
            },
            permissionsCoordinator: permissionsCoordinator
        )
    }

    private func setupCorrectionLearning() {
        CorrectionLearningMonitor.shared.installEventMonitors()
    }

    private func showVocabularyWindow() {
        vocabularyWindowController.showWindow()
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

    @discardableResult
    private func registerHotkey(config: HotkeyConfig) -> Bool {
        hotkeyManager.register(config: config) { [weak self] eventType in
            DispatchQueue.main.async {
                self?.handleHotkeyEvent(eventType)
            }
        }
    }

    private func startHotkeyRecoveryLoopIfNeeded() {
        guard hotkeyRecoveryTimer == nil else {
            return
        }

        hotkeyRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.retryHotkeyRegistrationIfNeeded()
            }
        }
    }

    private func stopHotkeyRecoveryLoop() {
        hotkeyRecoveryTimer?.invalidate()
        hotkeyRecoveryTimer = nil
    }

    private func retryHotkeyRegistrationIfNeeded() {
        guard permissionsCoordinator.accessibilityGranted else {
            stopHotkeyRecoveryLoop()
            return
        }

        ensureHotkeyRegistered(showFailureNotification: false)
    }

    private func ensureHotkeyRegistered(showFailureNotification: Bool) {
        guard permissionsCoordinator.accessibilityGranted else {
            stopHotkeyRecoveryLoop()
            return
        }

        let config = currentListeningShortcutConfig
        guard config.isValid else {
            hotkeyManager.unregister()
            stopHotkeyRecoveryLoop()
            hasShownHotkeyRecoveryNotification = false
            statusBarController?.showToolbarNotification(NotificationMessage.hotkeyInvalidShortcut)
            return
        }

        let success = registerHotkey(config: config)
        if success {
            stopHotkeyRecoveryLoop()
            if hasShownHotkeyRecoveryNotification {
                statusBarController?.showToolbarNotification(NotificationMessage.hotkeyActivationReady)
            }
            hasShownHotkeyRecoveryNotification = false
            return
        }

        startHotkeyRecoveryLoopIfNeeded()
        guard showFailureNotification, !hasShownHotkeyRecoveryNotification else {
            return
        }

        hasShownHotkeyRecoveryNotification = true
        print("❌ Failed to register listening shortcut: \(config.displayText)")
        statusBarController?.showToolbarNotification(
            NotificationMessage.hotkeyWaitingForAccessibility
        )
    }

    func applyListeningInteractionMode(_ mode: ListeningInteractionMode) {
        currentInteractionMode = mode
    }

    func applyListeningShortcut(_ shortcut: ListeningShortcut, force: Bool = false) {
        let config = shortcut.hotkeyConfig
        let shouldUpdate = force || shortcut != currentListeningShortcut || currentListeningShortcutConfig != config
        guard shouldUpdate else { return }

        currentListeningShortcut = shortcut
        currentListeningShortcutConfig = config
        guard permissionsCoordinator.accessibilityGranted else {
            hotkeyManager.unregister()
            stopHotkeyRecoveryLoop()
            return
        }

        ensureHotkeyRegistered(showFailureNotification: true)
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

    // MARK: - Permissions
    private func setupPermissionMonitoring() {
        permissionsCoordinator.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.handlePermissionSnapshotUpdate(snapshot)
            }
            .store(in: &cancellables)

        permissionsCoordinator.startMonitoring()
        handlePermissionSnapshotUpdate(permissionsCoordinator.snapshot)
    }

    private func handlePermissionSnapshotUpdate(_ snapshot: PermissionSnapshot) {
        let previousSnapshot = lastPermissionSnapshot
        lastPermissionSnapshot = snapshot
        statusBarController?.updatePermissionStatus(
            accessibilityGranted: snapshot.accessibilityGranted,
            microphoneGranted: snapshot.microphoneStatus == .authorized
        )
        updateMissingPermissionShortcutFeedbackMonitoring(using: snapshot)

        if snapshot.accessibilityGranted && !hasCompletedInitialPreparation {
            ensureModelsPrepared()
        }

        guard let previousSnapshot else {
            if snapshot.accessibilityGranted {
                ensureHotkeyRegistered(showFailureNotification: false)
            }
            return
        }

        if previousSnapshot.accessibilityGranted == snapshot.accessibilityGranted {
            return
        }

        if snapshot.accessibilityGranted {
            ensureHotkeyRegistered(showFailureNotification: true)
            statusBarController?.showToolbarNotification("Accessibility permission granted.")
            return
        }

        hotkeyManager.unregister()
        stopHotkeyRecoveryLoop()
        hasShownHotkeyRecoveryNotification = false
        statusBarController?.showToolbarNotification(
            NotificationMessage.hotkeyRevoked
        )
    }

    private func ensureModelsPrepared() {
        guard !hasCompletedInitialPreparation else {
            return
        }

        hasCompletedInitialPreparation = true
        Task { [weak self] in
            await self?.checkAndDownloadModels()
        }
    }

    private func runInitialPermissionOnboardingIfNeeded() async {
        let defaults = UserDefaults.standard
        let hasRequestedPermissions = defaults.bool(forKey: DefaultsKeys.didRequestInitialPermissions)

        if !hasRequestedPermissions {
            if !permissionsCoordinator.accessibilityGranted {
                permissionsCoordinator.promptAccessibility()
            }

            _ = await permissionsCoordinator.requestMicrophoneAccessIfNeeded()
            defaults.set(true, forKey: DefaultsKeys.didRequestInitialPermissions)
        }

        permissionsCoordinator.refreshNow()

        guard permissionsCoordinator.accessibilityGranted else {
            statusBarController?.showToolbarNotification(
                NotificationMessage.hotkeyNeedsAccessibility
            )
            return
        }

        ensureHotkeyRegistered(showFailureNotification: true)
    }

    // MARK: - Hotkey Handling
    private func handleHotkeyEvent(_ eventType: HotkeyEventType) {
        switch eventType {
        case .pressed:
            handleHotkeyPressed()
        case .released:
            handleHotkeyReleased()
        }
    }

    // MARK: - Recording Actions
    private func handleHotkeyPressed() {
        switch currentState {
        case .recording:
            guard currentInteractionMode == .listenToggle else { return }
            playStopChimeIfNeeded()
            stopRecording()
            resumeMediaIfNeeded()
            return
        case .processing:
            return
        case .idle, .downloading, .loadingModel:
            break
        }

        guard !notifyMissingPermissionsOnHotkeyPressIfNeeded() else {
            return
        }

        switch currentState {
        case .downloading, .loadingModel:
            showNotReadyNotification()
            return
        case .idle:
            break
        case .recording, .processing:
            return
        }

        guard dictationController.isReady else {
            showNotReadyNotification()
            return
        }

        StreamingMetrics.shared.markTriggerPressed()
        isListeningHotkeyHeld = true
        shouldPlayStopChimeForCurrentSession = false

        let requiresHeldHotkey = currentInteractionMode == .holdToTalk
        Task { [weak self] in
            await self?.beginListeningFromHotkeyTrigger(requiresHeldHotkey: requiresHeldHotkey)
        }
    }

    private func handleHotkeyReleased() {
        isListeningHotkeyHeld = false
        guard currentInteractionMode == .holdToTalk else {
            return
        }

        playStopChimeIfNeeded()

        if currentState == .recording {
            stopRecording()
            resumeMediaIfNeeded()
        }
    }

    private func beginListeningFromHotkeyTrigger(requiresHeldHotkey: Bool) async {
        guard currentState == .idle else { return }

        // Check if models are ready
        guard dictationController.isReady else {
            showNotReadyNotification()
            return
        }

        guard !requiresHeldHotkey || isListeningHotkeyHeld else {
            return
        }

        let didStartRecording = startRecordingIfReady()

        guard didStartRecording else {
            shouldPlayStopChimeForCurrentSession = false
            return
        }

        guard ListeningMediaPreference.load() else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            let didPauseMedia = await self.mediaPlaybackController.pauseIfActive()
            guard didPauseMedia else { return }

            if self.currentState != .recording {
                self.resumeMediaIfNeeded()
            }
        }
    }

    private func playStartChimeIfEnabled() {
        guard MicrophoneChimePreference.load() else {
            shouldPlayStopChimeForCurrentSession = false
            return
        }

        shouldPlayStopChimeForCurrentSession = dictationController.playStartChime()
    }

    private func playStopChimeIfNeeded() {
        guard shouldPlayStopChimeForCurrentSession else { return }
        _ = dictationController.playStopChime()
        shouldPlayStopChimeForCurrentSession = false
    }

    @discardableResult
    private func startRecordingIfReady() -> Bool {
        // Check if models are ready
        guard dictationController.isReady else {
            showNotReadyNotification()
            return false
        }

        guard permissionsCoordinator.accessibilityGranted else {
            statusBarController?.showToolbarNotification(
                NotificationMessage.hotkeyRequiresAccessibility
            )
            return false
        }

        switch permissionsCoordinator.microphoneStatus {
        case .authorized:
            break
        case .notDetermined:
            statusBarController?.showToolbarNotification(
                NotificationMessage.micPermissionPending
            )
            Task { [weak self] in
                _ = await self?.permissionsCoordinator.requestMicrophoneAccessIfNeeded()
            }
            return false
        case .denied, .restricted:
            statusBarController?.showToolbarNotification(
                NotificationMessage.micPermissionDenied
            )
            return false
        @unknown default:
            statusBarController?.showToolbarNotification(
                NotificationMessage.micPermissionUnknown
            )
            return false
        }

        // Start audio recording
        do {
            try dictationController.startRecording(onCaptureReady: { [weak self] in
                self?.handleCaptureReadyForCurrentSession()
            })
            return true
        } catch {
            if let audioError = error as? AudioError, case .permissionDenied = audioError {
                statusBarController?.showToolbarNotification(
                    NotificationMessage.micPermissionDenied
                )
            }
            print("❌ Failed to start recording: \(error)")
            return false
        }
    }

    private func handleCaptureReadyForCurrentSession() {
        guard dictationController.state == .recording else { return }
        if currentInteractionMode == .holdToTalk && !isListeningHotkeyHeld {
            return
        }

        playStartChimeIfEnabled()
    }

    private func resumeMediaIfNeeded() {
        mediaPlaybackController.resumeIfNeeded()
    }

    private func showNotReadyNotification() {
        let message: String
        switch currentState {
        case .downloading:
            message = "VoiceClutch is downloading model"
        case .loadingModel:
            message = "VoiceClutch is loading model"
        default:
            message = "VoiceClutch is still getting ready"
        }

        statusBarController?.showToolbarNotification(message)
    }

    private func updateMissingPermissionShortcutFeedbackMonitoring(using snapshot: PermissionSnapshot) {
        let microphoneGranted = snapshot.microphoneStatus == .authorized
        let hasMissingPermissions = !snapshot.accessibilityGranted || !microphoneGranted
        guard hasMissingPermissions else {
            missingPermissionShortcutFeedbackTimer?.invalidate()
            missingPermissionShortcutFeedbackTimer = nil
            isMissingPermissionShortcutCurrentlyPressed = false
            return
        }

        guard missingPermissionShortcutFeedbackTimer == nil else {
            return
        }

        missingPermissionShortcutFeedbackTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollMissingPermissionShortcutState()
            }
        }
    }

    private func pollMissingPermissionShortcutState() {
        let requiredKeyCodes = currentListeningShortcutConfig.requiredKeyCodes
        guard !requiredKeyCodes.isEmpty else {
            isMissingPermissionShortcutCurrentlyPressed = false
            return
        }

        let allKeysPressed = requiredKeyCodes.allSatisfy { keyCode in
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
        }

        if allKeysPressed && !isMissingPermissionShortcutCurrentlyPressed {
            _ = notifyMissingPermissionsOnHotkeyPressIfNeeded()
        }

        isMissingPermissionShortcutCurrentlyPressed = allKeysPressed
    }

    private func notifyMissingPermissionsOnHotkeyPressIfNeeded() -> Bool {
        let accessibilityGranted = permissionsCoordinator.accessibilityGranted
        let microphoneStatus = permissionsCoordinator.microphoneStatus
        let microphoneGranted = microphoneStatus == .authorized
        guard !accessibilityGranted || !microphoneGranted else {
            return false
        }

        statusBarController?.showToolbarNotification(NotificationMessage.permissionsMissing)

        if microphoneStatus == .notDetermined {
            Task { [weak self] in
                _ = await self?.permissionsCoordinator.requestMicrophoneAccessIfNeeded()
            }
        }

        return true
    }

    func stopRecording() {
        dictationController.stopRecording()
    }
}
