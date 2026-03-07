import AudioToolbox

enum MicrophoneChimePlayer {
    // Native system sounds used by dictation-style recording start/stop chimes.
    private static let pressSoundID: SystemSoundID = 1113
    private static let releaseSoundID: SystemSoundID = 1114

    static func playPressChime() {
        AudioServicesPlaySystemSound(pressSoundID)
    }

    static func playReleaseChime() {
        AudioServicesPlaySystemSound(releaseSoundID)
    }
}
