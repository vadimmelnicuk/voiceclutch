@preconcurrency import AVFoundation
import Foundation

final class AudioConverter {
    private final class ConversionState: @unchecked Sendable {
        var didProvideInput = false
    }

    private let targetFormat: AVAudioFormat

    init(targetFormat: AVAudioFormat? = nil) {
        self.targetFormat = targetFormat ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    func resampleBuffer(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        if isTargetFormat(buffer.format) {
            return extractFloatArray(from: buffer)
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw AudioConverterError.failedToCreateConverter
        }

        let capacityRatio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * capacityRatio))
        )

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw AudioConverterError.failedToCreateBuffer
        }

        let state = ConversionState()
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if state.didProvideInput {
                status.pointee = .endOfStream
                return nil
            }

            state.didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error else {
            throw AudioConverterError.conversionFailed(error)
        }

        return extractFloatArray(from: outputBuffer)
    }

    private func isTargetFormat(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == targetFormat.commonFormat
            && format.sampleRate == targetFormat.sampleRate
            && format.channelCount == targetFormat.channelCount
            && format.isInterleaved == targetFormat.isInterleaved
    }

    private func extractFloatArray(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}

enum AudioConverterError: LocalizedError {
    case failedToCreateConverter
    case failedToCreateBuffer
    case conversionFailed(NSError?)

    var errorDescription: String? {
        switch self {
        case .failedToCreateConverter:
            return "Failed to create audio converter."
        case .failedToCreateBuffer:
            return "Failed to allocate audio buffer."
        case .conversionFailed(let error):
            return error?.localizedDescription ?? "Audio conversion failed."
        }
    }
}
