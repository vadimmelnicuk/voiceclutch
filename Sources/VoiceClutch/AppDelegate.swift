import AppKit
import Combine
import CoreGraphics
import Dispatch

// Import core components
@preconcurrency import AVFoundation

// Timestamp formatter matching log format [HH:MM:SS.mmm]
extension DateFormatter {
    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "[HH:mm:ss.SSS]"
        return formatter
    }()
}

private func makeMemoryPressureEventHandler(
    source: DispatchSourceMemoryPressure,
    owner: AppDelegate
) -> @Sendable () -> Void {
    { [weak owner, unowned source] in
        let eventMask = source.data
        guard eventMask.contains(.warning) || eventMask.contains(.critical) else {
            return
        }

        Task { @MainActor [weak owner] in
            owner?.handleMemoryPressureEvent(eventMask)
        }
    }
}

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
        if !dictationController.areModelsInstalled() {
            dictationController.setState(.loadingModel)
        }
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
                await showFirstLaunchAlert(sizeBytes: downloadSizeBytes)
            } else {
                // Fall back to showing alert without size
                await showFirstLaunchAlert(sizeBytes: nil)
            }

            dictationController.setState(.downloading)
        }

        // Start LLM preload in parallel with ASR preparation
        LocalLLMCoordinator.preloadModelInBackground()

        do {
            let outcome = try await dictationController.prepareForUse()
            #if DEBUG
            let timestamp = DateFormatter.timestamp.string(from: Date())
            print("\(timestamp) ✅ VoiceClutch ready")
            #endif

            if outcome == .downloadedModels {
                showDownloadCompleteNotification()
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

    private func showFirstLaunchAlert(sizeBytes: Int64?) async {
        let alert = NSAlert()
        alert.messageText = "Downloading required models"

        let sizeText: String
        if let sizeBytes = sizeBytes {
            let sizeGB = Double(sizeBytes) / 1_073_741_824.0
            let roundedGB = (sizeGB * 10).rounded() / 10
            if roundedGB == floor(roundedGB) {
                sizeText = "\(Int(roundedGB)) GB"
            } else {
                sizeText = String(format: "%.1f GB", roundedGB)
            }
        } else {
            sizeText = "1 GB"
        }

        alert.informativeText = "VoiceClutch needs to download local models (\(sizeText)). This only happens once."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showDownloadCompleteNotification() {
        statusBarController?.showToolbarNotification(
            "VoiceClutch is ready.\nPress and hold Left Control to start dictation.",
            duration: 5.0
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cancel dispatch sources FIRST before any other cleanup
        memoryPressureSource?.cancel()
        memoryPressureSource = nil

        hotkeyManager.unregister()
        hotkeyRecoveryTimer?.invalidate()
        hotkeyRecoveryTimer = nil
        missingPermissionShortcutFeedbackTimer?.invalidate()
        missingPermissionShortcutFeedbackTimer = nil
        permissionsCoordinator.stopMonitoring()
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
            permissionsCoordinator: permissionsCoordinator
        )
    }

    private func setupCorrectionLearning() {
        CorrectionLearningMonitor.shared.installEventMonitors()
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

        dictationController.$downloadModelLabel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] label in
                self?.statusBarController?.updateDownloadModelLabel(label)
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
            DispatchQueue.main.async { [weak self] in
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

        // The dispatch source may fire on a background queue, so capture its
        // data there and hop explicitly to MainActor before touching app state.
        source.setEventHandler(handler: makeMemoryPressureEventHandler(source: source, owner: self))

        source.resume()
        memoryPressureSource = source
    }

    fileprivate func handleMemoryPressureEvent(_ eventMask: DispatchSource.MemoryPressureEvent) {
        guard eventMask.contains(.warning) || eventMask.contains(.critical) else { return }
        let level: LocalLLMMemoryPressureLevel = eventMask.contains(.critical) ? .critical : .warning
        dictationController.handleMemoryPressure(level: level)
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
        case .idle, .downloading, .loadingModel, .warmingUp:
            break
        }

        guard !notifyMissingPermissionsOnHotkeyPressIfNeeded() else {
            return
        }

        switch currentState {
        case .downloading, .loadingModel, .warmingUp:
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

        // We're already on MainActor (AppDelegate is @MainActor), so we can await directly
        let didPauseMedia = await mediaPlaybackController.pauseIfActive()
        guard didPauseMedia else { return }

        if currentState != .recording {
            resumeMediaIfNeeded()
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
            message = "VoiceClutch is loading models"
        case .warmingUp:
            message = "VoiceClutch is warming up"
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
            DispatchQueue.main.async { [weak self] in
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
