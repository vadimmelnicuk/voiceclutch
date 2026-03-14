import Foundation

public enum VoiceClutchState: String, Sendable {
    case idle = "idle"
    case recording = "recording"
    case processing = "processing"
    case downloading = "downloading"
    case loadingModel = "loadingModel"
    case warmingUp = "warmingUp"
}
