import Foundation

struct SpeechDetectionConfiguration {
    let threshold: Float
    let targetSampleRate: Double
    let windowThresholdMultiplier: Float
    let requiredConsecutiveSpeechWindows: Int
}

struct SpeechDetectionResult {
    let containsSpeech: Bool
    let rmsEnergy: Float
    let peakAmplitude: Float
    let maxWindowRms: Float
    let longestWindowRun: Int
    let trigger: String
}

enum SpeechDetector {
    static func detect(
        _ buffer: [Float],
        configuration: SpeechDetectionConfiguration
    ) -> SpeechDetectionResult {
        guard !buffer.isEmpty else {
            return SpeechDetectionResult(
                containsSpeech: false,
                rmsEnergy: 0,
                peakAmplitude: 0,
                maxWindowRms: 0,
                longestWindowRun: 0,
                trigger: "none"
            )
        }

        let rmsEnergy = calculateRMSEnergy(buffer)
        let peakAmplitude = buffer.reduce(Float.zero) { currentPeak, sample in
            max(currentPeak, abs(sample))
        }

        let windowSize = max(1, Int(configuration.targetSampleRate * 0.01))
        let permissiveWindowThreshold = configuration.threshold * configuration.windowThresholdMultiplier
        var maxWindowRms = Float.zero
        var currentWindowRun = 0
        var longestWindowRun = 0
        var currentIndex = 0

        while currentIndex < buffer.count {
            let windowEnd = min(currentIndex + windowSize, buffer.count)
            let windowRms = calculateRMSEnergy(buffer[currentIndex..<windowEnd])
            maxWindowRms = max(maxWindowRms, windowRms)

            if windowRms >= permissiveWindowThreshold {
                currentWindowRun += 1
                longestWindowRun = max(longestWindowRun, currentWindowRun)
            } else {
                currentWindowRun = 0
            }

            currentIndex = windowEnd
        }

        let containsSpeech = longestWindowRun >= configuration.requiredConsecutiveSpeechWindows
        let trigger = containsSpeech ? "window_rms" : "none"

        return SpeechDetectionResult(
            containsSpeech: containsSpeech,
            rmsEnergy: rmsEnergy,
            peakAmplitude: peakAmplitude,
            maxWindowRms: maxWindowRms,
            longestWindowRun: longestWindowRun,
            trigger: trigger
        )
    }

    private static func calculateRMSEnergy(_ buffer: [Float]) -> Float {
        calculateRMSEnergy(buffer[...])
    }

    private static func calculateRMSEnergy(_ buffer: ArraySlice<Float>) -> Float {
        guard !buffer.isEmpty else { return 0.0 }

        let sumOfSquares = buffer.reduce(0.0) { $0 + (Double($1) * Double($1)) }
        let rms = sqrt(sumOfSquares / Double(buffer.count))

        return Float(rms)
    }
}
