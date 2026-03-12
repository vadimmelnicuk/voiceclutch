import Foundation
@preconcurrency import AVFoundation

enum MicrophoneChimePlayer {
    private static let resourceDirectoryName = "Chimes"

    enum Sound {
        case press
        case release
    }

    struct Resources {
        let format: AVAudioFormat
        let pressBuffer: AVAudioPCMBuffer
        let releaseBuffer: AVAudioPCMBuffer

        func buffer(for sound: Sound) -> AVAudioPCMBuffer {
            switch sound {
            case .press:
                pressBuffer
            case .release:
                releaseBuffer
            }
        }
    }

    private enum ResourceError: Error, LocalizedError {
        case missingResource(String)
        case invalidAudioBuffer(String)
        case formatMismatch

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "Missing microphone chime resource: \(name)"
            case .invalidAudioBuffer(let name):
                return "Failed to decode microphone chime resource: \(name)"
            case .formatMismatch:
                return "Microphone chime resources use mismatched audio formats"
            }
        }
    }

    private static let cachedResources: Resources? = {
        do {
            return try makeResources()
        } catch {
            #if DEBUG
            print("⚠️ Failed to load microphone chimes: \(error.localizedDescription)")
            #endif
            return nil
        }
    }()

    static func loadResources() -> Resources? {
        cachedResources
    }

    private static func makeResources() throws -> Resources {
        let pressBuffer = try loadBuffer(named: "start")
        let releaseBuffer = try loadBuffer(named: "stop")

        guard formatsMatch(pressBuffer.format, releaseBuffer.format) else {
            throw ResourceError.formatMismatch
        }

        return Resources(
            format: pressBuffer.format,
            pressBuffer: pressBuffer,
            releaseBuffer: releaseBuffer
        )
    }

    private static func loadBuffer(named name: String) throws -> AVAudioPCMBuffer {
        guard let url = resourceURL(named: name) else {
            throw ResourceError.missingResource(name)
        }

        let audioFile = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else {
            throw ResourceError.invalidAudioBuffer(name)
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw ResourceError.invalidAudioBuffer(name)
        }

        try audioFile.read(into: buffer)
        return buffer
    }

    private static func resourceURL(named name: String) -> URL? {
        candidateResourceRoots()
            .map { $0.appendingPathComponent(resourceDirectoryName, isDirectory: true) }
            .map { $0.appendingPathComponent("\(name).wav", isDirectory: false) }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private static func candidateResourceRoots() -> [URL] {
        var candidates: [URL] = []

        if let appResourceURL = Bundle.main.resourceURL {
            candidates.append(appResourceURL)
        }

        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        candidates.append(currentDirectoryURL.appendingPathComponent("Resources", isDirectory: true))

        let executableURL = Bundle.main.bundleURL.standardizedFileURL
        let executableParent = executableURL.deletingLastPathComponent()
        let executableGrandparent = executableParent.deletingLastPathComponent()
        candidates.append(executableGrandparent.appendingPathComponent("Resources", isDirectory: true))

        var deduplicated: [URL] = []
        var seenPaths = Set<String>()
        for candidate in candidates {
            let standardizedPath = candidate.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else {
                continue
            }
            deduplicated.append(candidate)
        }

        return deduplicated
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
        lhs.channelCount == rhs.channelCount &&
        lhs.sampleRate == rhs.sampleRate &&
        lhs.isInterleaved == rhs.isInterleaved
    }
}
