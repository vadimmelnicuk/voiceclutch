import AppKit
import Combine
import Foundation
@preconcurrency import AVFoundation

struct PermissionSnapshot: Equatable {
    let accessibilityGranted: Bool
    let microphoneStatus: AVAuthorizationStatus
}

@MainActor
final class PermissionsCoordinator: ObservableObject {
    private enum Constants {
        static let refreshInterval: TimeInterval = 2.0
        static let securityPrivacyPane = "x-apple.systempreferences:com.apple.preference.security"
    }

    @Published private(set) var snapshot: PermissionSnapshot

    private var refreshTimer: Timer?
    private var appDidBecomeActiveObserver: NSObjectProtocol?

    var accessibilityGranted: Bool {
        snapshot.accessibilityGranted
    }

    var microphoneStatus: AVAuthorizationStatus {
        snapshot.microphoneStatus
    }

    init() {
        snapshot = Self.currentSnapshot()
    }

    func startMonitoring() {
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: Constants.refreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshNow()
                }
            }
        }

        if appDidBecomeActiveObserver == nil {
            appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshNow()
                }
            }
        }

        refreshNow()
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        if let observer = appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            appDidBecomeActiveObserver = nil
        }
    }

    func refreshNow() {
        let current = Self.currentSnapshot()
        guard current != snapshot else {
            return
        }
        snapshot = current
    }

    func promptAccessibility() {
        let options = NSMutableDictionary()
        options.setObject(true, forKey: "AXTrustedCheckOptionPrompt" as NSString)
        AXIsProcessTrustedWithOptions(options)
        refreshNow()
    }

    func requestMicrophoneAccessIfNeeded() async -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            refreshNow()
            return status
        }

        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                continuation.resume(returning: allowed)
            }
        }

        refreshNow()
        return granted ? .authorized : .denied
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    private func openPrivacySettings(anchor: String) {
        guard let anchorURL = URL(string: "\(Constants.securityPrivacyPane)?\(anchor)") else {
            return
        }

        if NSWorkspace.shared.open(anchorURL) {
            return
        }

        guard let fallbackURL = URL(string: Constants.securityPrivacyPane) else {
            return
        }
        _ = NSWorkspace.shared.open(fallbackURL)
    }

    private static func currentSnapshot() -> PermissionSnapshot {
        let options = NSMutableDictionary()
        options.setObject(false, forKey: "AXTrustedCheckOptionPrompt" as NSString)
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return PermissionSnapshot(
            accessibilityGranted: accessibilityGranted,
            microphoneStatus: microphoneStatus
        )
    }
}
