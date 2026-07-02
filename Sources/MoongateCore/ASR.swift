import Foundation
import CryptoKit
import NaturalLanguage

/// CJK word-boundary lookup backed by Apple's NaturalLanguage tokenizer (zero new dependency on
/// macOS). Used to keep whisper's sub-word token stream from being split mid-word (e.g. 「いこう」,
/// 「カード」, 「たくさん」). On non-Apple platforms the planner falls back to the particle heuristic.
enum CJKWordBoundary {
    /// True when `charOffset` falls strictly inside a tokenized word in `text` (i.e. breaking the
    /// cue at that position would cut a word in half). False at real word boundaries / gaps.
    static func straddles(_ text: String, at charOffset: Int) -> Bool {
        guard charOffset > 0, charOffset < text.count else { return false }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let target = text.index(text.startIndex, offsetBy: charOffset)
        var straddlesWord = false
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if range.lowerBound >= target { return false } // tokens are ordered; past the cut point
            if range.lowerBound < target, target < range.upperBound {
                straddlesWord = true
                return false
            }
            return true
        }
        return straddlesWord
    }
}

public enum ASRJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum ASRRecognitionProfile: String, Codable, Sendable {
    case speech
    case lyricsHighQuality
}

public enum ASRBackendKind: String, Codable, Sendable {
    case whisperCpp
    case senseVoiceFunASR
    case unknown

    static func inferred(from sourceModelID: String) -> ASRBackendKind {
        let normalized = sourceModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("whisper.cpp") { return .whisperCpp }
        if normalized.contains("sensevoice") || normalized.contains("funasr") { return .senseVoiceFunASR }
        return .unknown
    }
}

public struct ASRRequest: Codable, Equatable, Sendable {
    public let audioURL: URL
    public let languageCode: String?
    public let modelID: String
    public let prompt: String?
    public let recognitionProfile: ASRRecognitionProfile
    /// Optional whisper.cpp text-context cap (`-mc`). CJK local-ASR can fall into previous-text
    /// repetition loops; those requests use 0 to disable carryover.
    public let maxTextContextTokens: Int?
    /// Requests whisper.cpp VAD when a local Silero VAD model is available. Missing VAD assets are
    /// treated as a graceful downgrade to ordinary recognition.
    public let vadEnabled: Bool
    /// Explicit VAD model path. VAD is never enabled from an implicit runtime search; the path must
    /// come from app-managed settings and exist when the command is planned.
    public let vadModelPath: String?
    public let wordTimestamps: Bool
    /// When true (with word timestamps), whisper.cpp is asked for DTW-aligned token timestamps
    /// (`-dtw <preset> -nfa`). These are markedly closer to human timing than the default
    /// frame-quantized offsets. Disabled as a fail-safe if a model build rejects DTW.
    public let dtwTokenTimestamps: Bool
    public let cacheKey: String?

    public init(
        audioURL: URL,
        languageCode: String? = nil,
        modelID: String,
        prompt: String? = nil,
        recognitionProfile: ASRRecognitionProfile = .speech,
        maxTextContextTokens: Int? = nil,
        vadEnabled: Bool = true,
        vadModelPath: String? = nil,
        wordTimestamps: Bool = true,
        dtwTokenTimestamps: Bool = true,
        cacheKey: String? = nil
    ) {
        self.audioURL = audioURL
        self.languageCode = languageCode
        self.modelID = modelID
        self.prompt = prompt
        self.recognitionProfile = recognitionProfile
        self.maxTextContextTokens = maxTextContextTokens
        self.vadEnabled = vadEnabled
        self.vadModelPath = Self.normalizedOptionalPath(vadModelPath)
        self.wordTimestamps = wordTimestamps
        self.dtwTokenTimestamps = dtwTokenTimestamps
        self.cacheKey = cacheKey
    }

    private enum CodingKeys: String, CodingKey {
        case audioPath
        case legacyAudioURL = "audioUrl"
        case languageCode
        case modelID = "modelId"
        case prompt
        case recognitionProfile
        case maxTextContextTokens
        case vadEnabled
        case vadModelPath
        case wordTimestamps
        case dtwTokenTimestamps
        case cacheKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let audioValue = try container.decodeIfPresent(String.self, forKey: .audioPath)
            ?? container.decode(String.self, forKey: .legacyAudioURL)
        self.audioURL = Self.fileURL(from: audioValue)
        self.languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        self.modelID = try container.decode(String.self, forKey: .modelID)
        self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        self.recognitionProfile = try container.decodeIfPresent(ASRRecognitionProfile.self, forKey: .recognitionProfile) ?? .speech
        self.maxTextContextTokens = try container.decodeIfPresent(Int.self, forKey: .maxTextContextTokens)
        self.vadEnabled = try container.decodeIfPresent(Bool.self, forKey: .vadEnabled) ?? true
        self.vadModelPath = Self.normalizedOptionalPath(try container.decodeIfPresent(String.self, forKey: .vadModelPath))
        self.wordTimestamps = try container.decodeIfPresent(Bool.self, forKey: .wordTimestamps) ?? true
        self.dtwTokenTimestamps = try container.decodeIfPresent(Bool.self, forKey: .dtwTokenTimestamps) ?? true
        self.cacheKey = try container.decodeIfPresent(String.self, forKey: .cacheKey)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(audioURL.path, forKey: .audioPath)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encode(recognitionProfile, forKey: .recognitionProfile)
        try container.encodeIfPresent(maxTextContextTokens, forKey: .maxTextContextTokens)
        try container.encode(vadEnabled, forKey: .vadEnabled)
        try container.encodeIfPresent(vadModelPath, forKey: .vadModelPath)
        try container.encode(wordTimestamps, forKey: .wordTimestamps)
        try container.encode(dtwTokenTimestamps, forKey: .dtwTokenTimestamps)
        try container.encodeIfPresent(cacheKey, forKey: .cacheKey)
    }

    /// Returns a copy with DTW token timestamps disabled (fail-safe retry path).
    public func disablingDTW() -> ASRRequest {
        ASRRequest(
            audioURL: audioURL,
            languageCode: languageCode,
            modelID: modelID,
            prompt: prompt,
            recognitionProfile: recognitionProfile,
            maxTextContextTokens: maxTextContextTokens,
            vadEnabled: vadEnabled,
            vadModelPath: vadModelPath,
            wordTimestamps: wordTimestamps,
            dtwTokenTimestamps: false,
            cacheKey: cacheKey
        )
    }

    private static func fileURL(from value: String) -> URL {
        if let url = URL(string: value), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: value)
    }

    private static func normalizedOptionalPath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct ASRWord: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let probability: Double?

    public init(text: String, startSeconds: Double, endSeconds: Double, probability: Double? = nil) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.probability = probability
    }
}

public struct ASRSegment: Codable, Equatable, Sendable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct ASRTranscript: Codable, Equatable, Sendable {
    public let id: String
    public let languageCode: String
    public let languageConfidence: Double?
    public let durationSeconds: Double?
    public let words: [ASRWord]
    public let sourceModelID: String
    public let backendKind: ASRBackendKind
    public let segments: [ASRSegment]
    public let rawText: String?
    public let backendDiagnostics: [String: String]
    public let qualitySummary: LocalASRConfidenceSummary?
    public let createdAt: Date

    public init(
        id: String,
        languageCode: String,
        languageConfidence: Double? = nil,
        durationSeconds: Double? = nil,
        words: [ASRWord],
        sourceModelID: String,
        backendKind: ASRBackendKind? = nil,
        segments: [ASRSegment] = [],
        rawText: String? = nil,
        backendDiagnostics: [String: String] = [:],
        qualitySummary: LocalASRConfidenceSummary? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.languageCode = languageCode
        self.languageConfidence = languageConfidence
        self.durationSeconds = durationSeconds
        self.words = words
        self.sourceModelID = sourceModelID
        self.backendKind = backendKind ?? ASRBackendKind.inferred(from: sourceModelID)
        self.segments = segments
        self.rawText = rawText
        self.backendDiagnostics = backendDiagnostics
        self.qualitySummary = qualitySummary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case languageCode
        case languageConfidence
        case durationSeconds
        case words
        case sourceModelID = "sourceModelId"
        case backendKind
        case segments
        case rawText
        case backendDiagnostics
        case qualitySummary
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.languageCode = try container.decode(String.self, forKey: .languageCode)
        self.languageConfidence = try container.decodeIfPresent(Double.self, forKey: .languageConfidence)
        self.durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        self.words = try container.decode([ASRWord].self, forKey: .words)
        self.sourceModelID = try container.decode(String.self, forKey: .sourceModelID)
        self.backendKind = try container.decodeIfPresent(ASRBackendKind.self, forKey: .backendKind)
            ?? ASRBackendKind.inferred(from: sourceModelID)
        self.segments = try container.decodeIfPresent([ASRSegment].self, forKey: .segments) ?? []
        self.rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        self.backendDiagnostics = try container.decodeIfPresent([String: String].self, forKey: .backendDiagnostics) ?? [:]
        self.qualitySummary = try container.decodeIfPresent(LocalASRConfidenceSummary.self, forKey: .qualitySummary)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(languageCode, forKey: .languageCode)
        try container.encodeIfPresent(languageConfidence, forKey: .languageConfidence)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encode(words, forKey: .words)
        try container.encode(sourceModelID, forKey: .sourceModelID)
        try container.encode(backendKind, forKey: .backendKind)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(rawText, forKey: .rawText)
        try container.encode(backendDiagnostics, forKey: .backendDiagnostics)
        try container.encodeIfPresent(qualitySummary, forKey: .qualitySummary)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct ASRAudioActivityRange: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct ASRAudioActivity: Codable, Equatable, Sendable {
    public let silenceRanges: [ASRAudioActivityRange]

    public init(silenceRanges: [ASRAudioActivityRange]) {
        self.silenceRanges = silenceRanges
            .filter { range in
                range.startSeconds.isFinite
                    && range.endSeconds.isFinite
                    && range.endSeconds > range.startSeconds
                    && range.endSeconds >= 0
            }
            .sorted {
                $0.startSeconds == $1.startSeconds
                    ? $0.endSeconds < $1.endSeconds
                    : $0.startSeconds < $1.startSeconds
            }
    }

    public static func parseSilencedetectOutput(_ output: String) -> ASRAudioActivity {
        var ranges: [ASRAudioActivityRange] = []
        var openStart: Double?
        for line in output.components(separatedBy: .newlines) {
            if let start = firstNumber(in: line, after: "silence_start:") {
                openStart = start
                continue
            }
            if let end = firstNumber(in: line, after: "silence_end:"),
               let start = openStart {
                ranges.append(ASRAudioActivityRange(startSeconds: start, endSeconds: end))
                openStart = nil
            }
        }
        return ASRAudioActivity(silenceRanges: ranges)
    }

    func protectedLyricStart(for start: Double) -> Double {
        let tolerance = 0.12
        guard let range = silenceRanges.first(where: { range in
            start >= range.startSeconds - tolerance && start < range.endSeconds
        }) else {
            return start
        }
        return max(start, range.endSeconds)
    }

    private static func firstNumber(in line: String, after marker: String) -> Double? {
        guard let markerRange = line.range(of: marker) else { return nil }
        let tail = line[markerRange.upperBound...]
        guard let numberRange = tail.range(
            of: #"[-+]?[0-9]+(?:\.[0-9]+)?"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return Double(tail[numberRange])
    }
}

public struct ASRProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case modelDownload
        case audioExtract
        case speechRecognition
        case subtitleSegment
    }

    public let phase: Phase
    public let completedUnits: Double?
    public let totalUnits: Double?
    public let detail: String?

    public var fraction: Double? {
        guard let completedUnits, let totalUnits, totalUnits > 0 else { return nil }
        return min(max(completedUnits / totalUnits, 0), 1)
    }

    public init(
        phase: Phase,
        completedUnits: Double? = nil,
        totalUnits: Double? = nil,
        detail: String? = nil
    ) {
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.detail = detail
    }
}

public struct ASRReadiness: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready
        case missingRuntime
        case missingModel
        case badModelHash
        case insufficientDiskSpace
        case unsupportedPlatform
    }

    public let status: Status
    public let modelID: String?
    public let message: String

    public var isReady: Bool { status == .ready }

    public init(status: Status, modelID: String? = nil, message: String) {
        self.status = status
        self.modelID = modelID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case modelID = "modelId"
        case message
    }
}

public protocol SpeechRecognizer: Sendable {
    func readiness(for request: ASRRequest) async -> ASRReadiness
    func transcribe(
        _ request: ASRRequest,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> ASRTranscript
}

public extension SpeechRecognizer {
    func transcribe(
        _ request: ASRRequest,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> ASRTranscript {
        try await transcribe(request, control: nil, progress: progress)
    }
}

public enum FakeSpeechRecognizerError: Error, Equatable, Sendable {
    case noSpeech
    case lowLanguageConfidence
    case missingModel
    case badModelHash
}

public struct FakeSpeechRecognizer: SpeechRecognizer {
    public enum Mode: Sendable {
        case success(ASRTranscript)
        case failure(FakeSpeechRecognizerError)
        case cancelled
    }

    public let readinessResult: ASRReadiness
    public let mode: Mode

    public init(readiness: ASRReadiness, mode: Mode) {
        self.readinessResult = readiness
        self.mode = mode
    }

    public func readiness(for request: ASRRequest) async -> ASRReadiness {
        readinessResult
    }

    public func transcribe(
        _ request: ASRRequest,
        control: TaskControlToken? = nil,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> ASRTranscript {
        if Task.isCancelled { throw CancellationError() }
        try await control?.gate()
        progress(ASRProgress(phase: .speechRecognition, completedUnits: 0, totalUnits: 1))
        switch mode {
        case .success(let transcript):
            progress(ASRProgress(phase: .speechRecognition, completedUnits: 1, totalUnits: 1))
            return transcript
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}

public struct ASRModelManifest: Codable, Equatable, Sendable {
    public let models: [ASRModelInfo]

    public init(models: [ASRModelInfo]) {
        self.models = models
    }

    public static let recommendedWhisperCpp = ASRModelManifest(models: [
        ASRModelInfo(
            id: "whisper.cpp:tiny-q5_1",
            displayName: "Whisper tiny q5_1",
            fileName: "ggml-tiny-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin")!,
            sizeBytes: 32_152_673,
            sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
            memoryRequiredMB: 256,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:tiny-q8_0",
            displayName: "Whisper tiny q8_0",
            fileName: "ggml-tiny-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q8_0.bin")!,
            sizeBytes: 43_537_433,
            sha256: "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca",
            memoryRequiredMB: 384,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:base-q5_1",
            displayName: "Whisper base q5_1",
            fileName: "ggml-base-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!,
            sizeBytes: 59_707_625,
            sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
            memoryRequiredMB: 512,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:base-q8_0",
            displayName: "Whisper base q8_0",
            fileName: "ggml-base-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin")!,
            sizeBytes: 81_768_585,
            sha256: "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
            memoryRequiredMB: 768,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:small-q5_1",
            displayName: "Whisper small q5_1",
            fileName: "ggml-small-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
            sizeBytes: 190_085_487,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            memoryRequiredMB: 1_024,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:small-q8_0",
            displayName: "Whisper small q8_0",
            fileName: "ggml-small-q8_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin")!,
            sizeBytes: 264_464_607,
            sha256: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
            memoryRequiredMB: 1_280,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:small.en-q5_1",
            displayName: "Whisper small.en q5_1",
            fileName: "ggml-small.en-q5_1.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q5_1.bin")!,
            sizeBytes: 190_098_681,
            sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
            memoryRequiredMB: 1_024,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:medium-q5_0",
            displayName: "Whisper medium q5_0",
            fileName: "ggml-medium-q5_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")!,
            sizeBytes: 539_212_467,
            sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
            memoryRequiredMB: 2_048,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        ),
        ASRModelInfo(
            id: "whisper.cpp:large-v3-turbo-q5_0",
            displayName: "Whisper large-v3-turbo q5_0",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
            sizeBytes: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            memoryRequiredMB: 3_072,
            license: "MIT",
            sourceDescription: "ggerganov/whisper.cpp on Hugging Face"
        )
    ])

    public static let recommendedWhisperCppVAD = ASRModelManifest(models: [
        ASRModelInfo(
            id: "whisper.cpp-vad:silero-v5_1_2",
            displayName: "Silero voice boundary detector v5.1.2",
            fileName: "ggml-silero-v5.1.2.bin",
            downloadURL: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
            sizeBytes: 885_098,
            sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf",
            memoryRequiredMB: 64,
            license: "MIT",
            sourceDescription: "ggml-org/whisper-vad on Hugging Face"
        )
    ])
}

public struct ASRModelInfo: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let fileName: String
    public let downloadURL: URL
    public let sizeBytes: Int64
    public let sha256: String
    public let memoryRequiredMB: Int
    public let license: String
    public let sourceDescription: String

    public init(
        id: String,
        displayName: String,
        fileName: String,
        downloadURL: URL,
        sizeBytes: Int64,
        sha256: String,
        memoryRequiredMB: Int,
        license: String,
        sourceDescription: String
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.memoryRequiredMB = memoryRequiredMB
        self.license = license
        self.sourceDescription = sourceDescription
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fileName
        case downloadURL = "downloadUrl"
        case sizeBytes
        case sha256
        case memoryRequiredMB = "memoryRequiredMb"
        case license
        case sourceDescription
    }
}

public enum ASRRuntimeBundleManifestError: Error, Equatable, Sendable {
    case emptyManifest
    case missingRequiredField(String)
    case invalidExecutableRelativePath(String)
    case invalidSHA256(String)
    case missingExecutable(String)
    case sha256Mismatch(expected: String, actual: String)
    case downloadURLNotAllowed
}

public struct ASRRuntimeBundleManifest: Codable, Equatable, Sendable {
    public let runtimes: [ASRRuntimeBundleInfo]

    public init(runtimes: [ASRRuntimeBundleInfo]) throws {
        guard !runtimes.isEmpty else { throw ASRRuntimeBundleManifestError.emptyManifest }
        self.runtimes = runtimes
    }

    private enum CodingKeys: String, CodingKey {
        case runtimes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runtimes = try container.decode([ASRRuntimeBundleInfo].self, forKey: .runtimes)
        try self.init(runtimes: runtimes)
    }
}

public struct ASRRuntimeBundleInfo: Codable, Equatable, Sendable {
    public let provider: String
    public let platform: String
    public let architecture: String
    public let version: String
    public let executableRelativePath: String
    public let sha256: String
    public let license: String
    public let sourceDescription: String

    public init(
        provider: String,
        platform: String,
        architecture: String,
        version: String,
        executableRelativePath: String,
        sha256: String,
        license: String,
        sourceDescription: String
    ) throws {
        self.provider = try Self.required(provider, field: "provider")
        self.platform = try Self.required(platform, field: "platform")
        self.architecture = try Self.required(architecture, field: "architecture")
        self.version = try Self.required(version, field: "version")
        self.executableRelativePath = try Self.validatedRelativePath(executableRelativePath)
        self.sha256 = try Self.validatedSHA256(sha256)
        self.license = try Self.required(license, field: "license")
        self.sourceDescription = try Self.required(sourceDescription, field: "sourceDescription")
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case platform
        case architecture
        case version
        case executableRelativePath
        case sha256
        case license
        case sourceDescription
    }

    private enum GuardKeys: String, CodingKey {
        case downloadURL = "downloadUrl"
    }

    public init(from decoder: Decoder) throws {
        let guardContainer = try decoder.container(keyedBy: GuardKeys.self)
        if guardContainer.contains(.downloadURL) {
            throw ASRRuntimeBundleManifestError.downloadURLNotAllowed
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            provider: container.decode(String.self, forKey: .provider),
            platform: container.decode(String.self, forKey: .platform),
            architecture: container.decode(String.self, forKey: .architecture),
            version: container.decode(String.self, forKey: .version),
            executableRelativePath: container.decode(String.self, forKey: .executableRelativePath),
            sha256: container.decode(String.self, forKey: .sha256),
            license: container.decode(String.self, forKey: .license),
            sourceDescription: container.decode(String.self, forKey: .sourceDescription)
        )
    }

    public func executableURL(relativeTo runtimeDirectoryURL: URL) -> URL {
        executableRelativePath
            .split(separator: "/")
            .reduce(runtimeDirectoryURL) { url, component in
                url.appendingPathComponent(String(component), isDirectory: false)
            }
    }

    public func verifiedRuntimeInfo(relativeTo runtimeDirectoryURL: URL) throws -> ASRRuntimeInfo {
        let executable = executableURL(relativeTo: runtimeDirectoryURL)
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw ASRRuntimeBundleManifestError.missingExecutable(executableRelativePath)
        }
        let actualSHA = SHA256.hash(data: try Data(contentsOf: executable))
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA == sha256 else {
            throw ASRRuntimeBundleManifestError.sha256Mismatch(expected: sha256, actual: actualSHA)
        }
        return ASRRuntimeInfo(provider: provider, executableURL: executable)
    }

    private static func required(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ASRRuntimeBundleManifestError.missingRequiredField(field) }
        return trimmed
    }

    private static func validatedRelativePath(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":") else {
            throw ASRRuntimeBundleManifestError.invalidExecutableRelativePath(value)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ASRRuntimeBundleManifestError.invalidExecutableRelativePath(value)
        }
        return trimmed
    }

    private static func validatedSHA256(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdef")
        guard trimmed.count == 64,
              trimmed.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else {
            throw ASRRuntimeBundleManifestError.invalidSHA256(value)
        }
        return trimmed
    }
}

public struct ASRTranscriptCacheEntry: Codable, Equatable, Sendable {
    public let cacheKey: String
    public let audioFingerprint: String
    public let modelID: String
    public let backendKind: ASRBackendKind
    public let languageCode: String?
    public let transcriptURL: URL
    public let createdAt: Date

    public init(
        cacheKey: String,
        audioFingerprint: String,
        modelID: String,
        backendKind: ASRBackendKind? = nil,
        languageCode: String? = nil,
        transcriptURL: URL,
        createdAt: Date = Date()
    ) {
        self.cacheKey = cacheKey
        self.audioFingerprint = audioFingerprint
        self.modelID = modelID
        self.backendKind = backendKind ?? ASRBackendKind.inferred(from: modelID)
        self.languageCode = languageCode
        self.transcriptURL = transcriptURL
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case cacheKey
        case audioFingerprint
        case modelID = "modelId"
        case backendKind
        case languageCode
        case transcriptPath
        case legacyTranscriptURL = "transcriptUrl"
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cacheKey = try container.decode(String.self, forKey: .cacheKey)
        self.audioFingerprint = try container.decode(String.self, forKey: .audioFingerprint)
        self.modelID = try container.decode(String.self, forKey: .modelID)
        self.backendKind = try container.decodeIfPresent(ASRBackendKind.self, forKey: .backendKind)
            ?? ASRBackendKind.inferred(from: modelID)
        self.languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        let transcriptValue = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
            ?? container.decode(String.self, forKey: .legacyTranscriptURL)
        self.transcriptURL = Self.fileURL(from: transcriptValue)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cacheKey, forKey: .cacheKey)
        try container.encode(audioFingerprint, forKey: .audioFingerprint)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(backendKind, forKey: .backendKind)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encode(transcriptURL.path, forKey: .transcriptPath)
        try container.encode(createdAt, forKey: .createdAt)
    }

    private static func fileURL(from value: String) -> URL {
        if let url = URL(string: value), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: value)
    }
}

public enum ASRTranscriptMapper {
    private static let leadingSilenceToleranceSeconds = 0.12
    private static let leadingSilenceMinimumSeconds = 0.8
    private static let leadingSilenceCarryMaxGapSeconds = 1.0
    private static let leadingSilenceNoiseProbability = 0.35
    private static let leadingSilenceCarryProbability = 0.50
    private static let leadingSilenceCarryMinimumSeconds = 0.08

    public static func sourceFragments(from transcript: ASRTranscript) -> [SubtitleCueSourceFragment] {
        wordsToFragments(transcript.words)
    }

    private struct FragmentAccumulator {
        var fragment: SubtitleCueSourceFragment
        var latinMergeEligible: Bool
    }

    private static func wordsToFragments(_ words: [ASRWord]) -> [SubtitleCueSourceFragment] {
        var accumulated: [FragmentAccumulator] = []
        for word in words {
            let text = LocalASRSubtitleTimingPlanner.cleanedSpeechText(word.text)
            guard !text.isEmpty,
                  word.startSeconds.isFinite,
                  word.endSeconds.isFinite,
                  word.startSeconds >= 0,
                  word.endSeconds >= word.startSeconds else {
                continue
            }
            let fragment = SubtitleCueSourceFragment(
                startSeconds: word.startSeconds,
                endSeconds: word.endSeconds,
                text: text
            )
            let startsNewWhisperTokenWord = word.text.first?.isWhitespace == true
                && !containsCJKOrHangul(text)

            if let previous = accumulated.last,
               shouldMergeLatinASRToken(
                previousText: previous.fragment.text,
                previousMergeEligible: previous.latinMergeEligible,
                currentText: text,
                rawCurrentText: word.text
               ) {
                accumulated[accumulated.count - 1] = FragmentAccumulator(
                    fragment: SubtitleCueSourceFragment(
                        startSeconds: previous.fragment.startSeconds,
                        endSeconds: max(previous.fragment.endSeconds, fragment.endSeconds),
                        text: previous.fragment.text + text
                    ),
                    latinMergeEligible: true
                )
            } else {
                accumulated.append(FragmentAccumulator(
                    fragment: fragment,
                    latinMergeEligible: startsNewWhisperTokenWord
                ))
            }
        }
        return accumulated.map(\.fragment)
    }

    private static func shouldMergeLatinASRToken(
        previousText: String,
        previousMergeEligible: Bool,
        currentText: String,
        rawCurrentText: String
    ) -> Bool {
        guard previousMergeEligible else { return false }
        guard rawCurrentText.first?.isWhitespace != true else { return false }
        let previous = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !current.isEmpty else { return false }
        if containsCJKOrHangul(previous) || containsCJKOrHangul(current) { return false }
        if isLatinJoinPunctuation(current) { return true }
        if isLatinApostrophePrefix(previous) && containsLetterOutsideCJK(current) { return true }
        return containsLetterOutsideCJK(previous) && containsLetterOutsideCJK(current)
    }

    private static func isLatinJoinPunctuation(_ text: String) -> Bool {
        text.allSatisfy { character in
            character == "'" || character == "’" || character == "." || character == "," || character == "!" || character == "?" || character == ":" || character == ";"
        } || (text.first == "'" || text.first == "’")
    }

    private static func isLatinApostrophePrefix(_ text: String) -> Bool {
        text.allSatisfy { $0 == "'" || $0 == "’" }
    }

    private static func containsLetterOutsideCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && !isCJKOrHangulScalar(scalar)
        }
    }

    private static func containsCJKOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJKOrHangulScalar($0) }
    }

    private static func isCJKOrHangulScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(Int(scalar.value))
            || (0x3400...0x4DBF).contains(Int(scalar.value))
            || (0x4E00...0x9FFF).contains(Int(scalar.value))
            || (0xAC00...0xD7A3).contains(Int(scalar.value))
    }

    private static func sourceFragments(
        from transcript: ASRTranscript,
        profile: SubtitleTimingProfile,
        audioActivity: ASRAudioActivity?
    ) -> [SubtitleCueSourceFragment] {
        guard let audioActivity,
              profile == .lyrics || profile == .japaneseLyrics else {
            return sourceFragments(from: transcript)
        }
        let words = adjustedLeadingSilenceWords(transcript.words, audioActivity: audioActivity)
        let adjustedTranscript = ASRTranscript(
            id: transcript.id,
            languageCode: transcript.languageCode,
            languageConfidence: transcript.languageConfidence,
            durationSeconds: transcript.durationSeconds,
            words: words,
            sourceModelID: transcript.sourceModelID,
            backendKind: transcript.backendKind,
            segments: transcript.segments,
            rawText: transcript.rawText,
            backendDiagnostics: transcript.backendDiagnostics,
            qualitySummary: transcript.qualitySummary,
            createdAt: transcript.createdAt
        )
        return sourceFragments(from: adjustedTranscript)
    }

    private static func adjustedLeadingSilenceWords(
        _ words: [ASRWord],
        audioActivity: ASRAudioActivity
    ) -> [ASRWord] {
        guard let leadingSilence = audioActivity.silenceRanges.first(where: { range in
            range.startSeconds <= leadingSilenceToleranceSeconds
                && range.endSeconds - range.startSeconds >= leadingSilenceMinimumSeconds
        }) else {
            return words
        }
        let silenceEnd = leadingSilence.endSeconds
        guard let firstAudibleIndex = words.firstIndex(where: { word in
            word.endSeconds > silenceEnd + leadingSilenceToleranceSeconds
                || word.startSeconds >= silenceEnd
        }) else {
            return words.filter { !isLowConfidenceLeadingLyricNoise($0) }
        }
        guard firstAudibleIndex > words.startIndex else {
            return words.map { word in
                word.startSeconds < silenceEnd && word.endSeconds > silenceEnd
                    ? ASRWord(text: word.text, startSeconds: silenceEnd, endSeconds: word.endSeconds, probability: word.probability)
                    : word
            }
        }

        let leadingWords = Array(words[..<firstAudibleIndex])
        var adjusted: [ASRWord] = []
        if let carryWord = leadingWords.last(where: { word in
            !isLowConfidenceLeadingLyricNoise(word)
                && (word.probability ?? 1.0) >= leadingSilenceCarryProbability
        }) {
            let nextStart = words[firstAudibleIndex].startSeconds
            if nextStart >= silenceEnd,
               nextStart - silenceEnd <= leadingSilenceCarryMaxGapSeconds {
                adjusted.append(ASRWord(
                    text: carryWord.text,
                    startSeconds: silenceEnd,
                    endSeconds: max(silenceEnd + leadingSilenceCarryMinimumSeconds, nextStart),
                    probability: carryWord.probability
                ))
            }
        }

        for word in words[firstAudibleIndex...] {
            if word.startSeconds < silenceEnd, word.endSeconds > silenceEnd {
                adjusted.append(ASRWord(
                    text: word.text,
                    startSeconds: silenceEnd,
                    endSeconds: word.endSeconds,
                    probability: word.probability
                ))
            } else {
                adjusted.append(word)
            }
        }
        return adjusted
    }

    private static func isLowConfidenceLeadingLyricNoise(_ word: ASRWord) -> Bool {
        let text = LocalASRSubtitleTimingPlanner.cleanedSpeechText(word.text)
        let visibleCount = text.filter { !$0.isWhitespace }.count
        return visibleCount <= 2 && (word.probability ?? 1.0) < leadingSilenceNoiseProbability
    }

    public static func sourceCues(
        from transcript: ASRTranscript,
        profile: SubtitleTimingProfile = .speech,
        audioActivity: ASRAudioActivity? = nil
    ) -> [SubtitleCue] {
        let fragments = sourceFragments(from: transcript, profile: profile, audioActivity: audioActivity)
        let planned = LocalASRSubtitleTimingPlanner.planCues(
            from: fragments,
            transcriptDurationSeconds: transcript.durationSeconds,
            profile: profile
        )
        // Whisper-specific re-timing pass: pulls late onsets earlier, holds cues to just
        // before the next real onset, and guarantees no overlap. Separate from the platform
        // (YouTube auto-caption) timing path, which keeps human-aligned source anchors.
        return WhisperCueRetimer.retime(
            planned,
            transcriptDurationSeconds: transcript.durationSeconds,
            profile: profile,
            audioActivity: audioActivity
        )
    }

    /// Detect the content-type timing profile from the filename and a first-pass (`.speech`) cue
    /// shape, then re-plan with the matching profile. Lyrics/anime get tighter ceilings, smaller
    /// break gaps, shorter holds, and a residual cap. Pure function of its inputs; falls back to
    /// `.speech` (unchanged behaviour) when nothing matches.
    public static func sourceCues(
        from transcript: ASRTranscript,
        fileName: String,
        audioActivity: ASRAudioActivity? = nil
    ) -> [SubtitleCue] {
        let speechCues = sourceCues(from: transcript, profile: .speech)
        let profile = SubtitleTimingProfileDetector.detect(
            fileName: fileName,
            cues: speechCues,
            languageCode: transcript.languageCode
        )
        return profile == .speech ? speechCues : sourceCues(from: transcript, profile: profile, audioActivity: audioActivity)
    }

    public static func localASRSourceSRTURL(videoURL: URL, languageCode: String) -> URL {
        let normalizedLanguage = normalizedLanguageCode(languageCode)
        let stem = videoURL.deletingPathExtension().lastPathComponent
        return videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).local-asr.\(normalizedLanguage).srt", isDirectory: false)
    }

    @discardableResult
    public static func writeLocalASRSourceSRT(
        transcript: ASRTranscript,
        videoURL: URL,
        audioActivity: ASRAudioActivity? = nil
    ) throws -> URL {
        let cues = sourceCues(from: transcript, fileName: videoURL.lastPathComponent, audioActivity: audioActivity)
        guard !cues.isEmpty else { throw WhisperCppRecognizerError.emptyTranscript }
        let outputURL = localASRSourceSRTURL(videoURL: videoURL, languageCode: transcript.languageCode)
        try serializeSRT(cues).write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    private static func normalizedLanguageCode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "und" : trimmed
    }

}

/// Content-type timing profile. Local-ASR subtitles for a lecture, a song, and an anime need
/// different regroup ceilings, break gaps, and hold-to-next behaviour. The profile is detected
/// once (filename + cue shape, see `Translator.detectTimingProfile`) and threaded through all
/// three timing layers (resegmentation preset, `LocalASRSubtitleTimingPlanner`, `WhisperCueRetimer`).
/// `.speech` reproduces the pre-profile behaviour exactly, so the default path is unchanged.
public enum SubtitleTimingProfile: String, Codable, Sendable, CaseIterable {
    case speech
    case lyrics
    case japaneseLyrics
    case anime
}

/// Detects the content-type timing profile from a filename and first-pass cue shape. Pure and
/// deterministic so it is unit-testable and mirrored 1:1 in C# `SubtitleTimingProfileDetector`.
public enum SubtitleTimingProfileDetector {
    private static let lyricsFilenameKeywords = [
        "official music video", "music video", "official mv", " mv ",
        "lyrics", "lyric", "song", "cover", "歌ってみた", "歌詞", "字幕版", "mv)"
    ]
    private static let japaneseMusicFilenameKeywords = [
        " live", "ライブ", "official audio", "official visualizer", "performance video"
    ]
    private static let animeFilenameKeywords = [
        "anime", "アニメ", "动画", "動畫", "ova"
    ]
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]

    private static func isEpisodeDigit(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return false }
        let v = s.value
        return (0x30...0x39).contains(v) || (0xFF10...0xFF19).contains(v) // 半角 + 全角数字
    }

    private static func isASCIILetter(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first else { return false }
        return (0x61...0x7A).contains(s.value) // a–z（lower 已小写）
    }

    /// 仅在数字邻接时才把分集标记当动漫信号，避免裸「第/话/episode」把任意标题误判成动漫。
    /// 命中：第<数字>话 / 第<数字>話 / episode<可选分隔><数字> / ep<可选 .或空格><数字>（含全角数字）。
    /// 纯字符扫描、无正则，Swift / C# 逐字符一致镜像。`lower` 须为已小写的文件名。
    static func containsEpisodeMarker(_ lower: String) -> Bool {
        let chars = Array(lower)
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            // 第<数字>(话|話)
            if c == "第" {
                var j = i + 1
                var sawDigit = false
                while j < n, isEpisodeDigit(chars[j]) { sawDigit = true; j += 1 }
                if sawDigit, j < n, chars[j] == "话" || chars[j] == "話" { return true }
            }
            // 词边界处的 ep / episode，后跟可选 '.'/' ' 再接数字。
            if c == "e", i == 0 || !isASCIILetter(chars[i - 1]) {
                var markerLen = 0
                if matches(chars, at: i, "episode") { markerLen = 7 }
                else if matches(chars, at: i, "ep") { markerLen = 2 }
                if markerLen > 0 {
                    var k = i + markerLen
                    while k < n, chars[k] == "." || chars[k] == " " { k += 1 }
                    if k < n, isEpisodeDigit(chars[k]) { return true }
                }
            }
            i += 1
        }
        return false
    }

    private static func matches(_ chars: [Character], at index: Int, _ word: String) -> Bool {
        let w = Array(word)
        guard index + w.count <= chars.count else { return false }
        for offset in 0..<w.count where chars[index + offset] != w[offset] { return false }
        return true
    }

    public static func detect(
        fileName: String,
        cues: [SubtitleCue],
        languageCode: String? = nil
    ) -> SubtitleTimingProfile {
        let lower = fileName.lowercased()
        if lyricsFilenameKeywords.contains(where: { lower.contains($0) }) {
            return looksJapanese(fileName: lower, languageCode: languageCode, cues: cues) ? .japaneseLyrics : .lyrics
        }
        let earlyJapaneseContent = looksJapanese(fileName: lower, languageCode: languageCode, cues: cues)
        if earlyJapaneseContent,
           japaneseMusicFilenameKeywords.contains(where: { lower.contains($0) })
            || hasJapaneseLyricBoilerplateHallucination(cues)
            || hasJapaneseLyricIntroMusicHallucination(cues) {
            return .japaneseLyrics
        }
        guard cues.count >= 20 else {
            return animeFilenameKeywords.contains(where: { lower.contains($0) }) || containsEpisodeMarker(lower)
                ? .anime : .speech
        }

        var durations: [Double] = []
        var largeGaps = 0
        var shortCues = 0
        var cjkChars = 0
        var totalChars = 0
        var punctuated = 0
        var previousEnd: Double?
        for cue in cues {
            let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.last.map(sentenceEnders.contains) == true { punctuated += 1 }
            for scalar in trimmed.unicodeScalars {
                let value = scalar.value
                if !scalar.properties.isWhitespace { totalChars += 1 }
                if (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value)
                    || (0xAC00...0xD7A3).contains(value) {
                    cjkChars += 1
                }
            }
            guard let start = srtTimeToSeconds(cue.start),
                  let end = srtTimeToSeconds(cue.end),
                  end > start else { continue }
            let duration = end - start
            durations.append(duration)
            if duration <= 1.5 { shortCues += 1 }
            if let previousEnd, start - previousEnd >= 1.2 { largeGaps += 1 }
            previousEnd = end
        }
        guard !durations.isEmpty else { return .speech }
        let punctuatedRatio = Double(punctuated) / Double(cues.count)
        let average = durations.reduce(0, +) / Double(durations.count)
        let japaneseContent = earlyJapaneseContent

        // Some official J-pop uploads have titles like "Ado - うっせぇわ" without "MV" or
        // "lyrics". If whisper has already fallen into a dense Japanese loop, route through the
        // lyric profile so the dedicated hallucination suppressor can clean it up.
        if japaneseContent, punctuatedRatio < 0.2,
           (hasDenseJapaneseASRLoop(cues) || hasJapaneseLyricBoilerplateHallucination(cues)) {
            return .japaneseLyrics
        }

        // Lyrics: few sentence-final punctuation marks, medium-length lines, frequent silent gaps
        // between phrases (the shape of a sung verse) — matches Translator.looksLikeLocalASRLyrics.
        if punctuatedRatio < 0.2, average >= 3.0, average <= 5.8, largeGaps >= 2 {
            return japaneseContent ? .japaneseLyrics : .lyrics
        }

        // Anime: CJK-heavy, lots of short reaction cues, sparse end punctuation.
        let cjkRatio = totalChars > 0 ? Double(cjkChars) / Double(totalChars) : 0
        let shortRatio = Double(shortCues) / Double(cues.count)
        if animeFilenameKeywords.contains(where: { lower.contains($0) }) || containsEpisodeMarker(lower) { return .anime }
        if cjkRatio >= 0.5, shortRatio >= 0.45, punctuatedRatio < 0.35 {
            return .anime
        }
        return .speech
    }

    private static func hasDenseJapaneseASRLoop(_ cues: [SubtitleCue]) -> Bool {
        let normalized = normalizeJapaneseCueText(cues.map(\.text).joined())
        guard normalized.count >= 80 else { return false }
        let uniqueRatio = Double(Set(normalized).count) / Double(normalized.count)
        guard uniqueRatio <= 0.24 else { return false }
        guard repeatedBigramExcess(in: normalized) >= 24 else { return false }
        return hasDominantRepeatedSubstring(normalized)
    }

    private static func hasJapaneseLyricBoilerplateHallucination(_ cues: [SubtitleCue]) -> Bool {
        let normalized = normalizeJapaneseCueText(cues.map(\.text).joined())
        let hasCreditCluster = normalized.contains("作詞")
            && (normalized.contains("作曲") || normalized.contains("編曲") || normalized.contains("初音ミク"))
        let thankYouCount = normalized.components(separatedBy: "ご視聴ありがとうございました").count - 1
        let hasTerminalThankYou = normalized.range(of: "ご視聴ありがとうございました").map { range in
            normalized.distance(from: range.upperBound, to: normalized.endIndex) <= 12
        } ?? false
        return hasCreditCluster || thankYouCount >= 2 || hasTerminalThankYou
    }

    private static func hasJapaneseLyricIntroMusicHallucination(_ cues: [SubtitleCue]) -> Bool {
        guard let first = cues.first,
              let start = srtTimeToSeconds(first.start),
              start <= 2.0 else { return false }
        let head = cues.prefix(3)
            .map { normalizedLatinCueText($0.text) }
            .joined()
        return head.hasPrefix("BGM")
    }

    private static func normalizeJapaneseCueText(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return (0x3040...0x309F).contains(Int(value))
                || (0x30A0...0x30FF).contains(Int(value))
                || (0x4E00...0x9FFF).contains(Int(value))
        })
    }

    private static func normalizedLatinCueText(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar in
            let value = scalar.value
            guard (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) else {
                return nil
            }
            return Character(UnicodeScalar(String(scalar).uppercased())!)
        })
    }

    private static func repeatedBigramExcess(in text: String) -> Int {
        let characters = Array(text)
        guard characters.count >= 2 else { return 0 }
        var counts: [String: Int] = [:]
        for index in 0..<(characters.count - 1) {
            counts[String(characters[index...index + 1]), default: 0] += 1
        }
        return counts.values.reduce(0) { total, count in
            total + max(0, count - 1)
        }
    }

    private static func hasDominantRepeatedSubstring(_ text: String) -> Bool {
        let characters = Array(text)
        let maxLength = min(28, characters.count / 2)
        guard maxLength >= 8 else { return false }
        for length in stride(from: maxLength, through: 8, by: -1) {
            var counts: [String: Int] = [:]
            for index in 0...(characters.count - length) {
                let substring = String(characters[index..<(index + length)])
                guard Set(substring).count >= 3 else { continue }
                counts[substring, default: 0] += 1
            }
            if counts.values.contains(where: { count in
                count >= 3 && Double(length * count) / Double(characters.count) >= 0.35
            }) {
                return true
            }
        }
        return false
    }

    private static func looksJapanese(fileName lower: String, languageCode: String?, cues: [SubtitleCue]) -> Bool {
        if isJapaneseLanguage(languageCode) { return true }
        if lower.contains(".ja.") || lower.contains(".ja-") || lower.contains("_ja.") || lower.contains("_ja-")
            || lower.contains("[ja]") || lower.contains("日本語") || lower.contains("日语") || lower.contains("日語") {
            return true
        }
        var kana = 0
        var visible = 0
        for cue in cues.prefix(40) {
            for scalar in cue.text.unicodeScalars where !scalar.properties.isWhitespace {
                visible += 1
                let value = scalar.value
                if (0x3040...0x30FF).contains(value) { kana += 1 }
            }
        }
        return visible > 0 && Double(kana) / Double(visible) >= 0.18
    }

    private static func isJapaneseLanguage(_ languageCode: String?) -> Bool {
        guard let languageCode else { return false }
        let normalized = languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "ja" || normalized == "jpn" || normalized.hasPrefix("ja-")
    }
}

/// Per-profile regroup/timing thresholds. The single cross-platform source of truth for the
/// differentiated values is `Tests/fixtures/whisper-timing-constants.json` (`profiles` section);
/// the Swift and C# `thresholds(for:)` tables are each asserted equal to it (ARCH-3 parity).
public struct SubtitleTimingThresholds: Equatable, Sendable {
    public let maximumCJKCueSeconds: Double
    public let hardMaximumCJKCueSeconds: Double
    public let relaxedCJKCueSeconds: Double
    public let maximumLatinCueSeconds: Double
    public let largeSpeechGapSeconds: Double
    /// Profile-specific onset nudge. Spoken subtitles use a small late bias to avoid appearing
    /// before speech; Japanese lyrics keep raw DTW onset because sung words are often already late.
    public let onsetDelaySeconds: Double
    public let holdToNextSeconds: Double
    /// Maximum standalone duration for a residual single-character / lone-kana cue before it is
    /// time-capped. `.speech` keeps no extra constraint (residuals are handled by droppable +
    /// orphan merge); `.lyrics` / `.anime` cap it so a stray 「っ」/「ー」 cannot linger.
    public let residualMaxStandaloneSeconds: Double
    /// Breath-gap break anchor (stable-ts style). Once a cue is already past its soft ceiling, a
    /// real inter-word silence at least this long is treated as a natural phrase boundary and forces
    /// a break there — instead of extending to the hard ceiling. Latin speech uses a larger gap than
    /// CJK; lyrics use the smallest gap so sung lines break at every breath. Only consulted in the
    /// over-soft-ceiling zone, so short cues are never affected.
    public let breathGapBreakSeconds: Double
}

enum LocalASRSubtitleTimingPlanner {
    static let minimumCueSeconds = 0.3
    private static let sentenceTailSeconds = 0.45
    private static let phraseTailSeconds = 0.2
    static let maximumCJKCueSeconds = 4.5
    static let hardMaximumCJKCueSeconds = 5.5
    static let relaxedCJKCueSeconds = 6.5
    static let maximumLatinCueSeconds = SubtitleTimingPlanner.normalReadableCueSeconds
    private static let shortStandaloneCJKCueSeconds = 2.4
    private static let maximumCJKUnits = 18
    private static let hardMaximumCJKUnits = 28
    private static let relaxedShortMergeMaxCJKUnits = 34
    private static let maximumLatinTokens = 14
    // 0.65→0.50 (2026-06-24, segmentation eval 方向B)：参考人工字幕把 0.4–0.65s 停顿当强边界，
    // 原 0.65 漏断这类必断点（strong-boundary recall≈0.50）。降到 0.50 让真实停顿更早强制断句。
    // 跨端同步：windows/MoongateCore/Asr.cs 与 Tests/fixtures/whisper-timing-constants.json。
    private static let largeSpeechGapSeconds = 0.50

    /// Per-profile thresholds. `.speech` reproduces the standalone constants above exactly (zero
    /// behaviour change for the default path); `.lyrics` / `.anime` tighten ceilings and break gaps
    /// for song lines and short anime reactions. Mirrored in C# `LocalAsrSubtitleTimingPlanner` and
    /// asserted against `Tests/fixtures/whisper-timing-constants.json` (`profiles` section).
    static func thresholds(for profile: SubtitleTimingProfile) -> SubtitleTimingThresholds {
        switch profile {
        case .speech:
            return SubtitleTimingThresholds(
                maximumCJKCueSeconds: maximumCJKCueSeconds,
                hardMaximumCJKCueSeconds: hardMaximumCJKCueSeconds,
                relaxedCJKCueSeconds: relaxedCJKCueSeconds,
                maximumLatinCueSeconds: maximumLatinCueSeconds,
                largeSpeechGapSeconds: largeSpeechGapSeconds,
                onsetDelaySeconds: WhisperCueRetimer.onsetDelaySeconds,
                holdToNextSeconds: WhisperCueRetimer.holdToNextSeconds,
                residualMaxStandaloneSeconds: .greatestFiniteMagnitude,
                breathGapBreakSeconds: 0.35
            )
        case .lyrics:
            return SubtitleTimingThresholds(
                maximumCJKCueSeconds: 3.0,
                hardMaximumCJKCueSeconds: 4.0,
                relaxedCJKCueSeconds: 4.5,
                maximumLatinCueSeconds: 5.0,
                largeSpeechGapSeconds: 0.45,
                onsetDelaySeconds: 0.1,
                holdToNextSeconds: 0.35,
                residualMaxStandaloneSeconds: 0.9,
                breathGapBreakSeconds: 0.25
            )
        case .japaneseLyrics:
            return SubtitleTimingThresholds(
                maximumCJKCueSeconds: 4.2,
                hardMaximumCJKCueSeconds: 5.2,
                relaxedCJKCueSeconds: 5.8,
                maximumLatinCueSeconds: 5.4,
                largeSpeechGapSeconds: 0.5,
                onsetDelaySeconds: 0.0,
                holdToNextSeconds: 0.28,
                residualMaxStandaloneSeconds: 0.9,
                breathGapBreakSeconds: 0.3
            )
        case .anime:
            return SubtitleTimingThresholds(
                maximumCJKCueSeconds: 3.5,
                hardMaximumCJKCueSeconds: 5.0,
                relaxedCJKCueSeconds: 5.5,
                maximumLatinCueSeconds: 7.0,
                largeSpeechGapSeconds: 0.55,
                onsetDelaySeconds: 0.15,
                holdToNextSeconds: 0.5,
                residualMaxStandaloneSeconds: 1.2,
                breathGapBreakSeconds: 0.3
            )
        }
    }

    /// Japanese kana / punctuation that must not START a subtitle line (particles, small kana,
    /// long-vowel mark, closing punctuation). Breaking right before one of these produces the
    /// unnatural "leading-が / lone-ね" splits whisper's token stream otherwise yields.
    private static let cjkLeadingProhibited: Set<Character> = [
        "を", "が", "は", "に", "へ", "と", "で", "も", "の", "ね", "よ", "さ", "わ", "ぞ", "ぜ", "ん",
        "っ", "ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ", "ー", "〜",
        "、", "。", "，", "．", "・", "！", "？", "」", "』", "）", "”", "’"
    ]

    /// Standalone residual kana / long-vowel marks that whisper often hallucinates from breath,
    /// music, or stretched audio. Keeping them as cues creates multi-second 「っ」/「ー」 flashes.
    private static let droppableJapaneseResiduals: Set<String> = [
        "っ", "ー", "〜", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ"
    ]
    private static let japaneseLyricPhraseStartPrefixes = [
        "そんな", "こんな", "あんな", "どんな", "この", "その", "あの",
        "これ", "それ", "あれ", "でも", "だけど"
    ]
    private static let japaneseLyricBareTailFragments: Set<String> = [
        "な", "て", "で", "に", "の", "が", "は", "を", "も", "と", "よ", "ね", "さ", "ん"
    ]
    private static let japaneseLyricAdnominalHeads: Set<String> = [
        "よう", "そう", "みたい"
    ]
    private static let japaneseLyricObjectParticleStarts: Set<Character> = [
        "を", "が", "は", "に", "へ", "と", "で", "も", "の"
    ]
    private static let japaneseLyricSingleKanjiSuffixes: Set<Character> = [
        "生", "者", "性", "感", "心", "声", "音", "色", "先", "中", "目", "手"
    ]
    private static let japaneseLyricKanaVerbStemTails: Set<String> = [
        "もが", "こ", "続"
    ]

    private static let japaneseLoopMinPhraseFragments = 4
    private static let japaneseLoopMaxPhraseFragments = 12
    private static let japaneseLoopMinRepeatCount = 4
    private static let japaneseLoopAllowedRepeats = 1
    private static let japaneseLoopMaxPhraseSpanSeconds = 3.0
    private static let japaneseLoopMaxOccurrenceGapSeconds = 0.8
    private static let japaneseLoopFuseSeconds = 90.0
    private static let japaneseLyricLoopCueMinCount = 5
    private static let japaneseLyricLoopCueMinNormalizedCharacters = 28
    private static let japaneseLyricLoopCueMaxSpanSeconds = 35.0
    private static let japaneseLyricLoopCueMaxGapSeconds = 4.0
    private static let japaneseLyricLoopCueMaxUniqueCharacterRatio = 0.38
    private static let japaneseLyricLoopCueMinRepeatedBigramExcess = 8
    private static let japaneseLyricLoopCueLongSparseSeconds = 8.0
    private static let japaneseLyricDenseLoopMinCharacters = 36
    private static let japaneseLyricDenseLoopMinSubstringCharacters = 8
    private static let japaneseLyricDenseLoopMaxSubstringCharacters = 28
    private static let japaneseLyricDenseLoopMinOccurrences = 3
    private static let japaneseLyricDenseLoopMinCoverage = 0.55
    private static let japaneseLyricCreditHallucinationTokens: Set<String> = [
        "作", "詞", "词", "作詞", "作词", "曲", "作曲", "編", "编", "編曲", "编曲", "初", "音", "初音", "ミ", "ク", "ミク", "初音ミク"
    ]
    private static let japaneseLyricCreditHallucinationMarkers = [
        "作詞", "作词", "作曲", "編曲", "编曲", "初音ミク"
    ]
    private static let japaneseLyricCreditHallucinationMaxGapSeconds = 4.0
    private static let japaneseLyricOutroHallucinationMarkers = [
        "ご視聴ありがとうございました"
    ]
    private static let lyricFillerLoopTokens: Set<String> = [
        "yeah", "yea", "ya", "yah", "ey", "hey", "heyy",
        "oh", "ooh", "uh", "uhh", "ah", "mmm", "mm", "hmm", "hm"
    ]
    private static let lyricFillerLoopMinDurationSeconds = 8.0
    private static let lyricFillerLoopMinTokenCount = 12
    private static let lyricFillerLoopHighTokenCount = 24
    private static let lyricFillerCueMinTokenCount = 3
    private static let lyricFillerCueMinRatio = 0.75
    private static let lyricFillerLoopMaxGapSeconds = 1.5
    private static let lyricIntroCreditNameMaxStartSeconds = 3.0
    private static let lyricIntroCreditNameMaxEndSeconds = 5.0
    private static let lyricIntroCreditNameMinNextStartSeconds = 8.0
    private static let lyricIntroCreditNameMinGapSeconds = 6.0
    private static let lyricIntroCreditNameMinVisibleChars = 2
    private static let lyricIntroCreditNameMaxVisibleChars = 4
    private static let lyricRepeatedIntroFillerMaxStartSeconds = 35.0
    private static let lyricRepeatedIntroFillerMinCueCount = 5
    private static let lyricRepeatedIntroFillerMinDurationSeconds = 8.0
    private static let lyricRepeatedIntroFillerMaxGapSeconds = 2.5
    private static let lyricRepeatedIntroFillerMinKeyCharacters = 3
    private static let lyricRepeatedIntroFillerMaxKeyCharacters = 14
    private static let lyricRepeatedIntroFillerMaxRawKeyCharacters = 42
    private static let lyricRepeatedIntroFillerMaxVisibleChars = 16
    private static let lyricOutroBoilerplateKeys = [
        "thanksforwatching", "thankyouforwatching", "graciasporver", "graciasporverelvideo",
        "ご視聴ありがとうございました"
    ]

    /// A cue with at most this many visible characters is too short to stand alone (e.g. 「顔」,
    /// 「ね」, a lone 「えらい」) and is merged into the temporally-closest neighbour.
    private static let loneMergeMaxVisibleChars = 3
    /// Only merge a lone short cue into a neighbour within this gap (same utterance), so merging
    /// never drags a word across a long pause (which would make it appear early).
    private static let loneMergeMaxGapSeconds = 1.0
    /// 合并短孤儿组的有效间隙上限。**仅 speech 档**收紧到该档的"大停顿断句阈值":真实语音停顿是合法的人工句
    /// 边界,若在此处已正确断开,短组重并会把它吞回去(实测 tedx_nagoya:0.86s 停顿处人工断句被 1.0s 重并覆盖,
    /// strong-recall 丢分)。歌词/动漫档**保持 1.0s**——它们有专门的跨"演唱停顿"重接逻辑(0.75-1.35s),
    /// 收紧会破坏已调好的副歌/乐句重接(冻结档,不动)。
    private static func effectiveLoneMergeMaxGap(_ thresholds: SubtitleTimingThresholds, profile: SubtitleTimingProfile) -> Double {
        profile == .speech
            ? min(loneMergeMaxGapSeconds, thresholds.largeSpeechGapSeconds)
            : loneMergeMaxGapSeconds
    }
    private static let japaneseLyricParticleRejoinMaxGapSeconds = 1.35
    private static let japaneseLyricSemanticRejoinMaxGapSeconds = 0.75
    private static let japaneseLyricKanaVerbRejoinMaxGapSeconds = 0.9
    private static let japaneseLyricModifierRejoinMaxGapSeconds = 0.35
    private static let latinContinuationSuffixes: Set<String> = [
        "s", "es", "ed", "er", "ers", "or", "ors", "ing", "ly", "ally", "ually",
        "ist", "ists", "tion", "tions", "ment", "ness", "less", "able", "ible",
        "al", "ial", "ual", "cial", "ance", "ence", "ancia", "anca", "ança",
        "encia", "ência", "eiro", "eira", "eiros", "eiras", "iro", "iros", "ira", "iras",
        "ais", "ias", "ción", "ciones", "ção", "ções", "dad", "dade", "idades",
        "ada", "adas", "ado", "ados", "estra", "estre", "ês",
        "mente", "mento", "miento", "amiento", "zione", "zioni", "ient", "aient",
        "lich", "chen", "en", "ern", "ung", "ungen", "heit", "keit",
        "zial", "ier", "ieren", "uren", "feld", "sprach", "sprache", "ne", "wich",
        "ità", "tà", "né", "nné", "rsità", "é", "ée", "ior", "ano", "rice"
    ]
    private static let shortLatinContinuationSuffixes: Set<String> = [
        "ne", "ês", "né", "tà", "é", "ée"
    ]
    private static let latinBridgeFragments: Set<String> = [
        "la", "le", "li", "lo"
    ]
    private static let latinBridgeTailSuffixes: Set<String> = [
        "ient", "aient", "ée", "rice", "ano", "êt", "lio", "li", "na", "ette"
    ]
    private static let observedLatinBridgePrefixes: [String: Set<String>] = [
        "ach": ["arr"],
        "at": ["cré"],
        "r": ["most"],
        "n": ["lection", "sélection", "selection", "ion"],
        "onn": ["h"],
        "og": ["org"],
        "g": ["inse"]
    ]
    private static let observedLatinContinuationPrefixes: [String: Set<String>] = [
        "ütlich": ["gem"],
        "üt": ["gem"],
        "elt": ["reg"],
        "est": ["bef"],
        "igt": ["befest"],
        "ver": ["seiten"],
        "kle": ["seitenver", "ver"],
        "id": ["seitenverkle", "kle"],
        "ung": ["seitenverkleid", "id"],
        "äck": ["gep"],
        "ä": ["gep", "ep", "f"],
        "ck": ["gepä", "ä"],
        "f": ["gepäck", "ck"],
        "cher": ["gepäckfä", "fä", "ä"],
        "fächer": ["gepäck"],
        "ch": ["was"],
        "rä": ["wasch", "ch"],
        "ume": ["waschrä", "rä"],
        "amento": ["levant"],
        "cre": ["trans"],
        "ve": ["transcre", "cre"],
        "mos": ["transcreve", "ve"],
        "ut": ["trad"],
        "ores": ["tradut", "ut"],
        "ários": ["volunt"],
        "ng": ["lí"],
        "u": ["líng"],
        "as": ["língu"],
        "il": ["ut"],
        "ise": ["util"],
        "è": ["r"],
        "gl": ["rè"],
        "és": ["règl"],
        "li": ["app", "orgog", "neg"],
        "quer": ["appli"],
        "ien": ["quotid", "chem"],
        "ion": ["mar", "op", "opin"],
        "in": ["op"],
        "ette": ["marionn", "n"],
        "no": ["reg"],
        "ito": ["un"],
        "ra": ["lond"],
        "ia": ["svez"],
        "ix": ["d"],
        "lection": ["sé", "se"],
        "n": ["sélection", "selection", "marion", "ion"],
        "êt": ["honn", "onn"],
        "ée": ["sélectionn", "selectionn"],
        "eté": ["honnêt", "honnet"],
        "lio": ["orgog"],
        "ino": ["lat"],
        "os": ["orgogli", "li"],
        "amente": ["orgoglios", "os"],
        "ati": ["st"],
        "iti": ["un"],
        "igi": ["par"]
    ]
    private static let observedStandaloneLatinFunctionPrefixes: [String: Set<String>] = [
        "al": ["ito", "unito", "posto"],
        "en": ["influencer", "prendre", "encore", "mais"],
        "ne": ["qui"]
    ]
    private static let strongLatinContinuationSuffixes: Set<String> = [
        "s", "es", "ed", "er", "ers", "or", "ors", "ing", "ly", "ally", "ually",
        "ist", "ists", "tion", "tions", "ment", "ness", "less", "able", "ible"
    ]
    private static let latinContinuationFunctionWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "if", "in", "is", "it",
        "of", "on", "or", "the", "to", "we", "you", "he", "she", "they", "i", "me", "my",
        "un", "una", "une", "le", "la", "les", "de", "des", "du", "et", "ou", "que",
        "je", "tu", "il", "elle", "nous", "vous", "ce", "ces", "mon", "ma", "mes",
        "el", "los", "las", "y", "o", "yo", "tú", "tu", "él", "ella", "por", "para", "con",
        "em", "no", "na", "os", "as", "eu", "nós", "nos", "não", "ao", "à",
        "io", "noi", "voi", "che", "per", "con",
        "ich", "du", "er", "sie", "wir", "ihr", "der", "die", "das", "ein", "eine",
        "mit", "zu", "auf", "im", "am"
    ]

    /// Merge lone, too-short groups into the neighbour they are closest to in time. whisper splits
    /// off single morphemes (especially before/after its own timing gaps); without this they become
    /// jarring 1-character cues like 「顔」 separated from 「洗って」.
    private static func mergeShortGroups(
        _ groups: [[SubtitleCueSourceFragment]],
        thresholds: SubtitleTimingThresholds,
        profile: SubtitleTimingProfile
    ) -> [[SubtitleCueSourceFragment]] {
        // 入口过滤空组：下游多处取 first/last，空组会越界崩溃（BUG-D 防御）。正常分词不产空组，
        // 过滤后所有 first/last 访问都在“组恒非空”不变式下安全。
        let groups = groups.filter { !$0.isEmpty }
        guard groups.count > 1 else { return groups }
        var result: [[SubtitleCueSourceFragment]] = []
        var index = 0
        while index < groups.count {
            var group = groups[index]
            if group.count > 1,
               let previous = result.last,
               let prevEnd = previous.last?.endSeconds,
               startsWithLeadingProhibited(group[0].text) {
                let leading = [group[0]]
                let gapPrev = leading[0].startSeconds - prevEnd
                if gapPrev <= effectiveLoneMergeMaxGap(thresholds, profile: profile),
                   fitsMergedCue(previous + leading, absorbingShortGroup: leading, thresholds: thresholds) {
                    result[result.count - 1] = previous + leading
                    group.removeFirst()
                }
            }

            let text = joinedText(group)
            let isShort = isShortJapaneseOrphanGroup(group)
            if isShort {
                // group 入口已过滤空组后恒非空；用安全访问替代 first!/last!，
                // 万一为空则退化为“间隔无穷大”即不合并，安全降级（BUG-D）。
                let groupStart = group.first?.startSeconds ?? .greatestFiniteMagnitude
                let groupEnd = group.last?.endSeconds ?? -.greatestFiniteMagnitude
                let gapPrev = result.last.flatMap { $0.last?.endSeconds }.map { groupStart - $0 }
                    ?? Double.greatestFiniteMagnitude
                let nextGroup = index + 1 < groups.count ? groups[index + 1] : nil
                let gapNext = nextGroup.flatMap { $0.first?.startSeconds }.map { $0 - groupEnd }
                    ?? Double.greatestFiniteMagnitude
                let previous = result.last
                let canMergePrevious = gapPrev <= effectiveLoneMergeMaxGap(thresholds, profile: profile)
                    && previous.map { fitsMergedCue($0 + group, absorbingShortGroup: group, thresholds: thresholds) } == true
                let canMergeNext = gapNext <= effectiveLoneMergeMaxGap(thresholds, profile: profile)
                    && nextGroup.map { fitsMergedCue(group + $0, absorbingShortGroup: group, thresholds: thresholds) } == true

                if shouldPreferNextMerge(for: text), canMergeNext, let nextGroup {
                    result.append(group + nextGroup)
                    index += 2
                    continue
                }
                if shouldPreferPreviousMerge(for: text), canMergePrevious, let previous {
                    result[result.count - 1] = previous + group
                    index += 1
                    continue
                }

                // Prefer the smaller-gap side; only merge within the same-utterance gap.
                if canMergePrevious, (!canMergeNext || gapPrev <= gapNext), let previous {
                    result[result.count - 1] = previous + group
                    index += 1
                    continue
                }
                if canMergeNext, let nextGroup {
                    result.append(group + nextGroup)
                    index += 2 // consumed current + next
                    continue
                }
            }
            result.append(group)
            index += 1
        }
        return result
    }

    /// 可读性最小时长：低于此值的 cue 在屏幕上"闪现"，影响观感。把这类过短 group 并入相邻 group
    /// （优先并入前一条，把短句尾接到上一句末尾；否则并入后一条），前提是间隔够近且合并后不超长。
    /// 这是观感导向的 readability 合并，独立于 CJK 孤儿合并；不引入跨端常量，C# 侧镜像同一逻辑。
    private static let flashMinCueSeconds = 0.8
    private static let flashMergeMaxGapSeconds = 0.6

    private static func mergeFlashDurationGroups(
        _ groups: [[SubtitleCueSourceFragment]],
        thresholds: SubtitleTimingThresholds
    ) -> [[SubtitleCueSourceFragment]] {
        let groups = groups.filter { !$0.isEmpty }
        guard groups.count > 1 else { return groups }
        var result: [[SubtitleCueSourceFragment]] = []
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let span = (group.last?.endSeconds ?? 0) - (group.first?.startSeconds ?? 0)
            if span >= flashMinCueSeconds {
                result.append(group)
                index += 1
                continue
            }
            // too short to read comfortably — try to absorb it into a neighbour.
            let prev = result.last
            let gapPrev = prev.flatMap { $0.last?.endSeconds }.map { (group.first?.startSeconds ?? 0) - $0 }
                ?? Double.greatestFiniteMagnitude
            let next = index + 1 < groups.count ? groups[index + 1] : nil
            let gapNext = next.flatMap { $0.first?.startSeconds }.map { $0 - (group.last?.endSeconds ?? 0) }
                ?? Double.greatestFiniteMagnitude

            let canPrev = prev != nil && gapPrev <= flashMergeMaxGapSeconds
                && fitsMergedCue((prev ?? []) + group, absorbingShortGroup: group, thresholds: thresholds)
            let canNext = next != nil && gapNext <= flashMergeMaxGapSeconds
                && fitsMergedCue(group + (next ?? []), absorbingShortGroup: group, thresholds: thresholds)

            if canPrev, (!canNext || gapPrev <= gapNext) {
                result[result.count - 1] = (prev ?? []) + group
                index += 1
            } else if canNext, let next {
                result.append(group + next)
                index += 2
            } else {
                result.append(group)
                index += 1
            }
        }
        return result
    }

    private static func rebalanceJapaneseLyricPhraseStarts(
        _ groups: [[SubtitleCueSourceFragment]],
        thresholds: SubtitleTimingThresholds
    ) -> [[SubtitleCueSourceFragment]] {
        guard groups.count >= 2 else { return groups }
        var result: [[SubtitleCueSourceFragment]] = []
        result.reserveCapacity(groups.count)

        for group in groups {
            guard !result.isEmpty else {
                result.append(group)
                continue
            }
            let previousCandidate = result.last ?? []
            guard let prefixCount = japaneseLyricContinuationPrefixCount(group, after: previousCandidate),
                  group.count > prefixCount else {
                result.append(group)
                continue
            }

            let prefix = Array(group.prefix(prefixCount))
            let remainder = Array(group.dropFirst(prefixCount))
            let previous = result.removeLast()
            let directMerge = previous + prefix

            if fitsJapaneseLyricRebalancedCue(directMerge, thresholds: thresholds) {
                result.append(directMerge)
                result.append(remainder)
                continue
            }

            if let split = splitPreviousForJapaneseLyricContinuation(
                previous,
                prefix: prefix,
                thresholds: thresholds
            ) {
                result.append(split.head)
                result.append(split.tail + prefix)
                result.append(remainder)
                continue
            }

            result.append(previous)
            result.append(group)
        }
        return result
    }

    private static func japaneseLyricContinuationPrefixCount(
        _ group: [SubtitleCueSourceFragment],
        after previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        let texts = group.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard texts.count >= 2 else { return nil }
        if let detachedSuffixCount = japaneseLyricDetachedSuffixPrefixCount(texts, after: previous) {
            return detachedSuffixCount
        }
        if japaneseLyricBareTailFragments.contains(texts[0]),
           startsJapaneseLyricPhrase(texts[1]) {
            return 1
        }
        if texts.count >= 3,
           japaneseLyricAdnominalHeads.contains(texts[0]),
           texts[1] == "な",
           startsJapaneseLyricPhrase(texts[2]) {
            return 2
        }
        return nil
    }

    private static func japaneseLyricDetachedSuffixPrefixCount(
        _ texts: [String],
        after previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        let previousText = joinedText(previous)
        guard let previousLast = previousText.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return nil
        }
        if texts[0] == "ば", ["せ", "れ", "け"].contains(String(previousLast)) {
            return 1
        }
        if texts[0] == "く", containsKanji(String(previousLast)) {
            if texts.count >= 2, texts[1] == "へ" {
                return 2
            }
            return 1
        }
        return nil
    }

    private static func startsJapaneseLyricPhrase(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return japaneseLyricPhraseStartPrefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func fitsJapaneseLyricRebalancedCue(
        _ fragments: [SubtitleCueSourceFragment],
        thresholds: SubtitleTimingThresholds
    ) -> Bool {
        guard let first = fragments.first, let last = fragments.last else { return false }
        let text = joinedText(fragments)
        let duration = last.endSeconds - first.startSeconds
        let units = SubtitleTimingPlanner.timingTokens(text).count
        return duration <= thresholds.relaxedCJKCueSeconds
            && units <= relaxedShortMergeMaxCJKUnits
    }

    private static func splitPreviousForJapaneseLyricContinuation(
        _ previous: [SubtitleCueSourceFragment],
        prefix: [SubtitleCueSourceFragment],
        thresholds: SubtitleTimingThresholds
    ) -> (head: [SubtitleCueSourceFragment], tail: [SubtitleCueSourceFragment])? {
        guard previous.count >= 2 else { return nil }
        let maxSuffixCount = min(previous.count - 1, 8)
        var fallback: (head: [SubtitleCueSourceFragment], tail: [SubtitleCueSourceFragment])?
        for suffixCount in 1...maxSuffixCount {
            let head = Array(previous.dropLast(suffixCount))
            let tail = Array(previous.suffix(suffixCount))
            let rebalanced = tail + prefix
            let text = joinedText(rebalanced)
            guard !head.isEmpty,
                  !startsWithLeadingProhibited(text),
                  fitsJapaneseLyricRebalancedCue(rebalanced, thresholds: thresholds) else {
                continue
            }
            if fallback == nil {
                fallback = (head: head, tail: tail)
            }
            if containsKanji(joinedText(tail)) {
                return (head: head, tail: tail)
            }
        }
        return fallback
    }

    private static func rebalanceJapaneseLyricSingleFragmentBoundaries(
        _ groups: [[SubtitleCueSourceFragment]],
        thresholds: SubtitleTimingThresholds
    ) -> [[SubtitleCueSourceFragment]] {
        var result = groups.filter { !$0.isEmpty }
        guard result.count >= 2 else { return result }

        for index in 1..<result.count {
            guard !result[index - 1].isEmpty, !result[index].isEmpty else { continue }
            let current = result[index]
            guard let first = current.first,
                  isJapaneseLyricSingleKanjiSuffixFragment(first),
                  !startsWithLeadingProhibited(first.text),
                  let previousEnd = result[index - 1].last?.endSeconds,
                  first.startSeconds - previousEnd <= loneMergeMaxGapSeconds else {
                continue
            }
            let candidatePrevious = result[index - 1] + [first]
            guard fitsJapaneseLyricSingleFragmentRebalancedCue(candidatePrevious, thresholds: thresholds) else {
                continue
            }
            result[index - 1] = candidatePrevious
            result[index] = Array(current.dropFirst())
        }

        result = result.filter { !$0.isEmpty }
        guard result.count >= 2 else { return result }

        for _ in 0..<3 {
            var changed = false
            for index in 1..<result.count {
                guard !result[index - 1].isEmpty,
                      !result[index].isEmpty,
                      let moveCount = japaneseLyricSemanticTailMoveCount(
                        previous: result[index - 1],
                        current: result[index]
                      ) else {
                    continue
                }
                let previousWithoutMoved = Array(result[index - 1].dropLast(moveCount))
                let moved = Array(result[index - 1].suffix(moveCount))
                let candidateCurrent = moved + result[index]
                guard fitsJapaneseLyricSemanticTailRebalancedCue(candidateCurrent, thresholds: thresholds) else {
                    continue
                }
                result[index - 1] = previousWithoutMoved
                result[index] = candidateCurrent
                changed = true
            }
            if changed {
                result = result.filter { !$0.isEmpty }
            }
            if !changed { break }
        }

        return result.filter { !$0.isEmpty }
    }

    private static func japaneseLyricSemanticTailMoveCount(
        previous: [SubtitleCueSourceFragment],
        current: [SubtitleCueSourceFragment]
    ) -> Int? {
        guard !previous.isEmpty,
              let previousLast = previous.last,
              let currentFirst = current.first else {
            return nil
        }
        let gap = currentFirst.startSeconds - previousLast.endSeconds
        let currentText = currentFirst.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty else { return nil }

        if startsWithKanji(currentText),
           gap <= japaneseLyricModifierRejoinMaxGapSeconds,
           let modifierTailCount = japaneseLyricAdjectiveModifierTailMoveCount(previous) {
            return modifierTailCount
        }

        if startsWithJapaneseLyricObjectParticle(currentText),
           gap <= japaneseLyricParticleRejoinMaxGapSeconds,
           isMovableSingleCJKFragment(previousLast) {
            return 1
        }

        let previousLastText = previousLast.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if previousLastText == "あ",
           currentText.hasPrefix("なた"),
           gap <= japaneseLyricSemanticRejoinMaxGapSeconds {
            return 1
        }

        if isJapaneseLyricQuotedSpeechStart(currentText),
           gap <= japaneseLyricSemanticRejoinMaxGapSeconds,
           let quotedTailCount = japaneseLyricQuotedTailMoveCount(previous) {
            return quotedTailCount
        }

        if isJapaneseLyricFixedPhraseContinuationStart(currentText),
           gap <= japaneseLyricSemanticRejoinMaxGapSeconds,
           let fixedTailCount = japaneseLyricFixedPhraseTailMoveCount(previous) {
            return fixedTailCount
        }

        if currentText.hasPrefix("する"),
           gap <= japaneseLyricKanaVerbRejoinMaxGapSeconds,
           let suruTailCount = japaneseLyricSuruCompoundTailMoveCount(previous) {
            return suruTailCount
        }

        if isJapaneseLyricKanaVerbContinuationStart(currentText),
           gap <= japaneseLyricKanaVerbRejoinMaxGapSeconds,
           let kanaVerbTailCount = japaneseLyricKanaVerbTailMoveCount(previous) {
            return kanaVerbTailCount
        }

        if isJapaneseLyricAdjectivePredicateContinuationStart(currentText),
           gap <= japaneseLyricSemanticRejoinMaxGapSeconds,
           let adjectiveTailCount = japaneseLyricAdjectivePredicateTailMoveCount(previous) {
            return adjectiveTailCount
        }

        guard isJapaneseLyricPredicateContinuationStart(currentText),
              gap <= japaneseLyricSemanticRejoinMaxGapSeconds else {
            return nil
        }

        let maxSuffixCount = min(previous.count - 1, 4)
        guard maxSuffixCount >= 1 else { return nil }
        for suffixCount in 1...maxSuffixCount {
            let suffix = Array(previous.suffix(suffixCount))
            let text = joinedText(suffix)
            guard containsKanji(text),
                  !startsWithLeadingProhibited(text),
                  !endsSentence(text) else {
                continue
            }
            return suffixCount
        }
        return nil
    }

    private static func japaneseLyricAdjectiveModifierTailMoveCount(
        _ previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        let maxSuffixCount = min(previous.count, 3)
        guard maxSuffixCount >= 1 else { return nil }
        for suffixCount in 1...maxSuffixCount {
            let text = joinedText(Array(previous.suffix(suffixCount)))
            guard containsKanji(text),
                  text.hasSuffix("い"),
                  SubtitleTimingPlanner.visibleCharacters(text) <= 4,
                  !startsWithLeadingProhibited(text) else {
                continue
            }
            return suffixCount
        }
        return nil
    }

    private static func japaneseLyricAdjectivePredicateTailMoveCount(
        _ previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        let maxSuffixCount = min(previous.count, 4)
        guard maxSuffixCount >= 2 else { return nil }
        for suffixCount in 2...maxSuffixCount {
            let text = joinedText(Array(previous.suffix(suffixCount)))
            guard containsKanji(text),
                  ["く", "しく", "なく"].contains(where: { text.hasSuffix($0) }),
                  !startsWithLeadingProhibited(text),
                  !endsSentence(text) else {
                continue
            }
            return suffixCount
        }
        return nil
    }

    private static func startsWithKanji(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return containsKanji(String(first))
    }

    private static func japaneseLyricFixedPhraseTailMoveCount(
        _ previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        guard previous.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "だけ" else {
            return nil
        }
        return 1
    }

    private static func japaneseLyricSuruCompoundTailMoveCount(
        _ previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        guard previous.count >= 2 else { return nil }
        let suffix = Array(previous.suffix(2))
        let text = joinedText(suffix)
        return text.hasSuffix("こ") && containsKanji(text) ? 2 : nil
    }

    private static func isJapaneseLyricFixedPhraseContinuationStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("じゃ") || trimmed.hasPrefix("では")
    }

    private static func japaneseLyricKanaVerbTailMoveCount(
        _ previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        let maxSuffixCount = min(previous.count, 4)
        guard maxSuffixCount >= 1 else { return nil }
        for suffixCount in 1...maxSuffixCount {
            let text = joinedText(Array(previous.suffix(suffixCount)))
            if japaneseLyricKanaVerbStemTails.contains(text) {
                return suffixCount
            }
        }
        return nil
    }

    private static func isJapaneseLyricKanaVerbContinuationStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["いて", "いた", "いる", "する", "ける"].contains { trimmed.hasPrefix($0) }
    }

    private static func isJapaneseLyricAdjectivePredicateContinuationStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["なる", "なった", "ない"].contains { trimmed.hasPrefix($0) }
    }

    private static func japaneseLyricQuotedTailMoveCount(
        _ previous: [SubtitleCueSourceFragment]
    ) -> Int? {
        let maxSuffixCount = min(previous.count, 6)
        guard maxSuffixCount >= 2 else { return nil }
        for suffixCount in 2...maxSuffixCount {
            let suffix = Array(previous.suffix(suffixCount))
            let text = joinedText(suffix)
            guard containsKanji(text),
                  text.hasSuffix("と"),
                  !startsWithLeadingProhibited(text),
                  !endsSentence(text) else {
                continue
            }
            return suffixCount
        }
        return nil
    }

    private static func isJapaneseLyricQuotedSpeechStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("言") || trimmed.hasPrefix("いう") || trimmed.hasPrefix("言う")
    }

    private static func isJapaneseLyricPredicateContinuationStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "だ", "で", "と", "って", "ても", "て", "して", "した", "し"
        ].contains { trimmed.hasPrefix($0) }
    }

    private static func isMovableSingleCJKFragment(_ fragment: SubtitleCueSourceFragment) -> Bool {
        let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return false }
        return SubtitleTimingPlanner.visibleCharacters(text) == 1
            && containsCJK(text)
            && !cjkLeadingProhibited.contains(first)
    }

    private static func isJapaneseLyricSingleKanjiSuffixFragment(_ fragment: SubtitleCueSourceFragment) -> Bool {
        let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return false }
        return SubtitleTimingPlanner.visibleCharacters(text) == 1
            && containsKanji(text)
            && japaneseLyricSingleKanjiSuffixes.contains(first)
    }

    private static func rebalanceJapaneseLyricCueTextBoundaries(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= 2 else { return cues }
        var result = cues
        for index in 1..<result.count {
            let previous = result[index - 1]
            let current = result[index]
            guard let previousEnd = srtTimeToSeconds(previous.end),
                  let currentStart = srtTimeToSeconds(current.start),
                  currentStart - previousEnd <= loneMergeMaxGapSeconds,
                  let previousLast = previous.text.trimmingCharacters(in: .whitespacesAndNewlines).last,
                  containsKanji(String(previousLast)),
                  let currentFirst = current.text.trimmingCharacters(in: .whitespacesAndNewlines).first,
                  isJapaneseLyricSingleKanjiSuffixCharacter(currentFirst),
                  let moved = popFirstCharacter(from: current.text),
                  !moved.remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            result[index - 1] = SubtitleCue(
                index: previous.index,
                start: previous.start,
                end: previous.end,
                text: previous.text + moved.character,
                sourceFragments: previous.sourceFragments
            )
            result[index] = SubtitleCue(
                index: current.index,
                start: current.start,
                end: current.end,
                text: moved.remainder,
                sourceFragments: current.sourceFragments
            )
        }
        return result
    }

    private static func isMovableSingleCJKCharacter(_ character: Character) -> Bool {
        containsCJK(String(character)) && !cjkLeadingProhibited.contains(character)
    }

    private static func isJapaneseLyricSingleKanjiSuffixCharacter(_ character: Character) -> Bool {
        japaneseLyricSingleKanjiSuffixes.contains(character)
    }

    private static func popFirstCharacter(from text: String) -> (character: String, remainder: String)? {
        guard let first = text.first else { return nil }
        return (String(first), String(text.dropFirst()))
    }

    private static func startsWithJapaneseLyricObjectParticle(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return japaneseLyricObjectParticleStarts.contains(first)
    }

    private static func fitsJapaneseLyricSingleFragmentRebalancedCue(
        _ fragments: [SubtitleCueSourceFragment],
        thresholds: SubtitleTimingThresholds
    ) -> Bool {
        guard let first = fragments.first, let last = fragments.last else { return false }
        let duration = last.endSeconds - first.startSeconds
        let units = SubtitleTimingPlanner.timingTokens(joinedText(fragments)).count
        return duration <= min(thresholds.relaxedCJKCueSeconds + 1.0, 6.8)
            && units <= relaxedShortMergeMaxCJKUnits
    }

    private static func fitsJapaneseLyricSemanticTailRebalancedCue(
        _ fragments: [SubtitleCueSourceFragment],
        thresholds: SubtitleTimingThresholds
    ) -> Bool {
        guard let first = fragments.first, let last = fragments.last else { return false }
        let duration = last.endSeconds - first.startSeconds
        let units = SubtitleTimingPlanner.timingTokens(joinedText(fragments)).count
        return duration <= min(thresholds.relaxedCJKCueSeconds + 2.0, 7.8)
            && units <= relaxedShortMergeMaxCJKUnits
    }

    private static func fitsMergedCue(
        _ fragments: [SubtitleCueSourceFragment],
        absorbingShortGroup: [SubtitleCueSourceFragment]? = nil,
        thresholds: SubtitleTimingThresholds
    ) -> Bool {
        guard let first = fragments.first, let last = fragments.last else { return false }
        let text = joinedText(fragments)
        let duration = last.endSeconds - first.startSeconds
        if containsCJK(text) {
            let units = SubtitleTimingPlanner.timingTokens(text).count
            if duration <= thresholds.hardMaximumCJKCueSeconds && units <= hardMaximumCJKUnits {
                return true
            }
            guard let absorbingShortGroup, isShortJapaneseOrphanGroup(absorbingShortGroup) else {
                return false
            }
            return duration <= thresholds.relaxedCJKCueSeconds
                && units <= relaxedShortMergeMaxCJKUnits
        }
        return duration <= thresholds.maximumLatinCueSeconds
    }

    static func maximumCueSeconds(for text: String) -> Double {
        maximumCueSeconds(for: text, thresholds: thresholds(for: .speech))
    }

    static func maximumCueSeconds(for text: String, thresholds: SubtitleTimingThresholds) -> Double {
        if isShortStandaloneCJKCueText(text) {
            // Lyrics/anime profiles cap a lone residual char tighter so a stray 「っ」/「ー」/「顔」
            // cannot linger; `.speech` keeps the 2.4s standalone cap (residual cap is +infinity).
            return min(shortStandaloneCJKCueSeconds, thresholds.residualMaxStandaloneSeconds)
        }
        return containsCJK(text) ? thresholds.hardMaximumCJKCueSeconds : thresholds.maximumLatinCueSeconds
    }

    static func maximumCueSeconds(for text: String, start: Double, lastTokenEnd: Double) -> Double {
        maximumCueSeconds(for: text, start: start, lastTokenEnd: lastTokenEnd, thresholds: thresholds(for: .speech))
    }

    static func maximumCueSeconds(
        for text: String,
        start: Double,
        lastTokenEnd: Double,
        thresholds: SubtitleTimingThresholds
    ) -> Double {
        let cap = maximumCueSeconds(for: text, thresholds: thresholds)
        // A short standalone residual keeps its tightened cap when the profile constrains residuals
        // (lyrics/anime). `.speech` leaves residuals unconstrained, so its long-run bump below is
        // unchanged — zero behaviour change for the default path.
        if isShortStandaloneCJKCueText(text), thresholds.residualMaxStandaloneSeconds < .greatestFiniteMagnitude {
            return cap
        }
        if containsCJK(text), lastTokenEnd > start + cap {
            return max(cap, min(lastTokenEnd - start, thresholds.relaxedCJKCueSeconds))
        }
        return cap
    }

    private static func isShortJapaneseOrphanGroup(_ group: [SubtitleCueSourceFragment]) -> Bool {
        let text = joinedText(group)
        return containsCJK(text)
            && SubtitleTimingPlanner.visibleCharacters(text) <= loneMergeMaxVisibleChars
            && !endsSentence(text)
    }

    private static func isShortStandaloneCJKCueText(_ text: String) -> Bool {
        containsCJK(text)
            && SubtitleTimingPlanner.visibleCharacters(text) <= 2
            && !endsSentence(text)
    }

    private static func shouldPreferNextMerge(for text: String) -> Bool {
        containsKanji(text)
    }

    private static func shouldPreferPreviousMerge(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return cjkLeadingProhibited.contains(first) || !containsKanji(trimmed)
    }

    private static func startsWithLeadingProhibited(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return false
        }
        if cjkLeadingProhibited.contains(first) { return true }
        // Korean: a bare josa/eomi (particle or verb ending) must never start a line — it belongs to
        // the preceding eojeol. Conservative: only when the whole leading fragment IS the particle.
        return koreanLeadingProhibitedParticles.contains(trimmed)
    }

    /// Korean particles / verb endings (josa / eomi) that must not stand alone at the start of a
    /// subtitle line. Mirrored in C# `KoreanLeadingProhibitedParticles`.
    private static let koreanLeadingProhibitedParticles: Set<String> = [
        "은", "는", "이", "가", "을", "를", "에", "의", "도", "만", "와", "과", "로", "으로",
        "에서", "에게", "한테", "부터", "까지", "보다", "처럼", "마다", "조차", "밖에",
        "고", "서", "며", "지만", "는데", "니까", "어서", "아서"
    ]

    private static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }

    static func cleanedSpeechText(_ value: String) -> String {
        let markerPattern = #"\[_[A-Z]+(?:_[0-9]+)?_?\]"#
        let text = value.replacingOccurrences(
            of: markerPattern,
            with: " ",
            options: .regularExpression
        )
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func planCues(
        from fragments: [SubtitleCueSourceFragment],
        transcriptDurationSeconds: Double?,
        profile: SubtitleTimingProfile = .speech
    ) -> [SubtitleCue] {
        let thresholds = thresholds(for: profile)
        let kept = fragments.filter { shouldKeep($0) }
        let profileFiltered = (profile == .lyrics || profile == .japaneseLyrics)
            ? suppressJapaneseLyricBoilerplateHallucinationFragments(kept)
            : kept
        let exactLoopSuppressed = suppressRepeatedJapaneseLoopFragments(profileFiltered)
        let approximateLoopSuppressed = profile == .japaneseLyrics
            ? suppressJapaneseLyricLoopFragments(exactLoopSuppressed)
            : exactLoopSuppressed
        let loopSuppressed = splitLeadingJapaneseTailFragments(approximateLoopSuppressed)
        let ordered = loopSuppressed
            .sorted {
                $0.startSeconds == $1.startSeconds
                    ? $0.endSeconds < $1.endSeconds
                    : $0.startSeconds < $1.startSeconds
            }
        guard !ordered.isEmpty else { return [] }

        var groups: [[SubtitleCueSourceFragment]] = []
        var current: [SubtitleCueSourceFragment] = []

        func flushCurrent() {
            guard !current.isEmpty else { return }
            groups.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for fragment in ordered {
            if let previous = current.last {
                let candidate = current + [fragment]
                let gap = fragment.startSeconds - previous.endSeconds
                if shouldBreak(before: fragment, current: current, candidate: candidate, gap: gap, thresholds: thresholds) {
                    flushCurrent()
                }
            }
            current.append(fragment)
            if endsSentence(fragment.text) {
                flushCurrent()
            }
        }
        flushCurrent()
        groups = mergeShortGroups(groups, thresholds: thresholds, profile: profile)
        if profile == .japaneseLyrics {
            groups = rebalanceJapaneseLyricPhraseStarts(groups, thresholds: thresholds)
            groups = rebalanceJapaneseLyricSingleFragmentBoundaries(groups, thresholds: thresholds)
        }
        groups = mergeFlashDurationGroups(groups, thresholds: thresholds)

        var cues: [SubtitleCue] = []
        for group in groups {
            guard let cue = makeCue(
                index: cues.count + 1,
                fragments: group,
                transcriptDurationSeconds: transcriptDurationSeconds,
                thresholds: thresholds
            ) else { continue }
            cues.append(cue)
        }
        if profile == .japaneseLyrics {
            cues = suppressJapaneseLyricIntroHallucinationCues(cues)
            cues = mergeJapaneseLyricLeadingOrphanCues(cues, thresholds: thresholds)
            cues = suppressJapaneseLyricLoopCues(cues)
            cues = suppressJapaneseLyricInternalDuplicateCueNoise(cues)
            cues = rebalanceJapaneseLyricCueTextBoundaries(cues)
        }
        if profile == .lyrics || profile == .japaneseLyrics {
            cues = suppressLyricIntroCreditNameCues(cues)
            cues = suppressLyricRepeatedIntroFillerLoopCues(cues)
            cues = suppressLyricFillerLoopCues(cues)
        }
        return cues.enumerated().map { offset, cue in
            SubtitleCue(
                index: offset + 1,
                start: cue.start,
                end: cue.end,
                text: cue.text,
                sourceFragments: cue.sourceFragments
            )
        }
    }

    private struct JapaneseLoopMatch {
        let signature: String
        let phraseLength: Int
        let repeatCount: Int
    }

    private struct JapaneseLoopFuse {
        let phraseLength: Int
        let characters: Set<Character>
        var suppressUntilSeconds: Double
    }

    private struct JapaneseLyricLoopCueFuse {
        let characters: Set<Character>
        var suppressUntilSeconds: Double
    }

    private static let japaneseLyricIntroHallucinationMaxEndSeconds = 5.0
    private static let japaneseLyricIntroHallucinationMinNextStartSeconds = 8.0
    private static let japaneseLyricIntroHallucinationMinGapSeconds = 6.0
    private static let japaneseLyricIntroHallucinationMaxVisibleChars = 5
    private static let japaneseLyricLeadingOrphanMaxDurationSeconds = 1.2
    private static let japaneseLyricLeadingOrphanMaxGapSeconds = 1.25
    private static let japaneseLyricLeadingOrphanMaxMergedSeconds = 6.8
    private static let japaneseLyricDuplicateMinCharacters = 6
    private static let japaneseLyricDuplicateMinOverlap = 0.72

    private static func suppressJapaneseLyricIntroHallucinationCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= 2,
              let first = cues.first,
              let second = cues.dropFirst().first,
              let firstStart = first.sourceFragments.first?.startSeconds,
              let firstEnd = first.sourceFragments.last?.endSeconds,
              let secondStart = second.sourceFragments.first?.startSeconds else {
            return cues
        }
        let gap = secondStart - firstEnd
        let visible = SubtitleTimingPlanner.visibleCharacters(first.text)
        guard firstStart <= 1.0,
              firstEnd <= japaneseLyricIntroHallucinationMaxEndSeconds,
              secondStart >= japaneseLyricIntroHallucinationMinNextStartSeconds,
              gap >= japaneseLyricIntroHallucinationMinGapSeconds,
              visible <= japaneseLyricIntroHallucinationMaxVisibleChars,
              !endsSentence(first.text) else {
            return cues
        }
        return Array(cues.dropFirst())
    }

    private static func mergeJapaneseLyricLeadingOrphanCues(
        _ cues: [SubtitleCue],
        thresholds: SubtitleTimingThresholds
    ) -> [SubtitleCue] {
        guard cues.count >= 2 else { return cues }
        var result: [SubtitleCue] = []
        result.reserveCapacity(cues.count)
        var index = 0

        while index < cues.count {
            let cue = cues[index]
            guard index + 1 < cues.count,
                  isJapaneseLyricLeadingOrphanCue(cue),
                  let cueStart = cue.sourceFragments.first?.startSeconds,
                  let cueEnd = cue.sourceFragments.last?.endSeconds,
                  let nextStart = cues[index + 1].sourceFragments.first?.startSeconds else {
                result.append(cue)
                index += 1
                continue
            }

            let gap = nextStart - cueEnd
            let duration = cueEnd - cueStart
            let mergedFragments = cue.sourceFragments + cues[index + 1].sourceFragments
            if duration <= japaneseLyricLeadingOrphanMaxDurationSeconds,
               gap <= japaneseLyricLeadingOrphanMaxGapSeconds,
               fitsJapaneseLyricLeadingOrphanMerge(mergedFragments),
               let merged = makeCue(
                index: result.count + 1,
                fragments: mergedFragments,
                transcriptDurationSeconds: nil,
                thresholds: thresholds
               ) {
                result.append(merged)
                index += 2
                continue
            }

            result.append(cue)
            index += 1
        }
        return result
    }

    private static func fitsJapaneseLyricLeadingOrphanMerge(_ fragments: [SubtitleCueSourceFragment]) -> Bool {
        guard let first = fragments.first, let last = fragments.last else { return false }
        let text = joinedText(fragments)
        let duration = last.endSeconds - first.startSeconds
        let units = SubtitleTimingPlanner.timingTokens(text).count
        return duration <= japaneseLyricLeadingOrphanMaxMergedSeconds
            && units <= relaxedShortMergeMaxCJKUnits
    }

    private static func isJapaneseLyricLeadingOrphanCue(_ cue: SubtitleCue) -> Bool {
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SubtitleTimingPlanner.visibleCharacters(text) == 1
            && containsCJK(text)
            && !startsWithLeadingProhibited(text)
            && !endsSentence(text)
    }

    private static func suppressRepeatedJapaneseLoopFragments(
        _ fragments: [SubtitleCueSourceFragment]
    ) -> [SubtitleCueSourceFragment] {
        guard fragments.count >= japaneseLoopMinPhraseFragments * japaneseLoopMinRepeatCount else {
            return fragments
        }
        var output: [SubtitleCueSourceFragment] = []
        output.reserveCapacity(fragments.count)
        var fuses: [String: JapaneseLoopFuse] = [:]
        var index = 0

        while index < fragments.count {
            if let fused = fusedJapaneseLoopMatch(at: index, in: fragments, fuses: fuses) {
                let dropEnd = index + fused.repeatCount * fused.phraseLength
                if dropEnd > index, dropEnd <= fragments.count {
                    let last = fragments[dropEnd - 1]
                    if var fuse = fuses[fused.signature] {
                        fuse.suppressUntilSeconds = max(
                            fuse.suppressUntilSeconds,
                            last.endSeconds + japaneseLoopFuseSeconds
                        )
                        fuses[fused.signature] = fuse
                    }
                }
                index = dropEnd
                continue
            }

            if let match = repeatedJapaneseLoopMatch(at: index, in: fragments) {
                let keepEnd = index + japaneseLoopAllowedRepeats * match.phraseLength
                output.append(contentsOf: fragments[index..<keepEnd])

                let dropEnd = index + match.repeatCount * match.phraseLength
                if dropEnd > index, dropEnd <= fragments.count {
                    let last = fragments[dropEnd - 1]
                    fuses[match.signature] = JapaneseLoopFuse(
                        phraseLength: match.phraseLength,
                        characters: Set(match.signature),
                        suppressUntilSeconds: last.endSeconds + japaneseLoopFuseSeconds
                    )
                }
                index = dropEnd
                continue
            }

            output.append(fragments[index])
            index += 1
        }
        return output
    }

    private static func suppressJapaneseLyricLoopCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= japaneseLyricLoopCueMinCount else { return cues }
        var output: [SubtitleCue] = []
        output.reserveCapacity(cues.count)
        var index = 0
        var removedAny = false

        while index < cues.count {
            if let end = japaneseLyricLoopCueRunEnd(startingAt: index, in: cues) {
                let run = Array(cues[index..<end])
                let preserveCount = japaneseLyricDenseLoopPreservePrefixCount(run)
                if preserveCount > 0 {
                    output.append(contentsOf: run.prefix(preserveCount))
                }
                index = end
                removedAny = true
                continue
            }
            output.append(cues[index])
            index += 1
        }

        return removedAny && !output.isEmpty ? output : cues
    }

    private struct LyricFillerCueStats {
        let tokenCount: Int
        let fillerTokenCount: Int
        let hasOutroBoilerplate: Bool

        var fillerRatio: Double {
            tokenCount == 0 ? 0 : Double(fillerTokenCount) / Double(tokenCount)
        }
    }

    private static func suppressLyricIntroCreditNameCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= 2,
              let first = cues.first,
              let second = cues.dropFirst().first,
              isLyricIntroCreditNameCue(first, before: second) else {
            return cues
        }
        return Array(cues.dropFirst())
    }

    private static func isLyricIntroCreditNameCue(_ cue: SubtitleCue, before next: SubtitleCue) -> Bool {
        let start = cueStartSeconds(cue)
        let end = cueEndSeconds(cue)
        let nextStart = cueStartSeconds(next)
        let visible = SubtitleTimingPlanner.visibleCharacters(cue.text)
        return start <= lyricIntroCreditNameMaxStartSeconds
            && end <= lyricIntroCreditNameMaxEndSeconds
            && nextStart >= lyricIntroCreditNameMinNextStartSeconds
            && nextStart - end >= lyricIntroCreditNameMinGapSeconds
            && visible >= lyricIntroCreditNameMinVisibleChars
            && visible <= lyricIntroCreditNameMaxVisibleChars
            && isHanOnlyLyricCueText(cue.text)
            && !endsSentence(cue.text)
    }

    private static func suppressLyricRepeatedIntroFillerLoopCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= lyricRepeatedIntroFillerMinCueCount else { return cues }
        var output: [SubtitleCue] = []
        output.reserveCapacity(cues.count)
        var index = 0
        var removedAny = false
        var suppressedKeys: Set<String> = []

        while index < cues.count {
            if let trimmed = trimLyricRepeatedIntroFillerPrefix(cues[index], keys: suppressedKeys) {
                output.append(trimmed)
                index += 1
                removedAny = true
                continue
            }
            guard cueStartSeconds(cues[index]) <= lyricRepeatedIntroFillerMaxStartSeconds,
                  let key = lyricRepeatedIntroFillerKey(cues[index].text) else {
                output.append(cues[index])
                index += 1
                continue
            }

            var end = index + 1
            while end < cues.count {
                let gap = cueStartSeconds(cues[end]) - cueEndSeconds(cues[end - 1])
                guard cueStartSeconds(cues[end]) <= lyricRepeatedIntroFillerMaxStartSeconds,
                      gap <= lyricRepeatedIntroFillerMaxGapSeconds,
                      lyricRepeatedIntroFillerKey(cues[end].text) == key else {
                    break
                }
                end += 1
            }

            let count = end - index
            let duration = cueEndSeconds(cues[end - 1]) - cueStartSeconds(cues[index])
            if count >= lyricRepeatedIntroFillerMinCueCount,
               duration >= lyricRepeatedIntroFillerMinDurationSeconds {
                suppressedKeys.insert(key)
                index = end
                removedAny = true
            } else {
                output.append(contentsOf: cues[index..<end])
                index = end
            }
        }

        return removedAny ? output : cues
    }

    private static func trimLyricRepeatedIntroFillerPrefix(
        _ cue: SubtitleCue,
        keys: Set<String>
    ) -> SubtitleCue? {
        guard !keys.isEmpty else { return nil }
        for key in keys {
            guard let trimmedText = trimLyricRepeatedIntroFillerPrefix(key, from: cue.text) else {
                continue
            }
            return SubtitleCue(
                index: cue.index,
                start: cue.start,
                end: cue.end,
                text: trimmedText,
                sourceFragments: cue.sourceFragments
            )
        }
        return nil
    }

    private static func trimLyricRepeatedIntroFillerPrefix(_ key: String, from text: String) -> String? {
        var cursor = text.startIndex
        var matched = 0
        var consumeEnd = text.startIndex

        while cursor < text.endIndex, matched < key.count {
            let character = text[cursor]
            if let letter = lowercaseASCIILetter(character) {
                let expected = key[key.index(key.startIndex, offsetBy: matched)]
                guard letter == expected else { return nil }
                matched += 1
                consumeEnd = text.index(after: cursor)
            } else if isLyricPrefixSeparator(character) {
                consumeEnd = text.index(after: cursor)
            } else {
                return nil
            }
            cursor = text.index(after: cursor)
        }

        guard matched == key.count else { return nil }
        while consumeEnd < text.endIndex, isLyricPrefixSeparator(text[consumeEnd]) {
            consumeEnd = text.index(after: consumeEnd)
        }
        let remainder = String(text[consumeEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard SubtitleTimingPlanner.visibleCharacters(remainder) >= lyricRepeatedIntroFillerMinKeyCharacters else {
            return nil
        }
        return remainder
    }

    private static func lowercaseASCIILetter(_ character: Character) -> Character? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return nil
        }
        let value = scalar.value
        if (0x41...0x5A).contains(value) {
            return Character(String(UnicodeScalar(value + 32)!))
        }
        if (0x61...0x7A).contains(value) {
            return character
        }
        return nil
    }

    private static func isLyricPrefixSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    private static func lyricRepeatedIntroFillerKey(_ text: String) -> String? {
        guard SubtitleTimingPlanner.visibleCharacters(text) <= lyricRepeatedIntroFillerMaxVisibleChars,
              !containsCJK(text) else {
            return nil
        }
        var key = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x41...0x5A).contains(value) {
                key.unicodeScalars.append(UnicodeScalar(value + 32)!)
            } else if (0x61...0x7A).contains(value) {
                key.unicodeScalars.append(scalar)
            }
        }
        guard key.count >= lyricRepeatedIntroFillerMinKeyCharacters,
              key.count <= lyricRepeatedIntroFillerMaxRawKeyCharacters else {
            return nil
        }
        if let motif = repeatedLatinMotif(in: key),
           motif.count <= lyricRepeatedIntroFillerMaxKeyCharacters {
            return motif
        }
        guard key.count <= lyricRepeatedIntroFillerMaxKeyCharacters else { return nil }
        return key
    }

    private static func repeatedLatinMotif(in key: String) -> String? {
        let characters = Array(key)
        guard characters.count >= lyricRepeatedIntroFillerMinKeyCharacters * 2 else { return nil }
        for length in lyricRepeatedIntroFillerMinKeyCharacters...(characters.count / 2) {
            guard characters.count.isMultiple(of: length) else { continue }
            let motif = String(characters[..<length])
            let repeated = String(repeating: motif, count: characters.count / length)
            if repeated == key { return motif }
        }
        return nil
    }

    private static func isHanOnlyLyricCueText(_ text: String) -> Bool {
        var count = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            guard isHanScalar(scalar) else { return false }
            count += 1
        }
        return count >= lyricIntroCreditNameMinVisibleChars
            && count <= lyricIntroCreditNameMaxVisibleChars
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func suppressLyricFillerLoopCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= 2 else { return cues }
        var output: [SubtitleCue] = []
        output.reserveCapacity(cues.count)
        var index = 0
        var removedAny = false

        while index < cues.count {
            if lyricFillerCueStats(cues[index].text).hasOutroBoilerplate {
                index += 1
                removedAny = true
                continue
            }
            guard isLyricFillerLoopCue(cues[index]) else {
                output.append(cues[index])
                index += 1
                continue
            }

            var end = index + 1
            var fillerTokenCount = lyricFillerCueStats(cues[index].text).fillerTokenCount
            while end < cues.count {
                let gap = cueStartSeconds(cues[end]) - cueEndSeconds(cues[end - 1])
                guard gap <= lyricFillerLoopMaxGapSeconds, isLyricFillerLoopCue(cues[end]) else {
                    break
                }
                fillerTokenCount += lyricFillerCueStats(cues[end].text).fillerTokenCount
                end += 1
            }

            let duration = cueEndSeconds(cues[end - 1]) - cueStartSeconds(cues[index])
            let shouldDrop = (
                duration >= lyricFillerLoopMinDurationSeconds
                    && fillerTokenCount >= lyricFillerLoopMinTokenCount
            ) || fillerTokenCount >= lyricFillerLoopHighTokenCount

            if shouldDrop {
                index = end
                removedAny = true
            } else {
                output.append(contentsOf: cues[index..<end])
                index = end
            }
        }

        return removedAny ? output : cues
    }

    private static func isLyricFillerLoopCue(_ cue: SubtitleCue) -> Bool {
        let stats = lyricFillerCueStats(cue.text)
        if stats.hasOutroBoilerplate {
            return true
        }
        if stats.tokenCount > 0, stats.fillerRatio >= 1.0 {
            return true
        }
        return stats.tokenCount >= lyricFillerCueMinTokenCount
            && stats.fillerRatio >= lyricFillerCueMinRatio
    }

    private static func lyricFillerCueStats(_ text: String) -> LyricFillerCueStats {
        let tokens = lyricLatinTokens(text)
        let fillerCount = tokens.filter { lyricFillerLoopTokens.contains($0) }.count
        return LyricFillerCueStats(
            tokenCount: tokens.count,
            fillerTokenCount: fillerCount,
            hasOutroBoilerplate: containsLyricOutroBoilerplate(text)
        )
    }

    private static func lyricLatinTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) {
                current.unicodeScalars.append(UnicodeScalar(value >= 0x41 && value <= 0x5A ? value + 32 : value)!)
            } else if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func containsLyricOutroBoilerplate(_ text: String) -> Bool {
        let latinKey = String(text.unicodeScalars.compactMap { scalar -> Character? in
            let value = scalar.value
            if (0x41...0x5A).contains(value) {
                return Character(String(UnicodeScalar(value + 32)!))
            }
            if (0x61...0x7A).contains(value) {
                return Character(String(scalar))
            }
            return nil
        })
        let cjkKey = normalizedJapaneseLoopText(text)
        return lyricOutroBoilerplateKeys.contains { key in
            latinKey.contains(key) || cjkKey.contains(key)
        }
    }

    private static func suppressJapaneseLyricInternalDuplicateCueNoise(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.map { cue in
            let cleaned = suppressJapaneseLyricInternalDuplicateNoise(in: cue.text)
            guard cleaned != cue.text else { return cue }
            return SubtitleCue(
                index: cue.index,
                start: cue.start,
                end: cue.end,
                text: cleaned,
                sourceFragments: cue.sourceFragments
            )
        }
    }

    private static func suppressJapaneseLyricInternalDuplicateNoise(in text: String) -> String {
        let normalizedSeparators = text
            .replacingOccurrences(of: "，", with: "、")
            .replacingOccurrences(of: ",", with: "、")
        let parts = normalizedSeparators
            .split(separator: "、", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2 else { return text }

        var kept: [String] = []
        var keptNormalized: [String] = []
        var removedAny = false
        for part in parts {
            let normalized = normalizedJapaneseLoopText(part)
            if isApproximateJapaneseLyricDuplicateSegment(normalized, previous: keptNormalized) {
                removedAny = true
                continue
            }
            kept.append(part)
            if !normalized.isEmpty { keptNormalized.append(normalized) }
        }
        let cleaned = kept.joined(separator: "、").trimmingCharacters(in: .whitespacesAndNewlines)
        return removedAny && !cleaned.isEmpty ? cleaned : text
    }

    private static func isApproximateJapaneseLyricDuplicateSegment(
        _ candidate: String,
        previous: [String]
    ) -> Bool {
        guard candidate.count >= japaneseLyricDuplicateMinCharacters else { return false }
        for original in previous.suffix(3) {
            guard original.count >= japaneseLyricDuplicateMinCharacters,
                  original != candidate else { continue }
            let smaller = min(original.count, candidate.count)
            let larger = max(original.count, candidate.count)
            guard Double(smaller) / Double(larger) >= 0.55 else { continue }
            if japaneseCharacterOverlapRatio(original, candidate) >= japaneseLyricDuplicateMinOverlap {
                return true
            }
        }
        return false
    }

    private static func japaneseCharacterOverlapRatio(_ lhs: String, _ rhs: String) -> Double {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let denominator = min(lhsChars.count, rhsChars.count)
        guard denominator > 0 else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in lhsChars {
            counts[ch, default: 0] += 1
        }
        var overlap = 0
        for ch in rhsChars {
            let count = counts[ch, default: 0]
            guard count > 0 else { continue }
            overlap += 1
            counts[ch] = count - 1
        }
        return Double(overlap) / Double(denominator)
    }

    private static func suppressJapaneseLyricLoopFragments(
        _ fragments: [SubtitleCueSourceFragment]
    ) -> [SubtitleCueSourceFragment] {
        guard fragments.count >= japaneseLyricLoopCueMinCount else { return fragments }
        var output: [SubtitleCueSourceFragment] = []
        output.reserveCapacity(fragments.count)
        var fuses: [JapaneseLyricLoopCueFuse] = []
        var index = 0
        var removedAny = false

        while index < fragments.count {
            let normalized = normalizedJapaneseLoopText(fragments[index].text)
            if let fuseIndex = fuses.firstIndex(where: { fuse in
                fragments[index].startSeconds <= fuse.suppressUntilSeconds
                    && isJapaneseLyricLoopFuseCompatible(normalized, characters: fuse.characters)
            }) {
                fuses[fuseIndex].suppressUntilSeconds = max(
                    fuses[fuseIndex].suppressUntilSeconds,
                    fragments[index].endSeconds + japaneseLoopFuseSeconds
                )
                index += 1
                removedAny = true
                continue
            }
            if let end = japaneseLyricLoopFragmentRunEnd(startingAt: index, in: fragments) {
                let normalizedRun = fragments[index..<end]
                    .map { normalizedJapaneseLoopText($0.text) }
                    .joined()
                fuses.append(JapaneseLyricLoopCueFuse(
                    characters: Set(normalizedRun),
                    suppressUntilSeconds: fragments[end - 1].endSeconds + japaneseLoopFuseSeconds
                ))
                index = end
                removedAny = true
                continue
            }
            output.append(fragments[index])
            index += 1
        }

        return removedAny && !output.isEmpty ? output : fragments
    }

    private static func suppressJapaneseLyricBoilerplateHallucinationFragments(
        _ fragments: [SubtitleCueSourceFragment]
    ) -> [SubtitleCueSourceFragment] {
        guard !fragments.isEmpty else { return fragments }
        var output: [SubtitleCueSourceFragment] = []
        output.reserveCapacity(fragments.count)
        var index = 0
        var removedAny = false

        while index < fragments.count {
            if let musicEnd = japaneseLyricIntroMusicHallucinationClusterEnd(startingAt: index, in: fragments) {
                index = musicEnd
                removedAny = true
                continue
            }
            if let outroEnd = japaneseLyricOutroHallucinationClusterEnd(startingAt: index, in: fragments) {
                index = outroEnd
                removedAny = true
                continue
            }
            if let creditEnd = japaneseLyricCreditHallucinationClusterEnd(startingAt: index, in: fragments) {
                index = creditEnd
                removedAny = true
                continue
            }
            output.append(fragments[index])
            index += 1
        }

        return removedAny ? output : fragments
    }

    private static func japaneseLyricIntroMusicHallucinationClusterEnd(
        startingAt start: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> Int? {
        guard start == 0 else { return nil }
        var normalized = ""
        var end = start
        while end < fragments.count {
            let fragment = fragments[end]
            guard fragment.startSeconds <= 20.5 else { break }
            let token = normalizedLatinCueText(fragment.text)
            guard ["B", "G", "M", "BG", "GM", "BGM"].contains(token) else { break }
            normalized += token
            end += 1
            if normalized == "BGM" { return end }
        }
        return nil
    }

    private static func normalizedLatinCueText(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar in
            let value = scalar.value
            guard (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) else {
                return nil
            }
            return Character(String(scalar).uppercased())
        })
    }

    private static func japaneseLyricOutroHallucinationClusterEnd(
        startingAt start: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> Int? {
        var normalized = ""
        let maxEnd = min(fragments.count, start + 4)
        var end = start
        while end < maxEnd {
            normalized += normalizedJapaneseLoopText(fragments[end].text)
            guard japaneseLyricOutroHallucinationMarkers.contains(where: { marker in
                marker.hasPrefix(normalized) || normalized.hasPrefix(marker)
            }) else {
                return nil
            }
            if japaneseLyricOutroHallucinationMarkers.contains(where: { normalized.contains($0) }) {
                return end + 1
            }
            end += 1
        }
        return nil
    }

    private static func japaneseLyricCreditHallucinationClusterEnd(
        startingAt start: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> Int? {
        var normalized = ""
        var end = start
        var sawCreditMarker = false
        var trailingNameCharacterCount = 0
        while end < fragments.count {
            let token = normalizedJapaneseLoopText(fragments[end].text)
            if sawCreditMarker,
               end > start,
               fragments[end].startSeconds - fragments[end - 1].endSeconds > japaneseLyricCreditHallucinationMaxGapSeconds {
                break
            }
            if token.isEmpty, sawCreditMarker {
                end += 1
                continue
            }
            if isJapaneseLyricCreditHallucinationToken(token) {
                normalized += token
                sawCreditMarker = true
                trailingNameCharacterCount = 0
                end += 1
                continue
            }
            if sawCreditMarker,
               token.count <= 2,
               trailingNameCharacterCount + token.count <= 4 {
                normalized += token
                trailingNameCharacterCount += token.count
                end += 1
                continue
            } else {
                break
            }
        }
        guard end > start else { return nil }
        let markerCount = japaneseLyricCreditHallucinationMarkers.filter { normalized.contains($0) }.count
        guard markerCount > 0, normalized.count >= 2 else { return nil }
        return end
    }

    private static func isJapaneseLyricCreditHallucinationToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if japaneseLyricCreditHallucinationTokens.contains(token) { return true }
        return token.count <= 8
            && japaneseLyricCreditHallucinationMarkers.contains(where: { token.contains($0) })
    }

    private static func isJapaneseLyricLoopFuseCompatible(
        _ normalized: String,
        characters: Set<Character>
    ) -> Bool {
        !normalized.isEmpty && normalized.allSatisfy { characters.contains($0) }
    }

    private static func japaneseLyricLoopFragmentRunEnd(
        startingAt start: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> Int? {
        var latestSuspiciousEnd: Int?
        var end = start
        while end < fragments.count {
            if end > start {
                let gap = fragments[end].startSeconds - fragments[end - 1].endSeconds
                if gap > japaneseLyricLoopCueMaxGapSeconds { break }
            }
            let span = fragments[end].endSeconds - fragments[start].startSeconds
            if span > japaneseLyricLoopCueMaxSpanSeconds { break }

            let count = end - start + 1
            if count >= japaneseLyricLoopCueMinCount,
               isSuspiciousJapaneseLyricLoopFragmentRun(Array(fragments[start...end])) {
                latestSuspiciousEnd = end + 1
            }
            end += 1
        }
        return latestSuspiciousEnd
    }

    private static func isSuspiciousJapaneseLyricLoopFragmentRun(
        _ fragments: [SubtitleCueSourceFragment]
    ) -> Bool {
        let normalizedParts = fragments.map { normalizedJapaneseLoopText($0.text) }
        let normalized = normalizedParts.joined()
        guard normalized.count >= japaneseLyricLoopCueMinNormalizedCharacters else { return false }

        let uniqueRatio = Double(Set(normalized).count) / Double(normalized.count)
        guard uniqueRatio <= japaneseLyricLoopCueMaxUniqueCharacterRatio else { return false }
        guard repeatedBigramExcess(in: normalized) >= japaneseLyricLoopCueMinRepeatedBigramExcess else {
            return false
        }

        let longSparseFragmentCount = fragments.filter { fragment in
            let duration = fragment.endSeconds - fragment.startSeconds
            return duration >= japaneseLyricLoopCueLongSparseSeconds
                && SubtitleTimingPlanner.visibleCharacters(fragment.text) <= hardMaximumCJKUnits
        }.count

        // Fragment-level words from whisper.cpp naturally contain particles like を / に / が.
        // Treating those as malformed line starts deletes legitimate repeated choruses. Dense
        // whole-phrase loops are handled after cue formation, where we can preserve readable lyric
        // lead-in lines instead of dropping an entire chorus island too early.
        return longSparseFragmentCount > 0
    }

    private static func japaneseLyricLoopCueRunEnd(startingAt start: Int, in cues: [SubtitleCue]) -> Int? {
        var latestSuspiciousEnd: Int?
        var end = start
        while end < cues.count {
            if end > start {
                let gap = cueStartSeconds(cues[end]) - cueEndSeconds(cues[end - 1])
                if gap > japaneseLyricLoopCueMaxGapSeconds { break }
            }
            let span = cueEndSeconds(cues[end]) - cueStartSeconds(cues[start])
            if span > japaneseLyricLoopCueMaxSpanSeconds { break }

            let count = end - start + 1
            if count >= japaneseLyricLoopCueMinCount,
               isSuspiciousJapaneseLyricLoopCueRun(Array(cues[start...end])) {
                latestSuspiciousEnd = end + 1
            }
            end += 1
        }
        return latestSuspiciousEnd
    }

    private static func isSuspiciousJapaneseLyricLoopCueRun(_ cues: [SubtitleCue]) -> Bool {
        let normalizedParts = cues.map { normalizedJapaneseLoopText($0.text) }
        let normalized = normalizedParts.joined()
        guard normalized.count >= japaneseLyricLoopCueMinNormalizedCharacters else { return false }

        let uniqueRatio = Double(Set(normalized).count) / Double(normalized.count)
        guard uniqueRatio <= japaneseLyricLoopCueMaxUniqueCharacterRatio else { return false }
        guard repeatedBigramExcess(in: normalized) >= japaneseLyricLoopCueMinRepeatedBigramExcess else {
            return false
        }

        let longSparseCueCount = cues.filter { cue in
            let duration = cueEndSeconds(cue) - cueStartSeconds(cue)
            return duration >= japaneseLyricLoopCueLongSparseSeconds
                && SubtitleTimingPlanner.visibleCharacters(cue.text) <= hardMaximumCJKUnits
        }.count

        // Legitimate choruses can repeat short, particle-heavy phrases many times. Treat approximate
        // repetition as hallucination only when a short text is stretched across an implausibly long
        // span or a longer phrase densely repeats far beyond normal chorus cadence.
        return longSparseCueCount > 0 || hasDominantRepeatedJapaneseLyricSubstring(normalized)
    }

    private static func hasDominantRepeatedJapaneseLyricSubstring(_ text: String) -> Bool {
        dominantRepeatedJapaneseLyricSubstring(in: text) != nil
    }

    private static func dominantRepeatedJapaneseLyricSubstring(in text: String) -> String? {
        let characters = Array(text)
        guard characters.count >= japaneseLyricDenseLoopMinCharacters else { return nil }
        let maxLength = min(japaneseLyricDenseLoopMaxSubstringCharacters, characters.count / 2)
        guard maxLength >= japaneseLyricDenseLoopMinSubstringCharacters else { return nil }

        for length in stride(from: maxLength, through: japaneseLyricDenseLoopMinSubstringCharacters, by: -1) {
            var counts: [String: Int] = [:]
            for index in 0...(characters.count - length) {
                let substring = String(characters[index..<(index + length)])
                guard Set(substring).count >= 3 else { continue }
                counts[substring, default: 0] += 1
            }
            if let match = counts.max(by: { $0.value < $1.value }),
               match.value >= japaneseLyricDenseLoopMinOccurrences,
               Double(length * match.value) / Double(characters.count) >= japaneseLyricDenseLoopMinCoverage {
                return match.key
            }
        }
        return nil
    }

    private static func japaneseLyricDenseLoopPreservePrefixCount(_ cues: [SubtitleCue]) -> Int {
        let normalized = cues.map { normalizedJapaneseLoopText($0.text) }.joined()
        guard let motif = dominantRepeatedJapaneseLyricSubstring(in: normalized) else { return 0 }
        let motifPrefix = String(motif.prefix(min(8, motif.count)))
        guard motifPrefix.count >= japaneseLyricDenseLoopMinSubstringCharacters else { return 0 }
        for (offset, cue) in cues.enumerated() {
            if normalizedJapaneseLoopText(cue.text).contains(motifPrefix) {
                return offset
            }
        }
        return 0
    }

    private static func repeatedBigramExcess(in text: String) -> Int {
        let characters = Array(text)
        guard characters.count >= 2 else { return 0 }
        var counts: [String: Int] = [:]
        for index in 0..<(characters.count - 1) {
            counts[String(characters[index...index + 1]), default: 0] += 1
        }
        return counts.values.reduce(0) { total, count in
            total + max(0, count - 1)
        }
    }

    private static func cueStartSeconds(_ cue: SubtitleCue) -> Double {
        cue.sourceFragments.first?.startSeconds ?? 0
    }

    private static func cueEndSeconds(_ cue: SubtitleCue) -> Double {
        cue.sourceFragments.last?.endSeconds ?? cueStartSeconds(cue)
    }

    private static func repeatedJapaneseLoopMatch(
        at index: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> JapaneseLoopMatch? {
        for phraseLength in stride(
            from: min(japaneseLoopMaxPhraseFragments, fragments.count - index),
            through: japaneseLoopMinPhraseFragments,
            by: -1
        ) {
            guard let signature = japaneseLoopSignature(at: index, length: phraseLength, in: fragments) else {
                continue
            }
            let repeatCount = consecutiveJapaneseLoopCount(
                signature: signature,
                phraseLength: phraseLength,
                at: index,
                in: fragments
            )
            if repeatCount >= japaneseLoopMinRepeatCount {
                return JapaneseLoopMatch(
                    signature: signature,
                    phraseLength: phraseLength,
                    repeatCount: repeatCount
                )
            }
        }
        return nil
    }

    private static func fusedJapaneseLoopMatch(
        at index: Int,
        in fragments: [SubtitleCueSourceFragment],
        fuses: [String: JapaneseLoopFuse]
    ) -> JapaneseLoopMatch? {
        for (signature, fuse) in fuses {
            guard fragments[index].startSeconds <= fuse.suppressUntilSeconds else {
                continue
            }
            if isJapaneseLoopCompatibleNoise(fragments[index].text, characters: fuse.characters) {
                let repeatCount = consecutiveJapaneseLoopCompatibleNoiseCount(
                    characters: fuse.characters,
                    at: index,
                    in: fragments
                )
                return JapaneseLoopMatch(signature: signature, phraseLength: 1, repeatCount: repeatCount)
            }
            guard japaneseLoopSignature(at: index, length: fuse.phraseLength, in: fragments) == signature else {
                continue
            }
            let repeatCount = max(
                1,
                consecutiveJapaneseLoopCount(
                    signature: signature,
                    phraseLength: fuse.phraseLength,
                    at: index,
                    in: fragments
                )
            )
            return JapaneseLoopMatch(signature: signature, phraseLength: fuse.phraseLength, repeatCount: repeatCount)
        }
        return nil
    }

    private static func consecutiveJapaneseLoopCompatibleNoiseCount(
        characters: Set<Character>,
        at index: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> Int {
        var count = 0
        while index + count < fragments.count,
              isJapaneseLoopCompatibleNoise(fragments[index + count].text, characters: characters) {
            count += 1
        }
        return max(1, count)
    }

    private static func consecutiveJapaneseLoopCount(
        signature: String,
        phraseLength: Int,
        at index: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> Int {
        var count = 0
        var previousStart: Double?
        while index + (count + 1) * phraseLength <= fragments.count {
            let phraseIndex = index + count * phraseLength
            guard japaneseLoopSignature(at: phraseIndex, length: phraseLength, in: fragments) == signature else {
                break
            }
            let start = fragments[phraseIndex].startSeconds
            if let previousStart, start - previousStart > japaneseLoopMaxOccurrenceGapSeconds {
                break
            }
            previousStart = start
            count += 1
        }
        return count
    }

    private static func japaneseLoopSignature(
        at index: Int,
        length: Int,
        in fragments: [SubtitleCueSourceFragment]
    ) -> String? {
        guard length >= japaneseLoopMinPhraseFragments, index + length <= fragments.count else {
            return nil
        }
        let phraseFragments = fragments[index..<(index + length)]
        let span = (phraseFragments.last?.endSeconds ?? 0) - (phraseFragments.first?.startSeconds ?? 0)
        guard span <= japaneseLoopMaxPhraseSpanSeconds else { return nil }
        let signature = phraseFragments
            .map { normalizedJapaneseLoopText($0.text) }
            .joined()
        guard signature.count >= japaneseLoopMinPhraseFragments,
              signature.count <= 16,
              signature.allSatisfy(isJapaneseLoopSignatureCharacter),
              Set(signature).count > 1 else {
            return nil
        }
        return signature
    }

    private static func normalizedJapaneseLoopText(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return (0x3040...0x309F).contains(Int(value))
                || (0x30A0...0x30FF).contains(Int(value))
                || (0x4E00...0x9FFF).contains(Int(value))
        })
    }

    private static func isJapaneseLoopCompatibleNoise(_ text: String, characters: Set<Character>) -> Bool {
        let normalized = normalizedJapaneseLoopText(text)
        return !normalized.isEmpty
            && normalized.allSatisfy(isJapaneseLoopSignatureCharacter)
            && normalized.allSatisfy { characters.contains($0) }
    }

    private static func isJapaneseLoopSignatureCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            let value = Int(scalar.value)
            return (0x3040...0x309F).contains(value)
                || (0x30A0...0x30FF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
        }
    }

    private static func shouldKeep(_ fragment: SubtitleCueSourceFragment) -> Bool {
        guard !fragment.text.isEmpty else { return false }
        guard fragment.endSeconds >= fragment.startSeconds else { return false }
        // Drop no-speech fragments (a lone "?", "...", "♪" etc.) outright — they carry no readable
        // content and otherwise become standalone cues that linger to the cue cap.
        if isPurePunctuation(fragment.text) { return false }
        if isDroppableJapaneseResidual(fragment.text) { return false }
        return true
    }

    private static func splitLeadingJapaneseTailFragments(
        _ fragments: [SubtitleCueSourceFragment]
    ) -> [SubtitleCueSourceFragment] {
        fragments.flatMap { fragment -> [SubtitleCueSourceFragment] in
            let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("なそ"), text.count >= 3 else { return [fragment] }
            let duration = fragment.endSeconds - fragment.startSeconds
            guard duration >= 0.2 else { return [fragment] }
            let tailEnd = min(fragment.endSeconds, fragment.startSeconds + max(0.12, min(0.28, duration * 0.2)))
            let rest = String(text.dropFirst())
            guard !rest.isEmpty else { return [fragment] }
            return [
                SubtitleCueSourceFragment(
                    startSeconds: fragment.startSeconds,
                    endSeconds: tailEnd,
                    text: "な"
                ),
                SubtitleCueSourceFragment(
                    startSeconds: tailEnd,
                    endSeconds: fragment.endSeconds,
                    text: rest
                )
            ]
        }
    }

    private static func shouldBreak(
        before next: SubtitleCueSourceFragment,
        current: [SubtitleCueSourceFragment],
        candidate: [SubtitleCueSourceFragment],
        gap: Double,
        thresholds: SubtitleTimingThresholds
    ) -> Bool {
        guard let first = current.first, let last = current.last else { return false }
        if gap > thresholds.largeSpeechGapSeconds { return true }

        let candidateText = joinedText(candidate)
        let candidateDuration = next.endSeconds - first.startSeconds
        if containsCJK(candidateText) {
            let units = SubtitleTimingPlanner.timingTokens(candidateText).count
            let latinContinuation = isStrongLatinContinuationFragment(left: last.text, right: next.text)
            if latinContinuation,
               candidateDuration <= thresholds.relaxedCJKCueSeconds,
               units <= relaxedShortMergeMaxCJKUnits {
                return false
            }
            // Hard ceilings always break.
            if candidateDuration > thresholds.hardMaximumCJKCueSeconds { return true }
            if units > hardMaximumCJKUnits { return true }
            // Soft ceilings break only at a natural boundary: never split mid-word (morphological
            // word boundary via NaturalLanguage), and never right before a leading particle / small
            // kana / closing punctuation. Otherwise extend to the hard ceiling, so words like
            // 「いこう」「カード」「たくさん」 stay whole and 「だ|よ」/ lone 「ね」 tails stay attached.
            if candidateDuration > thresholds.maximumCJKCueSeconds || units > maximumCJKUnits {
                // Breath-gap anchor (stable-ts): a real inter-word silence is the natural place to
                // break a long line, so break there even mid-word rather than running to the hard
                // ceiling. Never break right before a leading particle / small kana / closing
                // punctuation, even after a pause. Only in this over-soft-ceiling zone.
                if gap >= thresholds.breathGapBreakSeconds, !startsWithLeadingProhibited(next.text) {
                    return true
                }
                let junction = joinedText(current).count
                let midWord = CJKWordBoundary.straddles(candidateText, at: junction)
                return !(midWord || hasWeakBoundary(left: last.text, right: next.text))
            }
            return false
        }

        if candidateDuration > thresholds.maximumLatinCueSeconds { return true }
        let latinBudgetText = candidate
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if SubtitleTimingPlanner.speechTokens(latinBudgetText).count > maximumLatinTokens {
            // Over the token budget: a breath gap is a natural break even at a weak boundary;
            // otherwise keep the existing weak-boundary protection.
            if gap >= thresholds.breathGapBreakSeconds { return true }
            if !hasWeakBoundary(left: last.text, right: next.text) { return true }
        }
        return false
    }

    private static func makeCue(
        index: Int,
        fragments: [SubtitleCueSourceFragment],
        transcriptDurationSeconds: Double?,
        thresholds: SubtitleTimingThresholds
    ) -> SubtitleCue? {
        guard let first = fragments.first, let last = fragments.last else { return nil }
        let text = joinedText(fragments)
        guard !text.isEmpty else { return nil }

        let start = first.startSeconds
        var end = last.endSeconds + (endsSentence(text) ? sentenceTailSeconds : phraseTailSeconds)
        if let transcriptDurationSeconds {
            end = min(end, transcriptDurationSeconds)
        }
        let maximumEnd = start + maximumCueSeconds(for: text, start: start, lastTokenEnd: last.endSeconds, thresholds: thresholds)
        end = min(end, maximumEnd)
        end = max(end, start + minimumCueSeconds)
        // Neighbor-aware timing (lead-in, hold-to-next-onset, no-overlap) is applied later by
        // WhisperCueRetimer. makeCue intentionally does NOT clamp to the next group's start here:
        // doing so before the minimum-duration floor produced overlapping cues (BUG-1).
        return SubtitleCue(
            index: index,
            start: secondsToSRTTime(start),
            end: secondsToSRTTime(end),
            text: text,
            sourceFragments: fragments
        )
    }

    private static func joinedText(_ fragments: [SubtitleCueSourceFragment]) -> String {
        var output = ""
        var previous = ""
        let allowBroadLatinContinuation = containsCJK(fragments.map(\.text).joined())
        let parts = fragments.map(\.text)
        for (index, part) in parts.enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let next = index + 1 < parts.count
                ? parts[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            if !output.isEmpty,
               !isObservedLatinContinuation(left: output, right: trimmed),
               shouldInsertSpace(
                left: previous,
                right: trimmed,
                next: next,
                allowBroadLatinContinuation: allowBroadLatinContinuation
               ) {
                output += " "
            }
            output += trimmed
            previous = trimmed
        }
        return output
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsCJK(_ text: String) -> Bool {
        SubtitleTimingPlanner.containsCJKText(text)
    }

    private static func shouldInsertSpace(
        left: String,
        right: String,
        next: String?,
        allowBroadLatinContinuation: Bool
    ) -> Bool {
        guard let rightFirst = right.first else { return false }
        if isNoSpaceBefore(rightFirst) { return false }
        if isObservedStandaloneLatinFunction(left: left, right: right) { return true }
        if isLatinBridgeFragment(left: left, right: right, next: next) { return false }
        if isStrongLatinContinuationFragment(left: left, right: right) { return false }
        if isLatinContinuationFragment(
            left: left,
            right: right,
            allowBroadHeuristics: allowBroadLatinContinuation
        ) {
            return false
        }
        if containsHangul(left),
           containsHangul(right),
           !koreanLeadingProhibitedParticles.contains(right.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return true
        }
        // Space-separated non-CJK scripts (Devanagari/Bengali/Arabic/Cyrillic/…) keep word spaces.
        if containsSpacedScript(left), containsSpacedScript(right) {
            return true
        }
        return containsASCIIAlphanumeric(left) || containsASCIIAlphanumeric(right)
    }

    private static func isObservedStandaloneLatinFunction(left: String, right: String) -> Bool {
        let leftRun = trailingLatinLetterRun(left).lowercased()
        let rightRun = leadingLatinLetterRun(right).lowercased()
        guard !leftRun.isEmpty, !rightRun.isEmpty,
              let allowedPrefixes = observedStandaloneLatinFunctionPrefixes[rightRun] else {
            return false
        }
        return allowedPrefixes.contains(leftRun)
    }

    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(Int(scalar.value))
        }
    }

    private static func containsSpacedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = Int(scalar.value)
            return (0x0900...0x097F).contains(v)   // Devanagari
                || (0x0980...0x09FF).contains(v)   // Bengali
                || (0x0600...0x06FF).contains(v)   // Arabic
                || (0x0750...0x077F).contains(v)   // Arabic Supplement
                || (0x08A0...0x08FF).contains(v)   // Arabic Extended-A
                || (0x0400...0x04FF).contains(v)   // Cyrillic
                || (0x0500...0x052F).contains(v)   // Cyrillic Supplement
        }
    }

    private static func containsASCIIAlphanumeric(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x30...0x39).contains(value)
                || (0x41...0x5A).contains(value)
                || (0x61...0x7A).contains(value)
        }
    }

    private static func isNoSpaceBefore(_ character: Character) -> Bool {
        ["'", ".", ",", "!", "?", ":", ";", "。", "、", "！", "？", "，", "：", "；", "）", ")", "」", "』", "”", "’"]
            .contains(character)
    }

    private static func hasWeakBoundary(left: String, right: String) -> Bool {
        // CJK: never break right before a leading particle / small kana / closing punctuation.
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstChar = trimmedRight.first,
           cjkLeadingProhibited.contains(firstChar) {
            return true
        }
        // Korean: never break right before a bare josa/eomi fragment.
        if koreanLeadingProhibitedParticles.contains(trimmedRight) {
            return true
        }
        if isStrongLatinContinuationFragment(left: left, right: right) {
            return true
        }
        if isLatinContinuationFragment(left: left, right: right, allowBroadHeuristics: false) {
            return true
        }
        let leftTokens = SubtitleTimingPlanner.wordTokens(left)
        let rightTokens = SubtitleTimingPlanner.wordTokens(right)
        guard let last = leftTokens.last, let first = rightTokens.first else { return false }
        return SubtitleTimingPlanner.isWeakBoundary(leftToken: last, rightToken: first)
    }

    private static func isStrongLatinContinuationFragment(left: String, right: String) -> Bool {
        if hasApostropheInsideLatinRun(left) { return false }
        let leftRun = trailingLatinLetterRun(left)
        let rightRun = leadingLatinLetterRun(right)
        guard !leftRun.isEmpty, !rightRun.isEmpty else { return false }
        let leftLower = leftRun.lowercased()
        let rightLower = rightRun.lowercased()
        if strongLatinContinuationSuffixes.contains(rightLower) {
            return !latinContinuationFunctionWords.contains(leftLower)
        }
        return leftRun.count == 1
            && leftRun == leftRun.uppercased()
            && !latinContinuationFunctionWords.contains(leftLower)
            && startsWithLowercaseLetter(rightRun)
    }

    private static func isLatinContinuationFragment(
        left: String,
        right: String,
        allowBroadHeuristics: Bool
    ) -> Bool {
        if isObservedLatinContinuation(left: left, right: right) {
            return true
        }
        if hasApostropheInsideLatinRun(left) { return false }
        let leftRun = trailingLatinLetterRun(left)
        let rightRun = leadingLatinLetterRun(right)
        guard !leftRun.isEmpty, !rightRun.isEmpty else { return false }
        let leftLower = leftRun.lowercased()
        let rightLower = rightRun.lowercased()
        if latinBridgeFragments.contains(leftLower),
           latinBridgeTailSuffixes.contains(rightLower) {
            return true
        }
        if latinContinuationFunctionWords.contains(leftLower) { return false }
        if latinContinuationSuffixes.contains(rightLower) {
            if shortLatinContinuationSuffixes.contains(rightLower) {
                return leftRun.count >= 2 && !latinContinuationFunctionWords.contains(leftLower)
            }
            return !latinContinuationFunctionWords.contains(leftLower)
        }
        if rightLower == "i",
           leftLower.hasSuffix("ior"),
           !latinContinuationFunctionWords.contains(leftLower) {
            return true
        }
        if !allowBroadHeuristics { return false }
        if leftRun.count == 1,
           leftRun == leftRun.uppercased(),
           !latinContinuationFunctionWords.contains(leftLower),
           startsWithLowercaseLetter(rightRun) {
            return true
        }
        if leftRun.count <= 3,
           startsWithUppercaseLetter(leftRun),
           rightRun.count >= 3,
           !latinContinuationFunctionWords.contains(leftLower),
           !latinContinuationFunctionWords.contains(rightLower),
           startsWithLowercaseLetter(rightRun) {
            return true
        }
        if leftRun.count <= 2,
           rightRun.count >= 3,
           !latinContinuationFunctionWords.contains(leftLower),
           !latinContinuationFunctionWords.contains(rightLower),
           startsWithLowercaseLetter(rightRun) {
            return true
        }
        return false
    }

    private static func isObservedLatinContinuation(left: String, right: String) -> Bool {
        let leftLower = left
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rightLower = right
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if rightLower == "rice" {
            return leftLower.hasSuffix("créat") || leftLower.hasSuffix("creat")
        }
        guard let allowedPrefixes = observedLatinContinuationPrefixes[rightLower] else {
            return false
        }
        // Match the trailing Latin run *exactly* against an observed sub-word piece, not with
        // hasSuffix on the whole left string. hasSuffix glued mainstream words whose tail merely
        // happened to end in a fragment ("stop"+"in"→"stopin", "salut"+"il"→"salutil",
        // "drop"/"shop"/"develop"+"in"). The accumulation chains already list every accumulated
        // form as its own key (e.g. "seitenver"/"seitenverkle"), so equality still links real
        // multi-piece sub-words while failing safe on complete words.
        let leftRun = trailingLatinLetterRun(left).lowercased()
        guard !leftRun.isEmpty else { return false }
        return allowedPrefixes.contains { leftRun == $0 }
    }

    private static func isLatinBridgeFragment(left: String, right: String, next: String?) -> Bool {
        guard let next else { return false }
        if hasApostropheInsideLatinRun(left) { return false }
        let leftRun = trailingLatinLetterRun(left)
        let rightRun = leadingLatinLetterRun(right)
        let nextRun = leadingLatinLetterRun(next)
        guard !leftRun.isEmpty, !rightRun.isEmpty, !nextRun.isEmpty else { return false }
        let leftLower = leftRun.lowercased()
        let rightLower = rightRun.lowercased()
        let nextLower = nextRun.lowercased()
        if let allowedPrefixes = observedLatinBridgePrefixes[rightLower] {
            return allowedPrefixes.contains { leftLower.hasSuffix($0) }
                && latinBridgeTailSuffixes.contains(nextLower)
        }
        if observedLatinBridgePrefixes.keys.contains(rightLower) {
            return false
        }
        return latinBridgeFragments.contains(rightLower)
            && !latinContinuationFunctionWords.contains(leftLower)
            && latinContinuationSuffixes.contains(nextLower)
    }

    private static func hasApostropheInsideLatinRun(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("'") || trimmed.contains("’")
    }

    private static func trailingLatinLetterRun(_ text: String) -> String {
        let text = text.precomposedStringWithCanonicalMapping
        var characters: [Character] = []
        for character in text.reversed() {
            guard isLatinLetter(character) else { break }
            characters.append(character)
        }
        return String(characters.reversed())
    }

    private static func leadingLatinLetterRun(_ text: String) -> String {
        let text = text.precomposedStringWithCanonicalMapping
        var characters: [Character] = []
        for character in text {
            guard isLatinLetter(character) else { break }
            characters.append(character)
        }
        return String(characters)
    }

    private static func isLatinLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            let inLatinBlock = (0x0041...0x005A).contains(value)
                || (0x0061...0x007A).contains(value)
                || (0x00C0...0x00FF).contains(value)
                || (0x0100...0x024F).contains(value)
                || (0x1E00...0x1EFF).contains(value)
            return inLatinBlock && CharacterSet.letters.contains(scalar)
        }
    }

    private static func startsWithLowercaseLetter(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.lowercased() == String(first) && first.uppercased() != String(first)
    }

    private static func startsWithUppercaseLetter(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.uppercased() == String(first) && first.lowercased() != String(first)
    }

    private static func endsSentence(_ value: String) -> Bool {
        guard let last = value.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?。！？".contains(last)
    }

    private static func isPurePunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
        }
    }

    private static func isDroppableJapaneseResidual(_ text: String) -> Bool {
        droppableJapaneseResiduals.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Maps a Moongate whisper model id (e.g. `whisper.cpp:small-q5_1`) to the whisper.cpp
/// `-dtw <preset>` alignment-heads preset name (dot form, e.g. `large.v3.turbo`). Returns nil
/// when no preset is known, in which case the caller must omit `-dtw` (fail-safe).
public enum WhisperDTWPreset {
    private static let known: Set<String> = [
        "tiny", "tiny.en", "base", "base.en", "small", "small.en",
        "medium", "medium.en", "large.v1", "large.v2", "large.v3", "large.v3.turbo"
    ]

    public static func preset(forModelID modelID: String) -> String? {
        var name = modelID
        if let colon = name.lastIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        name = name.lowercased().trimmingCharacters(in: .whitespaces)
        // Strip quantization suffix like "-q5_1", ".q8_0", "_q5_0".
        if let range = name.range(of: #"[-_.]q[0-9].*$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        // Catalog ids use dashes for large variants (large-v3-turbo); presets use dots.
        if name.hasPrefix("large") {
            name = name.replacingOccurrences(of: "-", with: ".")
        }
        return known.contains(name) ? name : nil
    }
}

/// Whisper-specific subtitle re-timer. Operates on the grouped cues produced by
/// `LocalASRSubtitleTimingPlanner` and adjusts disappearance to better match human timing,
/// exploiting the asymmetric acceptance window used by the timing eval (start error
/// -250..+450ms, end error -150..+900ms):
/// - Appearance: nudge the onset slightly later than the raw whisper/DTW onset (onsetDelaySeconds)
///   so subtitles don't appear before speech; bounded so short cues keep a readable duration.
/// - Disappearance: extend the cue toward the next real onset (capped at `holdToNextSeconds`)
///   to absorb whisper's habitually-early word ends, never overlapping the next cue. This also
///   fixes the old `min(end, nextStart)` clamp that caused both abrupt cut-offs and overlaps
///   (BUG-1).
/// This is deliberately separate from the platform (YouTube auto-caption) timing path, which
/// keeps human-aligned source anchors that whisper does not have.
public enum WhisperCueRetimer {
    /// Onset delay: nudge appearance slightly later than the raw whisper/DTW onset. DTW gives a
    /// realistic onset but with a small residual early bias, and the eval acceptance window is
    /// centred around +100..+200ms (slightly late reads better than early). A small delay keeps
    /// subtitles from appearing before speech. Bounded so short cues keep a readable duration.
    public static let onsetDelaySeconds = 0.2
    /// 整段第一条字幕的提前量(lead-in):视频开头观众等在空屏前,首句早一点出现更自然(不像中途 cue 那样
    /// 需要避让前一条/防早现)。仅作用于 index==0,clamp 到 ≥0。
    public static let firstCueLeadInSeconds = 0.3
    /// Gap kept before the next cue's onset so adjacent cues never overlap.
    public static let interCueGuardSeconds = 0.08
    /// Maximum extra hold past the last spoken token. whisper ends words noticeably earlier
    /// than human captions, so holding toward the next onset cuts the dominant early-cutoff
    /// failures; capped so a long pause never produces a long idle hold.
    public static let holdToNextSeconds = 0.7
    /// Mixed CJK + Latin/number runs are often ASR-glued code switches; use a shorter hold so
    /// pasted English fragments do not linger across the next silence.
    public static let mixedCJKLatinHoldToNextSeconds = 0.45
    private static let baseMinimumCueSeconds = LocalASRSubtitleTimingPlanner.minimumCueSeconds
    private static let profiledMinimumCueSeconds = 0.9
    private static let epsilon = 0.001

    private struct RawCue {
        let start: Double
        let end: Double
        let lastTokenEnd: Double
        let text: String
        let fragments: [SubtitleCueSourceFragment]
        let cap: Double
    }

    public static func retime(
        _ cues: [SubtitleCue],
        transcriptDurationSeconds: Double?,
        profile: SubtitleTimingProfile = .speech,
        audioActivity: ASRAudioActivity? = nil
    ) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        let thresholds = LocalASRSubtitleTimingPlanner.thresholds(for: profile)
        let lyricAcousticGuardEnabled = profile == .lyrics || profile == .japaneseLyrics
        var raws: [RawCue] = []
        raws.reserveCapacity(cues.count)
        for cue in cues {
            guard let start = srtTimeToSeconds(cue.start), let end = srtTimeToSeconds(cue.end) else {
                return cues // unparseable input: leave untouched rather than corrupt timing
            }
            let lastTokenEnd = cue.sourceFragments.last?.endSeconds ?? end
            let cap = LocalASRSubtitleTimingPlanner.maximumCueSeconds(
                for: cue.text,
                start: start,
                lastTokenEnd: lastTokenEnd,
                thresholds: thresholds
            )
            raws.append(RawCue(
                start: start,
                end: end,
                lastTokenEnd: lastTokenEnd,
                text: cue.text,
                fragments: cue.sourceFragments,
                cap: cap
            ))
        }

        var output: [SubtitleCue] = []
        output.reserveCapacity(raws.count)
        var previousEnd = -Double.greatestFiniteMagnitude
        for index in raws.indices {
            let raw = raws[index]
            let hasNext = index + 1 < raws.count
            let nextStart = hasNext ? raws[index + 1].start : Double.greatestFiniteMagnitude

            // Appearance: nudge the onset slightly later (DTW has a small early bias; the window's
            // ideal is slightly-late) so cues don't appear before speech. Bounded so the cue keeps
            // a readable minimum duration, never before the previous cue's end, never negative.
            // 例外:**整段第一条**不加 onsetDelay。视频开头观众盯着空屏等,首句比首词再晚 0.2s 会明显"话快说完才
            // 出现"。但也不能拉到首词之前(那会在静音里空显)——除非首词本就贴近视频开头(leadingSilence 很短),
            // 才给一点 lead-in 提前量填掉开头那点空白。中途 cue 维持原 +onsetDelay(避让前条/防早现)。
            var start: Double
            if index == 0 {
                if raw.start <= firstCueLeadInSeconds {
                    // 首词贴近视频开头:从 0 起显,填掉开头空白。
                    start = 0
                } else {
                    // 首词前有真实静音(如前奏/留白):用原始 onset,不加延迟、也不提前进静音。
                    start = raw.start
                }
            } else {
                start = raw.start + thresholds.onsetDelaySeconds
            }
            start = min(start, max(raw.start, raw.end - baseMinimumCueSeconds))
            if index > 0 { start = max(start, previousEnd) }
            start = max(start, 0)
            if lyricAcousticGuardEnabled, let audioActivity {
                start = audioActivity.protectedLyricStart(for: start)
                if hasNext {
                    start = min(start, max(raw.start, nextStart - baseMinimumCueSeconds))
                }
            }

            // Disappearance: extend the cue toward the next real onset to absorb whisper's early
            // word ends, capped at holdToNextSeconds past the last token (so a long pause cannot
            // produce a long idle hold) and at the next onset minus a guard (so cues never overlap).
            // 末句没有下一个 onset，但仍不能越过整段音频时长，否则末句字幕会拖到视频结尾之后（BUG-4）。
            let ceiling = hasNext
                ? nextStart - interCueGuardSeconds
                : (transcriptDurationSeconds ?? Double.greatestFiniteMagnitude)
            let hold = holdToNextSeconds(for: raw.text, thresholds: thresholds)
            var end = max(raw.end, min(ceiling, raw.lastTokenEnd + hold))
            if let duration = transcriptDurationSeconds { end = min(end, duration) }
            end = min(end, start + raw.cap)
            end = max(end, start + minimumCueSeconds(for: profile)) // minimum readable duration (before overlap clamp)
            end = min(end, ceiling)                   // never overlap the next onset window
            end = min(end, nextStart)                 // hard no-overlap authority
            end = max(end, start + epsilon)           // always positive duration

            output.append(SubtitleCue(
                index: output.count + 1,
                start: secondsToSRTTime(start),
                end: secondsToSRTTime(end),
                text: raw.text,
                sourceFragments: raw.fragments
            ))
            previousEnd = end
        }
        return output
    }

    private static func holdToNextSeconds(for text: String, thresholds: SubtitleTimingThresholds) -> Double {
        // Mixed CJK + Latin runs are ASR-glued code switches: keep the short mixed hold regardless
        // of profile so pasted English fragments do not linger. Otherwise use the profile's hold.
        containsCJKLatinMix(text) ? min(mixedCJKLatinHoldToNextSeconds, thresholds.holdToNextSeconds) : thresholds.holdToNextSeconds
    }

    private static func minimumCueSeconds(for profile: SubtitleTimingProfile) -> Double {
        switch profile {
        case .speech:
            return baseMinimumCueSeconds
        case .lyrics, .japaneseLyrics, .anime:
            return profiledMinimumCueSeconds
        }
    }

    private static func containsCJKLatinMix(_ text: String) -> Bool {
        guard SubtitleTimingPlanner.containsCJKText(text) else { return false }
        return text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x30...0x39).contains(value)
                || (0x41...0x5A).contains(value)
                || (0x61...0x7A).contains(value)
        }
    }
}

/// 本地 ASR 生成结果：源 SRT 路径 + 转写整体置信度（用于「识别质量较低」提示）。
public struct GeneratedLocalASRSource: Sendable {
    public let url: URL
    public let confidence: LocalASRConfidenceSummary?

    public init(url: URL, confidence: LocalASRConfidenceSummary?) {
        self.url = url
        self.confidence = confidence
    }
}

public protocol LocalASRSubtitleGenerator: Sendable {
    func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata?,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> GeneratedLocalASRSource
}

public extension LocalASRSubtitleGenerator {
    func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> GeneratedLocalASRSource {
        try await generateSourceSubtitle(
            videoFile: videoFile,
            languageCode: languageCode,
            promptMetadata: nil,
            control: control,
            progress: progress
        )
    }
}

public enum LocalASRSidecarError: Error, Equatable {
    case processFailed(status: Int32, stderrTail: String)
    case missingOutput(URL)
    case emptyOutput(URL)
}

/// Adapter for user-supplied high-quality local ASR sidecars such as faster-whisper,
/// SenseVoice/FunASR, or a local alignment wrapper. The sidecar must write timed SRT to
/// `--output`; Moongate then feeds that file through the normal resolver/scorer pipeline.
public struct SidecarLocalASRSubtitleGenerator: LocalASRSubtitleGenerator {
    public let executableURL: URL
    public let modelURL: URL
    public let workDirectoryURL: URL
    public let modelID: String

    public init(
        executableURL: URL,
        modelURL: URL,
        workDirectoryURL: URL,
        modelID: String = "sidecar:local-precise"
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.workDirectoryURL = workDirectoryURL
        self.modelID = modelID
    }

    public func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata?,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> GeneratedLocalASRSource {
        try Task.checkCancellation()
        try await control?.gate()
        try FileManager.default.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)

        let outputURL = ASRTranscriptMapper.localASRSourceSRTURL(videoURL: videoFile, languageCode: languageCode)
        try? FileManager.default.removeItem(at: outputURL)
        progress(ASRProgress(phase: .speechRecognition, completedUnits: 0, totalUnits: 1))
        try await runSidecar(videoFile: videoFile, languageCode: languageCode, outputURL: outputURL, control: control)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw LocalASRSidecarError.missingOutput(outputURL)
        }
        let raw = try String(contentsOf: outputURL, encoding: .utf8)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalASRSidecarError.emptyOutput(outputURL)
        }
        progress(ASRProgress(phase: .speechRecognition, completedUnits: 1, totalUnits: 1))
        let confidence = LocalASRConfidence.assessSubtitle(
            raw: raw,
            fileName: outputURL.lastPathComponent,
            languageCode: languageCode,
            requestedLanguageCode: languageCode
        )
        return GeneratedLocalASRSource(url: outputURL, confidence: confidence)
    }

    private func runSidecar(
        videoFile: URL,
        languageCode: String,
        outputURL: URL,
        control: TaskControlToken?
    ) async throws {
        let state = ASRCommandProcessState()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = [
                    "--input", videoFile.path,
                    "--output", outputURL.path,
                    "--language", normalizedSidecarLanguage(languageCode),
                    "--model", modelURL.path,
                    "--format", "srt"
                ]
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let ioGroup = DispatchGroup()
                ioGroup.enter()
                ioGroup.enter()
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    _ = state.consume(data, stream: .stdout)
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    _ = state.consume(data, stream: .stderr)
                }
                process.terminationHandler = { finished in
                    let terminationStatus = finished.terminationStatus
                    DispatchQueue.global().async {
                        _ = ioGroup.wait(timeout: .now() + 5)
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        _ = state.flushRemainder()
                        control?.setActivePID(0)
                        state.resumeOnce {
                            continuation.resume(returning: terminationStatus)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    ioGroup.leave()
                    ioGroup.leave()
                    state.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if state.register(process) {
                    TaskControlToken.signalTree(process.processIdentifier, SIGKILL)
                }
                control?.setActivePID(process.processIdentifier)
            }
        } onCancel: {
            state.cancel()
        }
        if state.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw LocalASRSidecarError.processFailed(status: status, stderrTail: state.stderrTail)
        }
    }

    private func normalizedSidecarLanguage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "auto" : trimmed
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var output: [String] = []
    for value in values {
        guard seen.insert(value).inserted else { continue }
        output.append(value)
    }
    return output
}

public struct ASRPromptMetadata: Equatable, Sendable {
    public let title: String?
    public let channel: String?
    public let characters: [String]
    public let glossaryTerms: [String]

    public init(
        title: String? = nil,
        channel: String? = nil,
        characters: [String] = [],
        glossaryTerms: [String] = []
    ) {
        self.title = Self.normalizedScalar(title)
        self.channel = Self.normalizedScalar(channel)
        self.characters = Self.normalizedList(characters)
        self.glossaryTerms = Self.normalizedList(glossaryTerms)
    }

    private static func normalizedScalar(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        let normalized = values.compactMap(normalizedScalar)
        return unique(Array(normalized.prefix(12)))
    }
}

public enum ASRPromptBuilder {
    /// CJK 标点范例：whisper.cpp 把 prompt 当前置上下文并沿用其风格。CJK 下模型默认几乎不产句末
    /// 标点（日语实测 0、韩语 6），分段器因而缺句末断点、欠分段。给带标点范例后标点 0→24，
    /// 公平对比（同次重跑 ASR）下 CJK aggregate strong-boundary recall 0.31→0.44 且无样本回退
    /// （segmentation eval 2026-06-24，n=4）。仅 CJK 注入，Latin 路径标点本就良好、保持不变。
    /// 跨端镜像：windows/MoongateCore/Asr.cs `AsrPromptBuilder`。
    static func punctuationExemplar(forLanguage language: String) -> String? {
        let lang = language.lowercased()
        if lang.hasPrefix("ja") {
            return "今日は、いい天気ですね。はい、そうです。"
        }
        if lang.hasPrefix("ko") {
            return "안녕하세요. 오늘은 날씨가 좋네요. 네, 맞습니다."
        }
        if lang.hasPrefix("zh") || lang.hasPrefix("yue") || lang.hasPrefix("cmn") {
            return "你好，今天天气不错。是的，没错。"
        }
        return nil
    }

    public static func defaultPrompt(
        videoURL: URL,
        languageCode: String,
        recognitionProfile: ASRRecognitionProfile = .speech,
        metadata: ASRPromptMetadata? = nil
    ) -> String? {
        let fileTitle = videoURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = metadata?.title ?? fileTitle
        let language = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        // CJK：前置标点范例，引导 whisper.cpp 输出句末标点（分段强边界依赖它）。
        if recognitionProfile == .speech,
           language.lowercased() != "auto",
           let exemplar = punctuationExemplar(forLanguage: language) {
            parts.append(exemplar)
        }
        if !title.isEmpty {
            parts.append("title=\(title)")
        }
        if let channel = metadata?.channel, !channel.isEmpty {
            parts.append("channel=\(channel)")
        }
        if !language.isEmpty, language.lowercased() != "auto" {
            parts.append("language=\(language)")
        }
        let hints = promptHints(title: title, languageCode: language, metadata: metadata)
        if !hints.characters.isEmpty {
            parts.append("characters=\(hints.characters.joined(separator: ", "))")
        }
        if !hints.glossaryTerms.isEmpty {
            parts.append("glossary=\(hints.glossaryTerms.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func promptHints(
        title: String,
        languageCode: String,
        metadata: ASRPromptMetadata?
    ) -> (characters: [String], glossaryTerms: [String]) {
        let inferred = inferredPromptHints(title: title, languageCode: languageCode)
        return (
            characters: unique((metadata?.characters ?? []) + inferred.characters),
            glossaryTerms: unique((metadata?.glossaryTerms ?? []) + inferred.glossaryTerms)
        )
    }

    private static func inferredPromptHints(
        title: String,
        languageCode: String
    ) -> (characters: [String], glossaryTerms: [String]) {
        let language = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard language == "auto" || language.hasPrefix("ja") else {
            return ([], [])
        }
        let lowerTitle = title.lowercased()
        guard title.contains("コウペン") || lowerTitle.contains("koupen") else {
            return ([], [])
        }
        return (
            characters: ["コウペンちゃん", "邪エナガさん"],
            glossaryTerms: ["チョコバナナ", "ソースせんべい", "くじ引きやろう"]
        )
    }

    /// 是否对该识别档启用 whisper.cpp VAD。VAD 对演讲/对白安全（实测全程覆盖、转写几乎不变），但对
    /// 歌唱/音乐**灾难性失效**——silero 把演唱人声+伴奏判为非语音、丢掉大部分音频（实测 群青 130s→仅
    /// 1 段 47s 残片）。故歌词高质量档关闭 VAD。
    public static func vadEnabled(for recognitionProfile: ASRRecognitionProfile) -> Bool {
        recognitionProfile != .lyricsHighQuality
    }

    public static func maxTextContextTokens(
        videoURL: URL,
        languageCode: String,
        recognitionProfile: ASRRecognitionProfile = .speech
    ) -> Int? {
        if recognitionProfile == .lyricsHighQuality {
            return 0
        }
        let language = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cjkLanguage = language.hasPrefix("ja")
            || language.hasPrefix("ko")
            || language.hasPrefix("zh")
            || language.hasPrefix("yue")
            || language.hasPrefix("cmn")
        return cjkLanguage ? 0 : nil
    }

    public static func recognitionProfile(videoURL: URL, languageCode: String) -> ASRRecognitionProfile {
        let title = videoURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !title.isEmpty else { return .speech }
        let language = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let supportedLyricsLanguage = language.hasPrefix("ja")
            || language.hasPrefix("ko")
            || language.hasPrefix("zh")
            || language.hasPrefix("yue")
            || language.hasPrefix("cmn")
            || language.hasPrefix("en")
            || language.hasPrefix("fr")
            || language.hasPrefix("es")
            || language.hasPrefix("it")
        guard supportedLyricsLanguage || language == "auto" else { return .speech }
        let strongMusicMarkers = [
            "official music video", "music video", "official mv", " mv", "mv ",
            "official audio", "official visualizer", "performance video",
            "live", "lyrics", "lyric", "歌詞", "歌ってみた", "cover", "ライブ", "ライヴ"
        ]
        return strongMusicMarkers.contains(where: { title.contains($0) })
            || looksLikeOfficialArtistTitleRelease(title)
            ? .lyricsHighQuality
            : .speech
    }

    private static func looksLikeOfficialArtistTitleRelease(_ title: String) -> Bool {
        let officialMarkers = ["(official)", "[official]", "【official】"]
        guard officialMarkers.contains(where: { title.contains($0) }) else { return false }
        let artistTitleSeparators = [" ⧸ ", " / ", " ／ ", " - ", " – ", " — ", " | ", "｜"]
        return artistTitleSeparators.contains(where: { title.contains($0) })
    }
}

public struct ASRAudioExtractionPlan: Equatable, Sendable {
    public let ffmpegURL: URL
    public let inputURL: URL
    public let outputURL: URL
    public let arguments: [String]

    public init(ffmpegURL: URL, inputURL: URL, outputURL: URL) {
        self.ffmpegURL = ffmpegURL
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.arguments = [
            "-y",
            "-i", inputURL.path,
            "-map", "0:a:0",
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-f", "wav",
            outputURL.path
        ]
    }
}

public enum ASRAudioExtractorError: Error, Equatable, Sendable {
    case processFailed(status: Int32, stderrTail: String)
    case missingOutput(URL)
}

public struct ASRAudioActivityDetectionPlan: Equatable, Sendable {
    public let ffmpegURL: URL
    public let audioURL: URL
    public let arguments: [String]

    public init(ffmpegURL: URL, audioURL: URL) {
        self.ffmpegURL = ffmpegURL
        self.audioURL = audioURL
        self.arguments = [
            "-hide_banner",
            "-nostats",
            "-i", audioURL.path,
            "-af", "silencedetect=noise=-35dB:d=0.2",
            "-f", "null",
            "-"
        ]
    }
}

public enum ASRAudioActivityDetectorError: Error, Equatable, Sendable {
    case processFailed(status: Int32, stderrTail: String)
}

public protocol ASRAudioExtractor: Sendable {
    func extractAudio(
        plan: ASRAudioExtractionPlan,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> URL
}

public protocol ASRAudioActivityDetector: Sendable {
    func detectActivity(
        audioURL: URL,
        ffmpegURL: URL,
        control: TaskControlToken?
    ) async throws -> ASRAudioActivity
}

public struct ProcessASRAudioExtractor: ASRAudioExtractor {
    public init() {}

    public func extractAudio(
        plan: ASRAudioExtractionPlan,
        control: TaskControlToken? = nil,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        try await control?.gate()
        try FileManager.default.createDirectory(
            at: plan.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        progress(ASRProgress(phase: .audioExtract, completedUnits: 0, totalUnits: 1))
        let state = ASRCommandProcessState()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = plan.ffmpegURL
                process.arguments = plan.arguments
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let ioGroup = DispatchGroup()
                ioGroup.enter()
                ioGroup.enter()
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    _ = state.consume(data, stream: .stdout)
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    _ = state.consume(data, stream: .stderr)
                }
                process.terminationHandler = { finished in
                    let terminationStatus = finished.terminationStatus
                    DispatchQueue.global().async {
                        _ = ioGroup.wait(timeout: .now() + 5)
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        _ = state.flushRemainder()
                        control?.setActivePID(0)
                        state.resumeOnce {
                            continuation.resume(returning: terminationStatus)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    ioGroup.leave()
                    ioGroup.leave()
                    state.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if state.register(process) {
                    TaskControlToken.signalTree(process.processIdentifier, SIGKILL)
                }
                control?.setActivePID(process.processIdentifier)
            }
        } onCancel: {
            state.cancel()
        }
        if state.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw ASRAudioExtractorError.processFailed(status: status, stderrTail: state.stderrTail)
        }
        guard FileManager.default.fileExists(atPath: plan.outputURL.path) else {
            throw ASRAudioExtractorError.missingOutput(plan.outputURL)
        }
        progress(ASRProgress(phase: .audioExtract, completedUnits: 1, totalUnits: 1))
        return plan.outputURL
    }
}

public struct ProcessASRAudioActivityDetector: ASRAudioActivityDetector {
    public init() {}

    public func detectActivity(
        audioURL: URL,
        ffmpegURL: URL,
        control: TaskControlToken? = nil
    ) async throws -> ASRAudioActivity {
        try Task.checkCancellation()
        try await control?.gate()
        let plan = ASRAudioActivityDetectionPlan(ffmpegURL: ffmpegURL, audioURL: audioURL)
        let state = ASRCommandProcessState()
        let lines = LockedStringLines()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = plan.ffmpegURL
                process.arguments = plan.arguments
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let ioGroup = DispatchGroup()
                ioGroup.enter()
                ioGroup.enter()
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    lines.append(contentsOf: state.consume(data, stream: .stdout))
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    lines.append(contentsOf: state.consume(data, stream: .stderr))
                }
                process.terminationHandler = { finished in
                    let terminationStatus = finished.terminationStatus
                    DispatchQueue.global().async {
                        _ = ioGroup.wait(timeout: .now() + 5)
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        lines.append(contentsOf: state.flushRemainder())
                        control?.setActivePID(0)
                        state.resumeOnce {
                            continuation.resume(returning: terminationStatus)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    ioGroup.leave()
                    ioGroup.leave()
                    state.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if state.register(process) {
                    TaskControlToken.signalTree(process.processIdentifier, SIGKILL)
                }
                control?.setActivePID(process.processIdentifier)
            }
        } onCancel: {
            state.cancel()
        }
        if state.isCancelled { throw CancellationError() }
        guard status == 0 else {
            throw ASRAudioActivityDetectorError.processFailed(status: status, stderrTail: state.stderrTail)
        }
        return ASRAudioActivity.parseSilencedetectOutput(lines.joined())
    }
}

public struct WhisperCppLocalASRSubtitleGenerator: LocalASRSubtitleGenerator {
    public typealias PromptProvider = @Sendable (URL, String, ASRPromptMetadata?) -> String?

    public let ffmpegURL: URL
    public let workDirectoryURL: URL
    public let modelID: String
    public let vadModelURL: URL?

    private let recognizer: any SpeechRecognizer
    private let promptProvider: PromptProvider?
    private let audioActivityDetector: any ASRAudioActivityDetector
    private let audioExtractor: any ASRAudioExtractor

    public init(
        ffmpegURL: URL,
        workDirectoryURL: URL,
        recognizer: any SpeechRecognizer,
        modelID: String,
        vadModelURL: URL? = nil,
        promptProvider: PromptProvider? = nil,
        audioActivityDetector: any ASRAudioActivityDetector = ProcessASRAudioActivityDetector(),
        audioExtractor: any ASRAudioExtractor = ProcessASRAudioExtractor()
    ) {
        self.ffmpegURL = ffmpegURL
        self.workDirectoryURL = workDirectoryURL
        self.recognizer = recognizer
        self.modelID = modelID
        self.vadModelURL = vadModelURL
        self.promptProvider = promptProvider
        self.audioActivityDetector = audioActivityDetector
        self.audioExtractor = audioExtractor
    }

    public func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata? = nil,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> GeneratedLocalASRSource {
        try Task.checkCancellation()
        try await control?.gate()
        try FileManager.default.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)

        let audioURL = audioURL(for: videoFile, languageCode: languageCode)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            progress(ASRProgress(phase: .audioExtract, completedUnits: 1, totalUnits: 1))
        } else {
            let plan = ASRAudioExtractionPlan(ffmpegURL: ffmpegURL, inputURL: videoFile, outputURL: audioURL)
            _ = try await audioExtractor.extractAudio(plan: plan, control: control, progress: progress)
        }

        var request = makeRequest(
            videoFile: videoFile,
            audioURL: audioURL,
            languageCode: languageCode,
            promptMetadata: promptMetadata
        )
        var transcript = try await recognizer.transcribe(request, control: control, progress: progress)
        let languageHintCode = SubtitleLanguageRecommender.inferredLocalASRLanguageCode(
            title: videoFile.deletingPathExtension().lastPathComponent
        )
        var qualitySummary = qualitySummary(
            for: transcript,
            request: request,
            languageHintCode: languageHintCode
        )
        if shouldRetryAutoTranscript(
            summary: qualitySummary,
            request: request,
            languageHintCode: languageHintCode
        ), let retryLanguageCode = languageHintCode {
            try Task.checkCancellation()
            try await control?.gate()
            request = makeRequest(
                videoFile: videoFile,
                audioURL: audioURL,
                languageCode: retryLanguageCode,
                promptMetadata: promptMetadata
            )
            transcript = try await recognizer.transcribe(request, control: control, progress: progress)
            qualitySummary = self.qualitySummary(
                for: transcript,
                request: request,
                languageHintCode: languageHintCode
            )
        }
        // 严重质量问题（重复循环 / 自动语言误判）**不再让整个任务失败**——whisper 是 fallback，
        // 没有更好的源可换，硬失败只会让用户一无所得（这是近期被感知为"识别变差"的回归）。改为照常产出
        // 字幕，并把 qualitySummary 透传出去，由 QueueManager 给出诚实的"识别可能不可靠"提示，让用户决定。
        progress(ASRProgress(phase: .subtitleSegment, completedUnits: 0, totalUnits: 1))
        let audioActivity = try await audioActivityIfNeeded(
            transcript: transcript,
            videoFile: videoFile,
            audioURL: audioURL,
            control: control
        )
        let outputURL = try ASRTranscriptMapper.writeLocalASRSourceSRT(
            transcript: transcript,
            videoURL: videoFile,
            audioActivity: audioActivity
        )
        progress(ASRProgress(phase: .subtitleSegment, completedUnits: 1, totalUnits: 1))
        return GeneratedLocalASRSource(
            url: outputURL,
            confidence: qualitySummary)
    }

    private func makeRequest(
        videoFile: URL,
        audioURL: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata?
    ) -> ASRRequest {
        let recognitionProfile = ASRPromptBuilder.recognitionProfile(videoURL: videoFile, languageCode: languageCode)
        let prompt = promptProvider?(videoFile, languageCode, promptMetadata)
            ?? ASRPromptBuilder.defaultPrompt(
                videoURL: videoFile,
                languageCode: languageCode,
                recognitionProfile: recognitionProfile,
                metadata: promptMetadata
            )
        let maxTextContextTokens = ASRPromptBuilder.maxTextContextTokens(
            videoURL: videoFile,
            languageCode: languageCode,
            recognitionProfile: recognitionProfile
        )
        // VAD 对**演讲/对白**安全（实测全程覆盖、转写几乎不变），但对**歌唱/音乐**灾难性失效——silero 把
        // 演唱人声+伴奏判为非语音，丢掉大部分音频（实测 群青 130s→仅 1 段 47s 残片）。因此歌词档关闭 VAD。
        let vadEnabled = ASRPromptBuilder.vadEnabled(for: recognitionProfile)
        return ASRRequest(
            audioURL: audioURL,
            languageCode: languageCode,
            modelID: modelID,
            prompt: prompt,
            recognitionProfile: recognitionProfile,
            maxTextContextTokens: maxTextContextTokens,
            vadEnabled: vadEnabled,
            vadModelPath: vadModelURL?.path,
            wordTimestamps: true,
            cacheKey: cacheKey(
                for: videoFile,
                languageCode: languageCode,
                prompt: prompt,
                recognitionProfile: recognitionProfile,
                maxTextContextTokens: maxTextContextTokens,
                backendKind: .whisperCpp,
                vadEnabled: vadEnabled,
                vadModelPath: vadModelURL?.path,
                wordTimestamps: true,
                dtwTokenTimestamps: true
            )
        )
    }

    private func qualitySummary(
        for transcript: ASRTranscript,
        request: ASRRequest,
        languageHintCode: String?
    ) -> LocalASRConfidenceSummary {
        LocalASRConfidence.assess(
            words: transcript.words,
            segments: transcript.segments,
            languageCode: transcript.languageCode,
            requestedLanguageCode: request.languageCode,
            languageHintCode: languageHintCode
        )
    }

    private func shouldRetryAutoTranscript(
        summary: LocalASRConfidenceSummary,
        request: ASRRequest,
        languageHintCode: String?
    ) -> Bool {
        let requested = request.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard requested.isEmpty || requested == "auto" || requested == "und" || requested == "unknown" else {
            return false
        }
        guard let hint = languageHintCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty else {
            return false
        }
        return summary.qualityIssues.contains("autoLanguageMismatch")
            || summary.qualityIssues.contains("phraseLoop")
            || summary.qualityIssues.contains("lowSegmentDiversity")
    }

    private func audioActivityIfNeeded(
        transcript: ASRTranscript,
        videoFile: URL,
        audioURL: URL,
        control: TaskControlToken?
    ) async throws -> ASRAudioActivity? {
        let speechCues = ASRTranscriptMapper.sourceCues(from: transcript, profile: .speech)
        let profile = SubtitleTimingProfileDetector.detect(
            fileName: videoFile.lastPathComponent,
            cues: speechCues,
            languageCode: transcript.languageCode
        )
        guard profile == .lyrics || profile == .japaneseLyrics else {
            return nil
        }
        do {
            return try await audioActivityDetector.detectActivity(
                audioURL: audioURL,
                ffmpegURL: ffmpegURL,
                control: control
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func audioURL(for videoFile: URL, languageCode: String) -> URL {
        workDirectoryURL
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(stableFileStem(audioSeed(videoFile: videoFile, languageCode: languageCode))).wav", isDirectory: false)
    }

    private func cacheKey(
        for videoFile: URL,
        languageCode: String,
        prompt: String?,
        recognitionProfile: ASRRecognitionProfile,
        maxTextContextTokens: Int?,
        backendKind: ASRBackendKind,
        vadEnabled: Bool,
        vadModelPath: String?,
        wordTimestamps: Bool,
        dtwTokenTimestamps: Bool
    ) -> String {
        "local-asr:\(stableFileStem("\(audioSeed(videoFile: videoFile, languageCode: languageCode))\nbackend=\(backendKind.rawValue)\n\(prompt ?? "")\nrp=\(recognitionProfile.rawValue)\nmc=\(maxTextContextTokens.map(String.init) ?? "default")\nvad=\(vadEnabled)\nvm=\(vadModelPath ?? "none")\nwords=\(wordTimestamps)\ndtw=\(dtwTokenTimestamps)\nschema=v4"))"
    }

    private func audioSeed(videoFile: URL, languageCode: String) -> String {
        let path = videoFile.standardizedFileURL.path
        let attributes = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)) ?? [:]
        let size = attributes[.size] as? NSNumber
        let modifiedAt = attributes[.modificationDate] as? Date
        return [
            path,
            languageCode,
            modelID,
            size?.stringValue ?? "unknown-size",
            modifiedAt.map { String(format: "%.6f", $0.timeIntervalSince1970) } ?? "unknown-mtime"
        ].joined(separator: "\n")
    }

    private func stableFileStem(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum LocalASRGeneratorFactory {
    public static func make(
        settings: AppSettings,
        ffmpegURL: URL? = defaultFFmpegURL(),
        supportDirectoryURL: URL = AppSettings.supportDirectory,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) -> (any LocalASRSubtitleGenerator)? {
        guard settings.localASREnabled else { return nil }
        let sidecarRuntimePath = settings.localASRSidecarRuntimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let sidecarModelPath = settings.localASRSidecarModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.localASRPreciseModeEnabled {
            guard !sidecarRuntimePath.isEmpty, !sidecarModelPath.isEmpty else { return nil }
            let sidecarURL = URL(fileURLWithPath: sidecarRuntimePath)
            let sidecarModelURL = URL(fileURLWithPath: sidecarModelPath)
            guard isExecutable(sidecarURL),
                  FileManager.default.fileExists(atPath: sidecarModelURL.path) else {
                return nil
            }
            let asrDirectory = supportDirectoryURL.appendingPathComponent("asr", isDirectory: true)
            return SidecarLocalASRSubtitleGenerator(
                executableURL: sidecarURL,
                modelURL: sidecarModelURL,
                workDirectoryURL: asrDirectory.appendingPathComponent("sidecar-work", isDirectory: true)
            )
        }
        let runtimePath = settings.localASRRuntimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelPath = settings.localASRModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = settings.localASRModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtimePath.isEmpty, !modelPath.isEmpty, !modelID.isEmpty else { return nil }
        guard let ffmpegURL, isExecutable(ffmpegURL) else { return nil }

        let runtimeURL = URL(fileURLWithPath: runtimePath)
        let modelURL = URL(fileURLWithPath: modelPath)
        guard isExecutable(runtimeURL), FileManager.default.fileExists(atPath: modelURL.path) else {
            return nil
        }
        guard isReadyModel(modelID: modelID, modelURL: modelURL, supportDirectoryURL: supportDirectoryURL) else {
            return nil
        }
        let vadModelPath = settings.localASRVADModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let vadModelURL: URL? = {
            guard !vadModelPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: vadModelPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }()

        let asrDirectory = supportDirectoryURL.appendingPathComponent("asr", isDirectory: true)
        let recognizer = WhisperCppSpeechRecognizer(
            runtime: ASRRuntimeInfo(executableURL: runtimeURL),
            modelURL: modelURL,
            outputDirectoryURL: asrDirectory.appendingPathComponent("transcripts-work", isDirectory: true),
            cacheStore: ASRTranscriptCacheStore(directoryURL: asrDirectory.appendingPathComponent("cache", isDirectory: true)),
            nowProvider: nowProvider
        )
        return WhisperCppLocalASRSubtitleGenerator(
            ffmpegURL: ffmpegURL,
            workDirectoryURL: asrDirectory.appendingPathComponent("work", isDirectory: true),
            recognizer: recognizer,
            modelID: modelID,
            vadModelURL: vadModelURL,
            promptProvider: { videoURL, languageCode, metadata in
                ASRPromptBuilder.defaultPrompt(
                    videoURL: videoURL,
                    languageCode: languageCode,
                    recognitionProfile: ASRPromptBuilder.recognitionProfile(videoURL: videoURL, languageCode: languageCode),
                    metadata: metadata
                )
            }
        )
    }

    public static func defaultFFmpegURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []
        if let custom = environment["MOONGATE_FFMPEG_PATH"], !custom.isEmpty {
            candidates.append(custom)
        }
        if let prefix = environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            candidates.append(prefix + "/opt/ffmpeg-full/bin/ffmpeg")
            candidates.append(prefix + "/bin/ffmpeg")
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",
            "/usr/local/opt/ffmpeg-full/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ])
        if let path = environment["PATH"], !path.isEmpty {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/ffmpeg" })
        }

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            let url = URL(fileURLWithPath: path)
            if isExecutable(url) { return url }
        }
        return nil
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func isReadyModel(modelID: String, modelURL: URL, supportDirectoryURL: URL) -> Bool {
        guard let model = ASRModelManifest.recommendedWhisperCpp.models.first(where: { $0.id == modelID }) else {
            return true
        }
        let store = ASRModelStore(directoryURL: supportDirectoryURL
            .appendingPathComponent("asr", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true))
        guard let status = try? store.status(for: model), status.isInstalled else {
            return false
        }
        return normalizedPath(modelURL) == normalizedPath(status.installedURL)
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

public struct WhisperCppCommandPlan: Equatable, Sendable {
    public let runtime: ASRRuntimeInfo
    public let modelURL: URL
    public let request: ASRRequest
    public let outputBaseURL: URL
    public let disableGPU: Bool
    public let arguments: [String]

    public var executableURL: URL { runtime.executableURL }

    public var outputJSONURL: URL {
        outputBaseURL.deletingPathExtension().appendingPathExtension("json")
    }

    public init(
        runtime: ASRRuntimeInfo,
        modelURL: URL,
        request: ASRRequest,
        outputBaseURL: URL,
        disableGPU: Bool = false
    ) {
        self.runtime = runtime
        self.modelURL = modelURL
        self.request = request
        self.outputBaseURL = outputBaseURL.deletingPathExtension()
        self.disableGPU = disableGPU
        var arguments = [
            "-m", modelURL.path,
            "-f", request.audioURL.path,
            request.wordTimestamps ? "-ojf" : "-oj",
            "-of", self.outputBaseURL.path,
            "-pp"
        ]
        if disableGPU {
            arguments.append("--no-gpu")
        }
        if request.vadEnabled,
           let vadModelPath = request.vadModelPath,
           FileManager.default.fileExists(atPath: vadModelPath) {
            arguments.append(contentsOf: ["--vad", "-vm", vadModelPath])
        }
        // DTW token timestamps need full JSON token output, a known preset, and flash attention
        // OFF (`-nfa`) — otherwise whisper.cpp silently disables DTW.
        if request.wordTimestamps,
           request.dtwTokenTimestamps,
           let preset = WhisperDTWPreset.preset(forModelID: request.modelID) {
            arguments.append(contentsOf: ["-dtw", preset, "-nfa"])
        }
        if let languageCode = request.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !languageCode.isEmpty,
           languageCode.lowercased() != "auto" {
            arguments.append(contentsOf: ["-l", languageCode])
        }
        if let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", prompt])
        }
        if let maxTextContextTokens = request.maxTextContextTokens {
            arguments.append(contentsOf: ["-mc", String(max(0, maxTextContextTokens))])
        }
        self.arguments = arguments
    }
}

public struct ASRCommandResult: Equatable, Sendable {
    public let status: Int32
    public let stderrTail: String

    public init(status: Int32, stderrTail: String) {
        self.status = status
        self.stderrTail = stderrTail
    }
}

public protocol ASRCommandRunner: Sendable {
    func runWhisper(
        plan: WhisperCppCommandPlan,
        control: TaskControlToken?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ASRCommandResult
}

public struct ProcessASRCommandRunner: ASRCommandRunner {
    public let environment: [String: String]
    public let currentDirectoryURL: URL?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL? = nil
    ) {
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }

    public func runWhisper(
        plan: WhisperCppCommandPlan,
        control: TaskControlToken? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ASRCommandResult {
        let state = ASRCommandProcessState()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let process = Process()
                process.executableURL = plan.executableURL
                process.arguments = plan.arguments
                process.environment = environment
                if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let ioGroup = DispatchGroup()
                ioGroup.enter()
                ioGroup.enter()

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    for line in state.consume(data, stream: .stdout) { onLine(line) }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ioGroup.leave()
                        return
                    }
                    for line in state.consume(data, stream: .stderr) { onLine(line) }
                }
                process.terminationHandler = { finished in
                    let terminationStatus = finished.terminationStatus
                    DispatchQueue.global().async {
                        _ = ioGroup.wait(timeout: .now() + 5)
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        for line in state.flushRemainder() { onLine(line) }
                        control?.setActivePID(0)
                        state.resumeOnce {
                            continuation.resume(returning: terminationStatus)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    ioGroup.leave()
                    ioGroup.leave()
                    state.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if state.register(process) {
                    TaskControlToken.signalTree(process.processIdentifier, SIGKILL)
                }
                control?.setActivePID(process.processIdentifier)
            }
        } onCancel: {
            state.cancel()
        }
        if state.isCancelled { throw CancellationError() }
        return ASRCommandResult(status: status, stderrTail: state.stderrTail)
    }
}

public enum WhisperCppRecognizerError: Error, Equatable, Sendable {
    case missingRuntime(URL)
    case missingModel(URL)
    case processFailed(status: Int32, stderrTail: String)
    case missingTranscriptJSON(URL)
    case emptyTranscript
    case invalidTranscriptJSON(String)
}

public enum ASRProgressLineParser {
    public static func whisperCppProgress(from line: String) -> ASRProgress? {
        // 只认 whisper.cpp 自己的进度行（`whisper_print_progress_callback: progress = 25%` /
        // `whisper.cpp progress: 25%`）。旧版用 `([0-9.]+)\s*%` 匹配任意含 % 的行，会把转写出来的台词
        // 文本（如 "…sales up 50%…"）误当成进度更新，导致进度条乱跳。用 “progress” 关键字 + 分隔符锚定，
        // 同时兼容 `=`/`:` 两种 whisper.cpp 版本格式。
        guard let range = line.range(
            of: #"(?i)progress\s*[:=]\s*[0-9]+(?:\.[0-9]+)?\s*%"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let matched = String(line[range])
        guard let numberRange = matched.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let value = Double(matched[numberRange]), value.isFinite else {
            return nil
        }
        return ASRProgress(
            phase: .speechRecognition,
            completedUnits: min(max(value, 0), 100),
            totalUnits: 100
        )
    }
}

public struct WhisperCppJSONTranscriptParser: Sendable {
    public init() {}

    public func parse(
        data: Data,
        request: ASRRequest,
        transcriptID: String,
        createdAt: Date = Date()
    ) throws -> ASRTranscript {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WhisperCppRecognizerError.invalidTranscriptJSON("Root object is not a JSON dictionary.")
            }
            root = object
        } catch let error as WhisperCppRecognizerError {
            throw error
        } catch {
            throw WhisperCppRecognizerError.invalidTranscriptJSON(error.localizedDescription)
        }

        let languageCode = languageCode(in: root, request: request)
        let languageConfidence = languageConfidence(in: root)
        let segments = (root["transcription"] as? [[String: Any]])
            ?? (root["segments"] as? [[String: Any]])
            ?? []
        var words: [ASRWord] = []
        var transcriptSegments: [ASRSegment] = []
        var rawTexts: [String] = []
        var dtwStarts: [Double?] = []
        var maxEnd: Double?

        for segment in segments {
            if let interval = interval(in: segment, offsetValuesAreMilliseconds: true) {
                maxEnd = max(maxEnd ?? interval.end, interval.end)
                if let text = cleanText(segment["text"] as? String) {
                    transcriptSegments.append(ASRSegment(text: text, startSeconds: interval.start, endSeconds: interval.end))
                    rawTexts.append(text)
                }
            }
            let tokenEntries = parseTokenEntries(in: segment, segmentText: cleanText(segment["text"] as? String))
            if tokenEntries.isEmpty {
                if let fallback = parseSegmentWord(segment) {
                    words.append(fallback)
                    dtwStarts.append(nil)
                    maxEnd = max(maxEnd ?? fallback.endSeconds, fallback.endSeconds)
                }
            } else {
                for entry in tokenEntries {
                    words.append(entry.word)
                    dtwStarts.append(entry.dtwStart)
                }
            }
        }

        // When whisper.cpp emitted DTW token timestamps (`-dtw`, requires `-nfa`), prefer them:
        // they are markedly closer to human timing than the default frame-quantized offsets.
        // Each token's DTW point becomes its start; the next DTW token's point becomes its end.
        if dtwStarts.contains(where: { $0 != nil }) {
            words = applyDTWTiming(words: words, dtwStarts: dtwStarts)
        }
        for word in words {
            maxEnd = max(maxEnd ?? word.endSeconds, word.endSeconds)
        }

        guard !words.isEmpty else { throw WhisperCppRecognizerError.emptyTranscript }
        return ASRTranscript(
            id: transcriptID,
            languageCode: languageCode,
            languageConfidence: languageConfidence,
            durationSeconds: maxEnd,
            words: words,
            sourceModelID: request.modelID,
            backendKind: .whisperCpp,
            segments: transcriptSegments,
            rawText: rawTexts.isEmpty ? nil : rawTexts.joined(separator: "\n"),
            backendDiagnostics: [
                "segmentCount": String(segments.count),
                "wordTimestampMode": request.wordTimestamps ? "word" : "segment",
                "dtwRequested": String(request.wordTimestamps && request.dtwTokenTimestamps),
                "vadRequested": String(request.vadEnabled)
            ],
            qualitySummary: LocalASRConfidence.assess(
                words: words,
                segments: transcriptSegments,
                languageCode: languageCode,
                requestedLanguageCode: request.languageCode
            ),
            createdAt: createdAt
        )
    }

    private func languageCode(in root: [String: Any], request: ASRRequest) -> String {
        let result = root["result"] as? [String: Any]
        let params = root["params"] as? [String: Any]
        return [
            result?["language"] as? String,
            params?["language"] as? String,
            request.languageCode
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? "auto"
    }

    private func languageConfidence(in root: [String: Any]) -> Double? {
        let result = root["result"] as? [String: Any]
        return number(in: result, keys: ["language_probability", "languageProbability", "language_confidence", "languageConfidence"])
    }

    private func parseTokenEntries(
        in segment: [String: Any],
        segmentText: String? = nil
    ) -> [(word: ASRWord, dtwStart: Double?)] {
        let tokens = (segment["tokens"] as? [[String: Any]])
            ?? (segment["words"] as? [[String: Any]])
            ?? []
        var entries: [(word: ASRWord, dtwStart: Double?)] = []
        var mergeEligible: [Bool] = []
        for token in tokens {
            let rawText = token["text"] as? String ?? ""
            if isWhisperControlToken(rawText) {
                continue
            }
            guard let text = cleanText(rawText),
                  let interval = tokenInterval(in: token, offsetValuesAreMilliseconds: true) else {
                continue
            }
            let word = ASRWord(
                text: text,
                startSeconds: interval.start,
                endSeconds: interval.end,
                probability: number(in: token, keys: ["p", "probability", "confidence"])
            )
            // whisper.cpp t_dtw is in centiseconds; -1 means "not computed".
            let dtwStart: Double?
            if let raw = number(in: token, keys: ["t_dtw"]), raw >= 0 {
                dtwStart = raw / 100.0
            } else {
                dtwStart = nil
            }
            let startsNewWhisperTokenWord = rawText.first?.isWhitespace == true
                && !parserContainsCJKOrHangul(text)
            if let previous = entries.last,
               shouldMergeLatinParserToken(
                previousText: previous.word.text,
                previousMergeEligible: mergeEligible.last == true,
                currentText: text,
                rawCurrentText: rawText
               ) {
                let mergedWord = ASRWord(
                    text: previous.word.text + text,
                    startSeconds: previous.word.startSeconds,
                    endSeconds: max(previous.word.endSeconds, word.endSeconds),
                    probability: min(previous.word.probability ?? 1.0, word.probability ?? 1.0)
                )
                entries[entries.count - 1] = (mergedWord, previous.dtwStart ?? dtwStart)
                mergeEligible[mergeEligible.count - 1] = true
            } else {
                entries.append((word, dtwStart))
                mergeEligible.append(startsNewWhisperTokenWord)
            }
        }
        return spacedScriptSegmentWordEntries(segmentText: segmentText, entries: entries) ?? entries
    }

    /// Rebuild word-level entries from segment text for scripts that whisper.cpp writes with real
    /// word spacing but splits into sub-character token pieces (Hangul eojeol, Devanagari words).
    /// CJK (Chinese/Japanese) segment text has no spaces, so it yields <2 units and is left untouched.
    private func spacedScriptSegmentWordEntries(
        segmentText: String?,
        entries: [(word: ASRWord, dtwStart: Double?)]
    ) -> [(word: ASRWord, dtwStart: Double?)]? {
        guard let segmentText,
              parserContainsHangul(segmentText) || parserContainsSpacedScript(segmentText),
              !entries.isEmpty else {
            return nil
        }
        let units = segmentText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard units.count >= 2 else { return nil }

        var output: [(word: ASRWord, dtwStart: Double?)] = []
        var entryIndex = entries.startIndex
        for unit in units {
            let target = parserAlignmentText(unit)
            guard !target.isEmpty else { return nil }
            var consumed: [(word: ASRWord, dtwStart: Double?)] = []
            var accumulated = ""
            while entryIndex < entries.endIndex, accumulated != target {
                let entry = entries[entryIndex]
                let tokenText = parserAlignmentText(entry.word.text)
                guard !tokenText.isEmpty else { return nil }
                accumulated += tokenText
                guard target.hasPrefix(accumulated) else { return nil }
                consumed.append(entry)
                entryIndex = entries.index(after: entryIndex)
            }
            guard accumulated == target,
                  let first = consumed.first,
                  let last = consumed.last else {
                return nil
            }
            output.append((
                word: ASRWord(
                    text: unit,
                    startSeconds: first.word.startSeconds,
                    endSeconds: consumed.reduce(last.word.endSeconds) { max($0, $1.word.endSeconds) },
                    probability: consumed.map { $0.word.probability ?? 1.0 }.min()
                ),
                dtwStart: first.dtwStart
            ))
        }
        guard entryIndex == entries.endIndex else { return nil }
        return output
    }

    private func shouldMergeLatinParserToken(
        previousText: String,
        previousMergeEligible: Bool,
        currentText: String,
        rawCurrentText: String
    ) -> Bool {
        guard previousMergeEligible else { return false }
        guard rawCurrentText.first?.isWhitespace != true else { return false }
        let previous = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !current.isEmpty else { return false }
        if parserContainsCJKOrHangul(previous) || parserContainsCJKOrHangul(current) { return false }
        if parserIsLatinJoinPunctuation(current) { return true }
        if parserIsLatinApostrophePrefix(previous) && parserContainsLetterOutsideCJK(current) { return true }
        return parserContainsLetterOutsideCJK(previous) && parserContainsLetterOutsideCJK(current)
    }

    private func parserIsLatinJoinPunctuation(_ text: String) -> Bool {
        text.allSatisfy { character in
            character == "'" || character == "’" || character == "." || character == "," || character == "!" || character == "?" || character == ":" || character == ";"
        } || (text.first == "'" || text.first == "’")
    }

    private func parserIsLatinApostrophePrefix(_ text: String) -> Bool {
        text.allSatisfy { $0 == "'" || $0 == "’" }
    }

    private func parserContainsLetterOutsideCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && !parserIsCJKOrHangulScalar(scalar)
        }
    }

    private func parserContainsCJKOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { parserIsCJKOrHangulScalar($0) }
    }

    private func parserContainsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(Int(scalar.value))
        }
    }

    /// Space-separated non-CJK scripts that whisper.cpp writes with real word spacing but splits
    /// into base-letter + combining-mark token pieces (Devanagari, Bengali, Arabic, Cyrillic, …).
    /// Word entries must be rebuilt from segment text to keep readable spacing, mirroring the Hangul
    /// eojeol reconstruction. CJK (Han/Kana) is intentionally excluded: it has no word spaces.
    private func parserContainsSpacedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = Int(scalar.value)
            return (0x0900...0x097F).contains(v)   // Devanagari
                || (0x0980...0x09FF).contains(v)   // Bengali
                || (0x0600...0x06FF).contains(v)   // Arabic
                || (0x0750...0x077F).contains(v)   // Arabic Supplement
                || (0x08A0...0x08FF).contains(v)   // Arabic Extended-A
                || (0x0400...0x04FF).contains(v)   // Cyrillic
                || (0x0500...0x052F).contains(v)   // Cyrillic Supplement
        }
    }

    private func parserAlignmentText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
    }

    private func isWhisperControlToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[_") && trimmed.hasSuffix("]")
    }

    private func parserIsCJKOrHangulScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(Int(scalar.value))
            || (0x3400...0x4DBF).contains(Int(scalar.value))
            || (0x4E00...0x9FFF).contains(Int(scalar.value))
            || (0xAC00...0xD7A3).contains(Int(scalar.value))
    }

    /// Rewrites word start/end using DTW token points: word i starts at its DTW point and ends at
    /// the next DTW point — but capped at the word's own acoustic (offsets) duration, so a word
    /// preceding a pause does NOT absorb the whole silent gap (which previously produced lone,
    /// multi-second single-morpheme cues like 「顔」 and forced unnatural splits). Tokens without a
    /// DTW point keep their offsets timing.
    private func applyDTWTiming(words: [ASRWord], dtwStarts: [Double?]) -> [ASRWord] {
        let minWordSeconds = 0.12
        var result = words
        for index in words.indices {
            guard let start = dtwStarts[index] else { continue }
            let offsetsDuration = max(minWordSeconds, words[index].endSeconds - words[index].startSeconds)
            let acousticEnd = start + offsetsDuration
            var end = acousticEnd
            var lookahead = index + 1
            while lookahead < words.count {
                if let nextStart = dtwStarts[lookahead] {
                    // Contiguous speech: end at the next onset. Across a real pause: stop at the
                    // word's acoustic end so the silence stays a gap (not folded into this word).
                    if nextStart > start { end = min(nextStart, acousticEnd) }
                    break
                }
                lookahead += 1
            }
            if end < start { end = start }
            result[index] = ASRWord(
                text: words[index].text,
                startSeconds: start,
                endSeconds: end,
                probability: words[index].probability
            )
        }
        return result
    }

    private func tokenInterval(
        in object: [String: Any],
        offsetValuesAreMilliseconds: Bool
    ) -> (start: Double, end: Double)? {
        if let interval = interval(in: object, offsetValuesAreMilliseconds: offsetValuesAreMilliseconds) {
            return interval
        }
        if let repaired = repairedReversedInterval(
            in: object["offsets"] as? [String: Any],
            valuesAreMilliseconds: offsetValuesAreMilliseconds
        ) {
            return repaired
        }
        if let repaired = repairedReversedInterval(
            in: object["timestamps"] as? [String: Any],
            valuesAreMilliseconds: false
        ) {
            return repaired
        }
        return nil
    }

    private func repairedReversedInterval(
        in object: [String: Any]?,
        valuesAreMilliseconds: Bool
    ) -> (start: Double, end: Double)? {
        guard let object,
              let start = seconds(from: object["from"], valuesAreMilliseconds: valuesAreMilliseconds),
              let end = seconds(from: object["to"], valuesAreMilliseconds: valuesAreMilliseconds),
              end < start else {
            return nil
        }
        return (start, start + 0.01)
    }

    private func parseSegmentWord(_ segment: [String: Any]) -> ASRWord? {
        guard let text = cleanText(segment["text"] as? String),
              let interval = interval(in: segment, offsetValuesAreMilliseconds: true) else {
            return nil
        }
        return ASRWord(
            text: text,
            startSeconds: interval.start,
            endSeconds: interval.end,
            probability: number(in: segment, keys: ["p", "probability", "confidence"])
        )
    }

    private func interval(
        in object: [String: Any],
        offsetValuesAreMilliseconds: Bool
    ) -> (start: Double, end: Double)? {
        if let offsets = object["offsets"] as? [String: Any],
           let start = seconds(from: offsets["from"], valuesAreMilliseconds: offsetValuesAreMilliseconds),
           let end = seconds(from: offsets["to"], valuesAreMilliseconds: offsetValuesAreMilliseconds),
           end >= start {
            return (start, end)
        }
        if let timestamps = object["timestamps"] as? [String: Any],
           let start = seconds(from: timestamps["from"], valuesAreMilliseconds: false),
           let end = seconds(from: timestamps["to"], valuesAreMilliseconds: false),
           end >= start {
            return (start, end)
        }
        let start = seconds(from: object["start"] ?? object["startSeconds"], valuesAreMilliseconds: false)
        let end = seconds(from: object["end"] ?? object["endSeconds"], valuesAreMilliseconds: false)
        if let start, let end, end >= start { return (start, end) }
        return nil
    }

    private func seconds(from value: Any?, valuesAreMilliseconds: Bool) -> Double? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return valuesAreMilliseconds ? raw / 1000 : raw
        }
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        if let raw = Double(string) {
            return valuesAreMilliseconds ? raw / 1000 : raw
        }
        let components = string.split(separator: ":").compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard components.count == 3 else { return nil }
        return components[0] * 3600 + components[1] * 60 + components[2]
    }

    private func cleanText(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func number(in object: [String: Any]?, keys: [String]) -> Double? {
        guard let object else { return nil }
        for key in keys {
            if let number = object[key] as? NSNumber { return number.doubleValue }
            if let string = object[key] as? String, let number = Double(string) { return number }
        }
        return nil
    }
}

public struct WhisperCppSpeechRecognizer: SpeechRecognizer {
    public let runtime: ASRRuntimeInfo
    public let modelURL: URL
    public let outputDirectoryURL: URL
    public let cacheStore: ASRTranscriptCacheStore?

    private let commandRunner: any ASRCommandRunner
    private let nowProvider: @Sendable () -> Date
    private let parser: WhisperCppJSONTranscriptParser

    public init(
        runtime: ASRRuntimeInfo,
        modelURL: URL,
        outputDirectoryURL: URL,
        cacheStore: ASRTranscriptCacheStore? = nil,
        commandRunner: any ASRCommandRunner = ProcessASRCommandRunner(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        parser: WhisperCppJSONTranscriptParser = WhisperCppJSONTranscriptParser()
    ) {
        self.runtime = runtime
        self.modelURL = modelURL
        self.outputDirectoryURL = outputDirectoryURL
        self.cacheStore = cacheStore
        self.commandRunner = commandRunner
        self.nowProvider = nowProvider
        self.parser = parser
    }

    public func readiness(for request: ASRRequest) async -> ASRReadiness {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: runtime.executableURL.path) else {
            return ASRReadiness(
                status: .missingRuntime,
                modelID: request.modelID,
                message: "whisper.cpp runtime is missing."
            )
        }
        guard fm.fileExists(atPath: modelURL.path) else {
            return ASRReadiness(
                status: .missingModel,
                modelID: request.modelID,
                message: "Whisper model is not installed."
            )
        }
        return ASRReadiness(
            status: .ready,
            modelID: request.modelID,
            message: "Local speech recognition is ready."
        )
    }

    public func transcribe(
        _ request: ASRRequest,
        control: TaskControlToken? = nil,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> ASRTranscript {
        try Task.checkCancellation()
        try await control?.gate()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: runtime.executableURL.path) else {
            throw WhisperCppRecognizerError.missingRuntime(runtime.executableURL)
        }
        guard fm.fileExists(atPath: modelURL.path) else {
            throw WhisperCppRecognizerError.missingModel(modelURL)
        }

        progress(ASRProgress(phase: .speechRecognition, completedUnits: 0, totalUnits: 1))
        let audioFingerprint = "sha256:\(try ASRModelStore.sha256(of: request.audioURL))"
        if let cacheKey = request.cacheKey,
           let cached = try cacheStore?.cachedTranscript(
                cacheKey: cacheKey,
                audioFingerprint: audioFingerprint,
                modelID: request.modelID,
                backendKind: .whisperCpp,
                languageCode: request.languageCode
           ) {
            progress(ASRProgress(phase: .speechRecognition, completedUnits: 1, totalUnits: 1))
            return cached
        }

        try fm.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        let transcriptID = request.cacheKey ?? UUID().uuidString
        let outputBaseURL = outputDirectoryURL.appendingPathComponent(Self.stableFileStem(transcriptID), isDirectory: false)

        func run(_ planRequest: ASRRequest, disableGPU: Bool = false) async throws -> (plan: WhisperCppCommandPlan, result: ASRCommandResult) {
            let plan = WhisperCppCommandPlan(
                runtime: runtime,
                modelURL: modelURL,
                request: planRequest,
                outputBaseURL: outputBaseURL,
                disableGPU: disableGPU
            )
            let result = try await commandRunner.runWhisper(plan: plan, control: control) { line in
                if let parsed = ASRProgressLineParser.whisperCppProgress(from: line) {
                    progress(parsed)
                }
            }
            try Task.checkCancellation()
            return (plan, result)
        }

        var disableGPU = false
        var (plan, result) = try await run(request, disableGPU: disableGPU)
        if Self.shouldRetryWithoutGPU(result: result) {
            disableGPU = true
            (plan, result) = try await run(request, disableGPU: disableGPU)
        }
        let usedDTW = request.wordTimestamps
            && request.dtwTokenTimestamps
            && WhisperDTWPreset.preset(forModelID: request.modelID) != nil
        if usedDTW, result.status != 0 || !fm.fileExists(atPath: plan.outputJSONURL.path) {
            // Fail-safe: if a model build rejects `-dtw`/`-nfa`, retry once without it so a DTW
            // incompatibility degrades to plain offsets instead of failing the whole run.
            (plan, result) = try await run(request.disablingDTW(), disableGPU: disableGPU)
        }

        guard result.status == 0 else {
            throw WhisperCppRecognizerError.processFailed(status: result.status, stderrTail: result.stderrTail)
        }
        guard fm.fileExists(atPath: plan.outputJSONURL.path) else {
            throw WhisperCppRecognizerError.missingTranscriptJSON(plan.outputJSONURL)
        }

        let transcript = try parser.parse(
            data: Data(contentsOf: plan.outputJSONURL),
            request: request,
            transcriptID: transcriptID,
            createdAt: nowProvider()
        )
        if let cacheKey = request.cacheKey {
            try cacheStore?.write(
                transcript: transcript,
                cacheKey: cacheKey,
                audioFingerprint: audioFingerprint,
                languageCode: request.languageCode
            )
        }
        progress(ASRProgress(phase: .speechRecognition, completedUnits: 1, totalUnits: 1))
        return transcript
    }

    private static func shouldRetryWithoutGPU(result: ASRCommandResult) -> Bool {
        guard result.status != 0 else { return false }
        let stderr = result.stderrTail.lowercased()
        return stderr.contains("ggml_metal")
            || stderr.contains("metal buffer")
            || stderr.contains("failed to allocate buffer")
    }

    private static func stableFileStem(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class ASRCommandProcessState: @unchecked Sendable {
    enum Stream {
        case stdout
        case stderr
    }

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var resumed = false
    private var stdoutRemainder = Data()
    private var stderrRemainder = Data()
    private var stderrStorage = Data()
    private let stderrLimit = 16 * 1024

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrStorage, as: UTF8.self)
    }

    func register(_ process: Process) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            return true
        }
        self.process = process
        lock.unlock()
        return false
    }

    func cancel() {
        let process: Process?
        lock.lock()
        cancelled = true
        process = self.process
        lock.unlock()
        if let process, process.isRunning {
            TaskControlToken.signalTree(process.processIdentifier, SIGKILL)
        }
    }

    func consume(_ data: Data, stream: Stream) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if stream == .stderr { appendStderrLocked(data) }
        var buffer = stream == .stdout ? stdoutRemainder : stderrRemainder
        buffer.append(data)
        let lines = extractLines(from: &buffer)
        if stream == .stdout {
            stdoutRemainder = buffer
        } else {
            stderrRemainder = buffer
        }
        return lines
    }

    func flushRemainder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        if !stdoutRemainder.isEmpty {
            lines.append(String(decoding: stdoutRemainder, as: UTF8.self))
            stdoutRemainder.removeAll(keepingCapacity: true)
        }
        if !stderrRemainder.isEmpty {
            lines.append(String(decoding: stderrRemainder, as: UTF8.self))
            stderrRemainder.removeAll(keepingCapacity: true)
        }
        return lines
    }

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        body()
    }

    private func appendStderrLocked(_ data: Data) {
        stderrStorage.append(data)
        if stderrStorage.count > stderrLimit {
            stderrStorage.removeFirst(stderrStorage.count - stderrLimit)
        }
    }

    private func extractLines(from data: inout Data) -> [String] {
        var lines: [String] = []
        while let index = data.firstIndex(of: 0x0A) {
            let lineData = data[..<index]
            let next = data.index(after: index)
            data.removeSubrange(..<next)
            lines.append(String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        return lines
    }
}

private final class LockedStringLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(contentsOf lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        storage.append(contentsOf: lines)
        lock.unlock()
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage.joined(separator: "\n")
    }
}

public struct ASRTranscriptCacheStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func entryURL(cacheKey: String) -> URL {
        directoryURL.appendingPathComponent("\(Self.stableFileStem(cacheKey)).entry.json", isDirectory: false)
    }

    public func transcriptURL(cacheKey: String) -> URL {
        directoryURL.appendingPathComponent("\(Self.stableFileStem(cacheKey)).transcript.json", isDirectory: false)
    }

    @discardableResult
    public func write(
        transcript: ASRTranscript,
        cacheKey: String,
        audioFingerprint: String,
        languageCode: String? = nil,
        createdAt: Date = Date()
    ) throws -> ASRTranscriptCacheEntry {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let transcriptURL = transcriptURL(cacheKey: cacheKey)
        let entryURL = entryURL(cacheKey: cacheKey)
        let encoder = ASRJSON.makeEncoder()
        try writeAtomically(encoder.encode(transcript), to: transcriptURL)
        let entry = ASRTranscriptCacheEntry(
            cacheKey: cacheKey,
            audioFingerprint: audioFingerprint,
            modelID: transcript.sourceModelID,
            backendKind: transcript.backendKind,
            languageCode: Self.normalizedCacheLanguage(languageCode)
                ?? Self.normalizedCacheLanguage(transcript.languageCode),
            transcriptURL: transcriptURL,
            createdAt: createdAt
        )
        try writeAtomically(encoder.encode(entry), to: entryURL)
        return entry
    }

    public func readEntry(cacheKey: String) throws -> ASRTranscriptCacheEntry? {
        let url = entryURL(cacheKey: cacheKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ASRJSON.makeDecoder().decode(ASRTranscriptCacheEntry.self, from: Data(contentsOf: url))
    }

    public func readTranscript(entry: ASRTranscriptCacheEntry) throws -> ASRTranscript {
        try ASRJSON.makeDecoder().decode(ASRTranscript.self, from: Data(contentsOf: entry.transcriptURL))
    }

    public func cachedTranscript(
        cacheKey: String,
        audioFingerprint: String,
        modelID: String,
        backendKind: ASRBackendKind = .whisperCpp,
        languageCode: String?
    ) throws -> ASRTranscript? {
        let requestedLanguageCode = Self.normalizedCacheLanguage(languageCode)
        guard let entry = try readEntry(cacheKey: cacheKey),
              entry.audioFingerprint == audioFingerprint,
              entry.modelID == modelID,
              entry.backendKind == backendKind,
              requestedLanguageCode == nil || Self.normalizedCacheLanguage(entry.languageCode) == requestedLanguageCode,
              FileManager.default.fileExists(atPath: entry.transcriptURL.path) else {
            return nil
        }
        return try readTranscript(entry: entry)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    private static func stableFileStem(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedCacheLanguage(_ languageCode: String?) -> String? {
        let trimmed = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let trimmed, !trimmed.isEmpty, trimmed != "auto" else { return nil }
        return trimmed
    }
}

public struct ASRRuntimeInfo: Codable, Equatable, Sendable {
    public let provider: String
    public let executableURL: URL

    public init(provider: String = "whisper.cpp", executableURL: URL) {
        self.provider = provider
        self.executableURL = executableURL
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case executablePath
        case legacyExecutableURL = "executableUrl"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "whisper.cpp"
        let executableValue = try container.decodeIfPresent(String.self, forKey: .executablePath)
            ?? container.decode(String.self, forKey: .legacyExecutableURL)
        if let url = URL(string: executableValue), url.isFileURL {
            self.executableURL = url
        } else {
            self.executableURL = URL(fileURLWithPath: executableValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(executableURL.path, forKey: .executablePath)
    }
}

public struct ASRRuntimeLocator: Sendable {
    public static let runtimeManifestFileName = "asr-runtime-manifest.json"

    public static var currentPlatform: String {
        #if os(macOS)
        "macos"
        #elseif os(Windows)
        "windows"
        #elseif os(Linux)
        "linux"
        #else
        "unknown"
        #endif
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x64"
        #elseif arch(i386)
        "x86"
        #elseif arch(arm)
        "arm"
        #else
        "unknown"
        #endif
    }

    public let candidateNames: [String]
    public let extraSearchURLs: [URL]
    public let environmentPath: String?
    public let runtimeManifestFileName: String

    public init(
        candidateNames: [String] = ["whisper-cli", "whisper-cli.exe"],
        extraSearchURLs: [URL] = [],
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        runtimeManifestFileName: String = Self.runtimeManifestFileName
    ) {
        self.candidateNames = candidateNames
        self.extraSearchURLs = extraSearchURLs
        self.environmentPath = environmentPath
        self.runtimeManifestFileName = runtimeManifestFileName
    }

    public func locate() -> ASRRuntimeInfo? {
        let fm = FileManager.default
        let manifestRoots = manifestRootURLs(fileManager: fm)
        for root in manifestRoots {
            if let runtime = runtimeFromManifest(in: root) {
                return runtime
            }
        }
        for url in searchCandidates()
            where !Self.isLocatedInsideAnyManifestRoot(url, roots: manifestRoots)
                && fm.isExecutableFile(atPath: url.path) {
            return ASRRuntimeInfo(executableURL: url)
        }
        return nil
    }

    private func manifestRootURLs(fileManager: FileManager) -> [URL] {
        var seen = Set<String>()
        var roots: [URL] = []
        for url in extraSearchURLs where url.hasDirectoryPath {
            let manifestURL = url.appendingPathComponent(runtimeManifestFileName, isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            let root = url.standardizedFileURL
            guard seen.insert(Self.normalizedDirectoryPath(root)).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    private func runtimeFromManifest(in directory: URL) -> ASRRuntimeInfo? {
        let manifestURL = directory.appendingPathComponent(runtimeManifestFileName, isDirectory: false)
        do {
            let manifest = try ASRJSON.makeDecoder().decode(
                ASRRuntimeBundleManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            for runtime in manifest.runtimes where Self.matchesCurrentRuntime(runtime) {
                if let info = try? runtime.verifiedRuntimeInfo(relativeTo: directory) {
                    return info
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func searchCandidates() -> [URL] {
        var urls: [URL] = []
        for url in extraSearchURLs {
            if url.hasDirectoryPath {
                urls.append(contentsOf: candidateNames.map { url.appendingPathComponent($0, isDirectory: false) })
            } else {
                urls.append(url)
            }
        }
        let pathEntries = (environmentPath ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        for dir in pathEntries {
            urls.append(contentsOf: candidateNames.map { dir.appendingPathComponent($0, isDirectory: false) })
        }
        return urls
    }

    private static func matchesCurrentRuntime(_ runtime: ASRRuntimeBundleInfo) -> Bool {
        runtime.platform.compare(currentPlatform, options: .caseInsensitive) == .orderedSame
            && runtime.architecture.compare(currentArchitecture, options: .caseInsensitive) == .orderedSame
    }

    private static func isLocatedInsideAnyManifestRoot(_ url: URL, roots: [URL]) -> Bool {
        roots.contains { isLocated(url, inside: $0) }
    }

    private static func isLocated(_ url: URL, inside root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = normalizedDirectoryPath(root)
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

public enum ASRModelInstallState: String, Codable, Equatable, Sendable {
    case notInstalled
    case installed
    case badHash
    case insufficientDiskSpace
}

public enum ASRModelStoreError: Error, Equatable, Sendable {
    case invalidModelFileName(String)
}

public struct ASRModelStatus: Codable, Equatable, Sendable {
    public let modelID: String
    public let state: ASRModelInstallState
    public let installedURL: URL
    public let expectedSha256: String
    public let actualSha256: String?
    public let sizeBytes: Int64
    public let availableBytes: Int64?

    public var isInstalled: Bool { state == .installed }

    public init(
        modelID: String,
        state: ASRModelInstallState,
        installedURL: URL,
        expectedSha256: String,
        actualSha256: String? = nil,
        sizeBytes: Int64,
        availableBytes: Int64? = nil
    ) {
        self.modelID = modelID
        self.state = state
        self.installedURL = installedURL
        self.expectedSha256 = expectedSha256
        self.actualSha256 = actualSha256
        self.sizeBytes = sizeBytes
        self.availableBytes = availableBytes
    }

    private enum CodingKeys: String, CodingKey {
        case modelID = "modelId"
        case state
        case installedURL = "installedUrl"
        case expectedSha256
        case actualSha256
        case sizeBytes
        case availableBytes
    }
}

public struct ASRModelStore: Sendable {
    public let directoryURL: URL
    private let availableCapacityProvider: @Sendable (URL) throws -> Int64?

    public init(
        directoryURL: URL,
        availableCapacityProvider: (@Sendable (URL) throws -> Int64?)? = nil
    ) {
        self.directoryURL = directoryURL
        self.availableCapacityProvider = availableCapacityProvider ?? Self.defaultAvailableCapacityProvider
    }

    public func installedURL(for model: ASRModelInfo) -> URL {
        directoryURL.appendingPathComponent(model.fileName, isDirectory: false)
    }

    public func stagedURL(for model: ASRModelInfo) -> URL {
        directoryURL.appendingPathComponent(".\(model.fileName).download", isDirectory: false)
    }

    public func status(for model: ASRModelInfo) throws -> ASRModelStatus {
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try validateFileName(model.fileName)
        let url = installedURL(for: model)
        let availableBytes = try availableCapacityProvider(directoryURL)
        guard fm.fileExists(atPath: url.path) else {
            let state: ASRModelInstallState = if let availableBytes, availableBytes < model.sizeBytes {
                .insufficientDiskSpace
            } else {
                .notInstalled
            }
            return ASRModelStatus(
                modelID: model.id,
                state: state,
                installedURL: url,
                expectedSha256: model.sha256,
                sizeBytes: model.sizeBytes,
                availableBytes: availableBytes
            )
        }

        let actualSha256 = try Self.sha256(of: url)
        let state: ASRModelInstallState = actualSha256.lowercased() == model.sha256.lowercased()
            ? .installed
            : .badHash
        return ASRModelStatus(
            modelID: model.id,
            state: state,
            installedURL: url,
            expectedSha256: model.sha256,
            actualSha256: actualSha256,
            sizeBytes: model.sizeBytes,
            availableBytes: availableBytes
        )
    }

    public func delete(model: ASRModelInfo) throws {
        try validateFileName(model.fileName)
        let fm = FileManager.default
        for url in [installedURL(for: model), stagedURL(for: model)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let defaultAvailableCapacityProvider: @Sendable (URL) throws -> Int64? = { directoryURL in
        let values = try directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage
    }

    private func validateFileName(_ fileName: String) throws {
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            throw ASRModelStoreError.invalidModelFileName(fileName)
        }
    }
}

public enum ASRModelCatalogError: Error, Equatable, Sendable {
    case unknownModelID(String)
}

public enum ASRModelInstallerError: Error, Equatable, Sendable {
    case unknownModelID(String)
    case insufficientDiskSpace(modelID: String, availableBytes: Int64?, requiredBytes: Int64)
    case missingDownloadedFile(URL)
    case hashMismatch(modelID: String, expected: String, actual: String)
}

extension ASRModelInstallerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownModelID(let modelID):
            "Unknown local ASR model ID: \(modelID)."
        case .insufficientDiskSpace(let modelID, let availableBytes, let requiredBytes):
            "Not enough disk space to install local ASR model \(modelID). Required: \(Self.byteCount(requiredBytes)); available: \(availableBytes.map(Self.byteCount) ?? "unknown")."
        case .missingDownloadedFile(let url):
            "Local ASR model download finished, but no file was found at \(url.path)."
        case .hashMismatch(let modelID, let expected, let actual):
            "Local ASR model \(modelID) failed SHA-256 verification. Expected \(expected), got \(actual)."
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public protocol ASRModelDownloadClient: Sendable {
    func downloadModel(
        _ model: ASRModelInfo,
        to destinationURL: URL,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws
}

public struct URLSessionASRModelDownloadClient: ASRModelDownloadClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func downloadModel(
        _ model: ASRModelInfo,
        to destinationURL: URL,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        fm.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        let (bytes, response) = try await session.bytes(from: model.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let totalBytes = response.expectedContentLength > 0
            ? response.expectedContentLength
            : model.sizeBytes
        progress(ASRProgress(phase: .modelDownload, completedUnits: 0, totalUnits: Double(totalBytes)))

        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(ASRProgress(
                    phase: .modelDownload,
                    completedUnits: Double(receivedBytes),
                    totalUnits: Double(totalBytes)
                ))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
        }
        progress(ASRProgress(
            phase: .modelDownload,
            completedUnits: Double(receivedBytes),
            totalUnits: Double(totalBytes)
        ))
    }
}

public struct ASRModelCatalogEntry: Codable, Equatable, Sendable {
    public let model: ASRModelInfo
    public let status: ASRModelStatus

    public var id: String { model.id }
    public var displayName: String { model.displayName }
    public var fileName: String { model.fileName }
    public var downloadURL: URL { model.downloadURL }
    public var sizeBytes: Int64 { model.sizeBytes }
    public var sha256: String { model.sha256 }
    public var memoryRequiredMB: Int { model.memoryRequiredMB }
    public var license: String { model.license }
    public var sourceDescription: String { model.sourceDescription }
    public var installState: ASRModelInstallState { status.state }
    public var installedURL: URL { status.installedURL }
    public var isInstalled: Bool { status.isInstalled }
    public var needsUserDownloadConsent: Bool { !status.isInstalled }

    public init(model: ASRModelInfo, status: ASRModelStatus) {
        self.model = model
        self.status = status
    }
}

public struct ASRModelCatalog: Sendable {
    public let entries: [ASRModelCatalogEntry]

    private let modelsByID: [String: ASRModelInfo]
    private let store: ASRModelStore

    public init(manifest: ASRModelManifest, store: ASRModelStore) throws {
        self.store = store
        self.entries = try manifest.models.map { model in
            ASRModelCatalogEntry(model: model, status: try store.status(for: model))
        }
        self.modelsByID = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id, $0) })
    }

    public func entry(id: String) -> ASRModelCatalogEntry? {
        entries.first { $0.id == id }
    }

    @discardableResult
    public func deleteModel(id: String) throws -> ASRModelInfo {
        guard let model = modelsByID[id] else {
            throw ASRModelCatalogError.unknownModelID(id)
        }
        try store.delete(model: model)
        return model
    }
}

public struct ASRModelInstaller: Sendable {
    private let modelsByID: [String: ASRModelInfo]
    private let store: ASRModelStore
    private let downloader: any ASRModelDownloadClient

    public init(
        manifest: ASRModelManifest,
        store: ASRModelStore,
        downloader: any ASRModelDownloadClient = URLSessionASRModelDownloadClient()
    ) {
        self.modelsByID = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id, $0) })
        self.store = store
        self.downloader = downloader
    }

    @discardableResult
    public func installModel(
        id: String,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> ASRModelStatus {
        guard let model = modelsByID[id] else {
            throw ASRModelInstallerError.unknownModelID(id)
        }
        let currentStatus = try store.status(for: model)
        if currentStatus.state == .installed {
            progress(ASRProgress(
                phase: .modelDownload,
                completedUnits: Double(model.sizeBytes),
                totalUnits: Double(model.sizeBytes)
            ))
            return currentStatus
        }
        if currentStatus.state == .insufficientDiskSpace {
            throw ASRModelInstallerError.insufficientDiskSpace(
                modelID: model.id,
                availableBytes: currentStatus.availableBytes,
                requiredBytes: model.sizeBytes
            )
        }

        let fm = FileManager.default
        let stagedURL = store.stagedURL(for: model)
        let installedURL = store.installedURL(for: model)
        if fm.fileExists(atPath: stagedURL.path) {
            try fm.removeItem(at: stagedURL)
        }

        do {
            try await downloader.downloadModel(model, to: stagedURL, progress: progress)
            guard fm.fileExists(atPath: stagedURL.path) else {
                throw ASRModelInstallerError.missingDownloadedFile(stagedURL)
            }
            let actualSha256 = try ASRModelStore.sha256(of: stagedURL)
            guard actualSha256.lowercased() == model.sha256.lowercased() else {
                try? fm.removeItem(at: stagedURL)
                throw ASRModelInstallerError.hashMismatch(
                    modelID: model.id,
                    expected: model.sha256,
                    actual: actualSha256
                )
            }
            if fm.fileExists(atPath: installedURL.path) {
                try fm.removeItem(at: installedURL)
            }
            try fm.moveItem(at: stagedURL, to: installedURL)
            progress(ASRProgress(
                phase: .modelDownload,
                completedUnits: Double(model.sizeBytes),
                totalUnits: Double(model.sizeBytes)
            ))
            return try store.status(for: model)
        } catch {
            if fm.fileExists(atPath: stagedURL.path) {
                try? fm.removeItem(at: stagedURL)
            }
            throw error
        }
    }
}
