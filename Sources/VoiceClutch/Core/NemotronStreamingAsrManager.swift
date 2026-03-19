import AVFoundation
@preconcurrency import CoreML
import Foundation

enum NemotronModelRepository {
    static let remotePath = "FluidInference/nemotron-speech-streaming-en-0.6b-coreml"
    static let subPath = "nemotron_coreml_560ms"
    static let folderName = "nemotron-streaming/560ms"
    static let requiredPaths: Set<String> = [
        "preprocessor.mlmodelc",
        "encoder/encoder_int8.mlmodelc",
        "decoder.mlmodelc",
        "joint.mlmodelc",
        "tokenizer.json",
        "metadata.json",
    ]
}

struct NemotronStreamingConfig: Sendable {
    let sampleRate: Int
    let melFeatures: Int
    let chunkMelFrames: Int
    let chunkMs: Int
    let preEncodeCache: Int
    let totalMelFrames: Int
    let vocabSize: Int
    let blankIdx: Int
    let encoderDim: Int
    let decoderHidden: Int
    let decoderLayers: Int
    let cacheChannelShape: [Int]
    let cacheTimeShape: [Int]

    var chunkSamples: Int { chunkMelFrames * 160 }

    init() {
        self.sampleRate = 16_000
        self.melFeatures = 128
        self.chunkMelFrames = 56
        self.chunkMs = 560
        self.preEncodeCache = 9
        self.totalMelFrames = 65
        self.vocabSize = 1_024
        self.blankIdx = 1_024
        self.encoderDim = 1_024
        self.decoderHidden = 640
        self.decoderLayers = 2
        self.cacheChannelShape = [1, 24, 70, 1_024]
        self.cacheTimeShape = [1, 24, 1_024, 8]
    }

    init(from metadataURL: URL) throws {
        let data = try Data(contentsOf: metadataURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        self.sampleRate = json["sample_rate"] as? Int ?? 16_000
        self.melFeatures = json["mel_features"] as? Int ?? 128
        self.chunkMelFrames = json["chunk_mel_frames"] as? Int ?? 56
        self.chunkMs = json["chunk_ms"] as? Int ?? 560
        self.preEncodeCache = json["pre_encode_cache"] as? Int ?? 9
        self.totalMelFrames = json["total_mel_frames"] as? Int ?? 65
        self.vocabSize = json["vocab_size"] as? Int ?? 1_024
        self.blankIdx = json["blank_idx"] as? Int ?? 1_024
        self.encoderDim = json["encoder_dim"] as? Int ?? 1_024
        self.decoderHidden = json["decoder_hidden"] as? Int ?? 640
        self.decoderLayers = json["decoder_layers"] as? Int ?? 2
        self.cacheChannelShape = json["cache_channel_shape"] as? [Int] ?? [1, 24, 70, 1_024]
        self.cacheTimeShape = json["cache_time_shape"] as? [Int] ?? [1, 24, 1_024, 8]
    }
}

enum NemotronStreamingError: Error, LocalizedError {
    case notInitialized
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Nemotron streaming ASR is not initialized."
        case .processingFailed(let message):
            return "Nemotron streaming ASR failed: \(message)"
        }
    }
}

typealias NemotronPartialCallback = @Sendable (String) -> Void

final class NemotronTokenizer: @unchecked Sendable {
    private struct TokenPiece {
        let id: Int
        let value: String
    }

    private let idToToken: [Int: String]
    private let tokenCandidatesByFirstCharacter: [Character: [TokenPiece]]

    init(vocabPath: URL) throws {
        let data = try Data(contentsOf: vocabPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]

        var idToToken: [Int: String] = [:]
        var candidates: [Character: [TokenPiece]] = [:]

        for (key, value) in json {
            guard let id = Int(key), value != "<unk>", let firstCharacter = value.first else { continue }
            idToToken[id] = value
            candidates[firstCharacter, default: []].append(TokenPiece(id: id, value: value))
        }

        self.idToToken = idToToken
        self.tokenCandidatesByFirstCharacter = candidates.mapValues { pieces in
            pieces.sorted { lhs, rhs in
                if lhs.value.count == rhs.value.count {
                    return lhs.id < rhs.id
                }
                return lhs.value.count > rhs.value.count
            }
        }
    }

    func decode(ids: [Int]) -> String {
        var text = ""
        for id in ids {
            if let token = idToToken[id] {
                text += token
            }
        }
        return text
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func tokenValue(for id: Int) -> String? {
        idToToken[id]
    }

    func encodeTerm(_ text: String) -> [Int]? {
        let sanitized = CustomVocabularyManager.sanitizedTerm(text)
        guard !sanitized.isEmpty else { return nil }

        let surfaceForm = sanitized
            .split(whereSeparator: \.isWhitespace)
            .map { "\u{2581}" + String($0) }
            .joined()

        var memo: [Int: [Int]?] = [:]
        return bestEncoding(of: surfaceForm, from: surfaceForm.startIndex, memo: &memo)
    }

    private func bestEncoding(
        of surface: String,
        from index: String.Index,
        memo: inout [Int: [Int]?]
    ) -> [Int]? {
        let offset = surface.distance(from: surface.startIndex, to: index)
        if let cached = memo[offset] {
            return cached
        }

        guard index < surface.endIndex else {
            return []
        }

        guard let firstCharacter = surface[index...].first else {
            return []
        }

        var bestSequence: [Int]?
        for candidate in tokenCandidatesByFirstCharacter[firstCharacter] ?? [] {
            guard surface[index...].hasPrefix(candidate.value) else { continue }
            let nextIndex = surface.index(index, offsetBy: candidate.value.count)
            guard let suffix = bestEncoding(of: surface, from: nextIndex, memo: &memo) else { continue }

            let currentSequence = [candidate.id] + suffix
            if let existingBest = bestSequence {
                if currentSequence.count < existingBest.count {
                    self.store(sequence: currentSequence, at: offset, memo: &memo)
                    bestSequence = currentSequence
                    continue
                }

                if currentSequence.count == existingBest.count,
                   candidate.value.count > (tokenValue(for: existingBest[0])?.count ?? 0) {
                    self.store(sequence: currentSequence, at: offset, memo: &memo)
                    bestSequence = currentSequence
                }
            } else {
                self.store(sequence: currentSequence, at: offset, memo: &memo)
                bestSequence = currentSequence
            }
        }

        if bestSequence == nil {
            memo[offset] = nil
        }
        return bestSequence
    }

    private func store(sequence: [Int], at offset: Int, memo: inout [Int: [Int]?]) {
        memo[offset] = sequence
    }
}

actor NemotronStreamingAsrManager {
    private let logger = AppLogger(category: "VoiceClutchNemotron")
    private let audioConverter = AudioConverter()

    private var preprocessor: MLModel?
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var joint: MLModel?
    private var tokenizer: NemotronTokenizer?

    private var config: NemotronStreamingConfig
    private var mlConfiguration: MLModelConfiguration

    private var audioBuffer: [Float] = []
    private var accumulatedTokenIds: [Int] = []

    private var cacheChannel: MLMultiArray?
    private var cacheTime: MLMultiArray?
    private var cacheLen: MLMultiArray?
    private var melCache: MLMultiArray?
    private var hState: MLMultiArray?
    private var cState: MLMultiArray?
    private var lastToken: Int32

    private var partialCallback: NemotronPartialCallback?
    private var processedChunks = 0

    init(configuration: MLModelConfiguration = MLModelConfiguration()) {
        self.mlConfiguration = configuration
        self.config = NemotronStreamingConfig()
        self.lastToken = Int32(config.blankIdx)
    }

    var chunkSampleCount: Int {
        config.chunkSamples
    }

    func setPartialCallback(_ callback: @escaping NemotronPartialCallback) {
        self.partialCallback = callback
    }

    func loadModels(modelDir: URL) async throws {
        logger.info("Loading from \(modelDir.path)")

        let metadataPath = modelDir.appendingPathComponent("metadata.json")
        if FileManager.default.fileExists(atPath: metadataPath.path) {
            self.config = try NemotronStreamingConfig(from: metadataPath)
        }

        self.preprocessor = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("preprocessor.mlmodelc"),
            configuration: mlConfiguration
        )
        self.encoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("encoder/encoder_int8.mlmodelc"),
            configuration: mlConfiguration
        )
        self.decoder = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("decoder.mlmodelc"),
            configuration: mlConfiguration
        )
        self.joint = try await MLModel.load(
            contentsOf: modelDir.appendingPathComponent("joint.mlmodelc"),
            configuration: mlConfiguration
        )
        self.tokenizer = try NemotronTokenizer(vocabPath: modelDir.appendingPathComponent("tokenizer.json"))

        try resetStates()
        logger.info("Loaded successfully")
    }

    func reset() async {
        audioBuffer.removeAll()
        accumulatedTokenIds.removeAll()
        processedChunks = 0
        try? resetStates()
    }

    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String {
        let samples = try audioConverter.resampleBuffer(audioBuffer)
        self.audioBuffer.append(contentsOf: samples)

        while self.audioBuffer.count >= config.chunkSamples {
            let chunk = Array(self.audioBuffer.prefix(config.chunkSamples))
            try await processChunk(chunk)
            self.audioBuffer.removeFirst(config.chunkSamples)
        }

        return ""
    }

    func finish() async throws -> String {
        if !audioBuffer.isEmpty {
            let paddingNeeded = max(0, config.chunkSamples - audioBuffer.count)
            if paddingNeeded > 0 {
                audioBuffer.append(contentsOf: repeatElement(0, count: paddingNeeded))
            }

            let chunk = Array(audioBuffer.prefix(config.chunkSamples))
            try await processChunk(chunk)
            audioBuffer.removeAll()
        }

        guard let tokenizer else {
            throw NemotronStreamingError.notInitialized
        }

        let transcript = tokenizer.decode(ids: accumulatedTokenIds)
        accumulatedTokenIds.removeAll()
        return transcript
    }

    private func resetStates() throws {
        cacheChannel = try MLMultiArray(
            shape: config.cacheChannelShape.map { NSNumber(value: $0) },
            dataType: .float32
        )
        cacheChannel?.reset(to: 0)

        cacheTime = try MLMultiArray(
            shape: config.cacheTimeShape.map { NSNumber(value: $0) },
            dataType: .float32
        )
        cacheTime?.reset(to: 0)

        cacheLen = try MLMultiArray(shape: [1], dataType: .int32)
        cacheLen?.reset(to: 0)

        melCache = nil

        hState = try MLMultiArray(
            shape: [NSNumber(value: config.decoderLayers), 1, NSNumber(value: config.decoderHidden)],
            dataType: .float32
        )
        hState?.reset(to: 0)

        cState = try MLMultiArray(
            shape: [NSNumber(value: config.decoderLayers), 1, NSNumber(value: config.decoderHidden)],
            dataType: .float32
        )
        cState?.reset(to: 0)

        lastToken = Int32(config.blankIdx)
    }

    private func processChunk(_ samples: [Float]) async throws {
        guard
            let preprocessor,
            let encoder,
            let decoder,
            let joint,
            let cacheChannel,
            let cacheTime,
            let cacheLen,
            var currentH = hState,
            var currentC = cState
        else {
            throw NemotronStreamingError.notInitialized
        }

        let audioArray = try createAudioArray(samples)
        let audioLength = try MLMultiArray(shape: [1], dataType: .int32)
        audioLength[0] = NSNumber(value: samples.count)

        let preprocessorInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audioArray),
            "audio_length": MLFeatureValue(multiArray: audioLength),
        ])

        let preprocessorOutput = try await preprocessor.prediction(from: preprocessorInput)
        guard let chunkMel = preprocessorOutput.featureValue(for: "mel")?.multiArrayValue else {
            throw NemotronStreamingError.processingFailed("Missing mel output")
        }

        let inputMel = try buildEncoderMel(chunkMel: chunkMel)
        let melLength = try MLMultiArray(shape: [1], dataType: .int32)
        melLength[0] = NSNumber(value: config.totalMelFrames)

        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: inputMel),
            "mel_length": MLFeatureValue(multiArray: melLength),
            "cache_channel": MLFeatureValue(multiArray: cacheChannel),
            "cache_time": MLFeatureValue(multiArray: cacheTime),
            "cache_len": MLFeatureValue(multiArray: cacheLen),
        ])

        let encoderOutput = try await encoder.prediction(from: encoderInput)
        self.cacheChannel = encoderOutput.featureValue(for: "cache_channel_out")?.multiArrayValue
        self.cacheTime = encoderOutput.featureValue(for: "cache_time_out")?.multiArrayValue
        self.cacheLen = encoderOutput.featureValue(for: "cache_len_out")?.multiArrayValue

        guard let encoded = encoderOutput.featureValue(for: "encoded")?.multiArrayValue else {
            throw NemotronStreamingError.processingFailed("Missing encoder output")
        }

        melCache = try extractMelCache(from: chunkMel)

        let numberOfFrames = encoded.shape[2].intValue
        var decodedNewTokens = false

        for timeIndex in 0..<numberOfFrames {
            let encoderStep = try extractEncoderStep(from: encoded, timeIndex: timeIndex)

            for _ in 0..<10 {
                let tokenInput = try MLMultiArray(shape: [1, 1], dataType: .int32)
                tokenInput[0] = NSNumber(value: lastToken)

                let tokenLength = try MLMultiArray(shape: [1], dataType: .int32)
                tokenLength[0] = 1

                let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
                    "token": MLFeatureValue(multiArray: tokenInput),
                    "token_length": MLFeatureValue(multiArray: tokenLength),
                    "h_in": MLFeatureValue(multiArray: currentH),
                    "c_in": MLFeatureValue(multiArray: currentC),
                ])

                let decoderOutput = try await decoder.prediction(from: decoderInput)
                guard
                    let decoderProjection = decoderOutput.featureValue(for: "decoder_out")?.multiArrayValue,
                    let hOut = decoderOutput.featureValue(for: "h_out")?.multiArrayValue,
                    let cOut = decoderOutput.featureValue(for: "c_out")?.multiArrayValue
                else {
                    throw NemotronStreamingError.processingFailed("Missing decoder output")
                }

                let decoderStep = try sliceDecoderOutput(decoderProjection)
                let jointInput = try MLDictionaryFeatureProvider(dictionary: [
                    "encoder": MLFeatureValue(multiArray: encoderStep),
                    "decoder": MLFeatureValue(multiArray: decoderStep),
                ])

                let jointOutput = try await joint.prediction(from: jointInput)
                guard let logits = jointOutput.featureValue(for: "logits")?.multiArrayValue else {
                    throw NemotronStreamingError.processingFailed("Missing joint output")
                }

                let predictedToken = argmax(logits)
                if predictedToken == config.blankIdx {
                    break
                }

                decodedNewTokens = true
                accumulatedTokenIds.append(predictedToken)
                lastToken = Int32(predictedToken)
                currentH = hOut
                currentC = cOut
            }
        }

        hState = currentH
        cState = currentC
        processedChunks += 1

        if decodedNewTokens, let partialCallback, let tokenizer {
            partialCallback(tokenizer.decode(ids: accumulatedTokenIds))
        }
    }

    private func argmax(_ logits: MLMultiArray) -> Int {
        let vocabularySize = config.vocabSize + 1
        let pointer = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)

        var bestIndex = 0
        var bestValue = pointer[0]
        for index in 1..<vocabularySize {
            let candidate = pointer[index]
            if candidate > bestValue {
                bestValue = candidate
                bestIndex = index
            }
        }

        return bestIndex
    }
    private func createAudioArray(_ samples: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: samples.count)], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
        pointer.update(from: samples, count: samples.count)
        return array
    }

    private func buildEncoderMel(chunkMel: MLMultiArray) throws -> MLMultiArray {
        let chunkFrames = chunkMel.shape[2].intValue
        let totalFrames = config.totalMelFrames
        let result = try MLMultiArray(
            shape: [1, NSNumber(value: config.melFeatures), NSNumber(value: totalFrames)],
            dataType: .float32
        )
        result.reset(to: 0)

        let resultPointer = result.dataPointer.bindMemory(to: Float.self, capacity: result.count)
        let chunkPointer = chunkMel.dataPointer.bindMemory(to: Float.self, capacity: chunkMel.count)

        if let melCache {
            let cachePointer = melCache.dataPointer.bindMemory(to: Float.self, capacity: melCache.count)
            let cacheFrames = melCache.shape[2].intValue
            for melIndex in 0..<config.melFeatures {
                for frameIndex in 0..<cacheFrames {
                    let sourceIndex = melIndex * cacheFrames + frameIndex
                    let destinationIndex = melIndex * totalFrames + frameIndex
                    resultPointer[destinationIndex] = cachePointer[sourceIndex]
                }
            }
        }

        let copyFrames = min(chunkFrames, totalFrames - config.preEncodeCache)
        for melIndex in 0..<config.melFeatures {
            for frameIndex in 0..<copyFrames {
                let sourceIndex = melIndex * chunkFrames + frameIndex
                let destinationIndex = melIndex * totalFrames + config.preEncodeCache + frameIndex
                resultPointer[destinationIndex] = chunkPointer[sourceIndex]
            }
        }

        return result
    }

    private func extractMelCache(from chunkMel: MLMultiArray) throws -> MLMultiArray {
        let chunkFrames = chunkMel.shape[2].intValue
        let cacheFrames = min(config.preEncodeCache, chunkFrames)
        let cache = try MLMultiArray(
            shape: [1, NSNumber(value: config.melFeatures), NSNumber(value: cacheFrames)],
            dataType: .float32
        )

        let sourcePointer = chunkMel.dataPointer.bindMemory(to: Float.self, capacity: chunkMel.count)
        let destinationPointer = cache.dataPointer.bindMemory(to: Float.self, capacity: cache.count)
        let startFrame = chunkFrames - cacheFrames

        for melIndex in 0..<config.melFeatures {
            for frameIndex in 0..<cacheFrames {
                let sourceIndex = melIndex * chunkFrames + startFrame + frameIndex
                let destinationIndex = melIndex * cacheFrames + frameIndex
                destinationPointer[destinationIndex] = sourcePointer[sourceIndex]
            }
        }

        return cache
    }

    private func extractEncoderStep(from encoded: MLMultiArray, timeIndex: Int) throws -> MLMultiArray {
        let hiddenSize = encoded.shape[1].intValue
        let step = try MLMultiArray(shape: [1, NSNumber(value: hiddenSize), 1], dataType: .float32)

        let sourcePointer = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
        let destinationPointer = step.dataPointer.bindMemory(to: Float.self, capacity: step.count)
        let stride0 = encoded.strides[0].intValue
        let stride1 = encoded.strides[1].intValue
        let stride2 = encoded.strides[2].intValue

        for channelIndex in 0..<hiddenSize {
            let sourceIndex = channelIndex * stride1 + timeIndex * stride2 + 0 * stride0
            destinationPointer[channelIndex] = sourcePointer[sourceIndex]
        }

        return step
    }

    private func sliceDecoderOutput(_ decoderOutput: MLMultiArray) throws -> MLMultiArray {
        let hiddenSize = decoderOutput.shape[1].intValue
        let result = try MLMultiArray(shape: [1, NSNumber(value: hiddenSize), 1], dataType: .float32)

        let sourcePointer = decoderOutput.dataPointer.bindMemory(to: Float.self, capacity: decoderOutput.count)
        let destinationPointer = result.dataPointer.bindMemory(to: Float.self, capacity: result.count)
        let stride0 = decoderOutput.strides[0].intValue
        let stride1 = decoderOutput.strides[1].intValue
        let stride2 = decoderOutput.strides[2].intValue

        for channelIndex in 0..<hiddenSize {
            let sourceIndex = channelIndex * stride1 + 0 * stride2 + 0 * stride0
            destinationPointer[channelIndex] = sourcePointer[sourceIndex]
        }

        return result
    }
}
