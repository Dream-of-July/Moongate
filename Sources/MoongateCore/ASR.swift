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

public struct ASRRequest: Codable, Equatable, Sendable {
    public let audioURL: URL
    public let languageCode: String?
    public let modelID: String
    public let prompt: String?
    public let vadEnabled: Bool
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
        vadEnabled: Bool = true,
        wordTimestamps: Bool = true,
        dtwTokenTimestamps: Bool = true,
        cacheKey: String? = nil
    ) {
        self.audioURL = audioURL
        self.languageCode = languageCode
        self.modelID = modelID
        self.prompt = prompt
        self.vadEnabled = vadEnabled
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
        case vadEnabled
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
        self.vadEnabled = try container.decodeIfPresent(Bool.self, forKey: .vadEnabled) ?? true
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
        try container.encode(vadEnabled, forKey: .vadEnabled)
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
            vadEnabled: vadEnabled,
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

public struct ASRTranscript: Codable, Equatable, Sendable {
    public let id: String
    public let languageCode: String
    public let languageConfidence: Double?
    public let durationSeconds: Double?
    public let words: [ASRWord]
    public let sourceModelID: String
    public let createdAt: Date

    public init(
        id: String,
        languageCode: String,
        languageConfidence: Double? = nil,
        durationSeconds: Double? = nil,
        words: [ASRWord],
        sourceModelID: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.languageCode = languageCode
        self.languageConfidence = languageConfidence
        self.durationSeconds = durationSeconds
        self.words = words
        self.sourceModelID = sourceModelID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case languageCode
        case languageConfidence
        case durationSeconds
        case words
        case sourceModelID = "sourceModelId"
        case createdAt
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
    public let languageCode: String?
    public let transcriptURL: URL
    public let createdAt: Date

    public init(
        cacheKey: String,
        audioFingerprint: String,
        modelID: String,
        languageCode: String? = nil,
        transcriptURL: URL,
        createdAt: Date = Date()
    ) {
        self.cacheKey = cacheKey
        self.audioFingerprint = audioFingerprint
        self.modelID = modelID
        self.languageCode = languageCode
        self.transcriptURL = transcriptURL
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case cacheKey
        case audioFingerprint
        case modelID = "modelId"
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
    public static func sourceFragments(from transcript: ASRTranscript) -> [SubtitleCueSourceFragment] {
        transcript.words.compactMap { word in
            let text = LocalASRSubtitleTimingPlanner.cleanedSpeechText(word.text)
            guard !text.isEmpty,
                  word.startSeconds.isFinite,
                  word.endSeconds.isFinite,
                  word.startSeconds >= 0,
                  word.endSeconds >= word.startSeconds else {
                return nil
            }
            return SubtitleCueSourceFragment(
                startSeconds: word.startSeconds,
                endSeconds: word.endSeconds,
                text: text
            )
        }
    }

    public static func sourceCues(from transcript: ASRTranscript) -> [SubtitleCue] {
        let planned = LocalASRSubtitleTimingPlanner.planCues(
            from: sourceFragments(from: transcript),
            transcriptDurationSeconds: transcript.durationSeconds
        )
        // Whisper-specific re-timing pass: pulls late onsets earlier, holds cues to just
        // before the next real onset, and guarantees no overlap. Separate from the platform
        // (YouTube auto-caption) timing path, which keeps human-aligned source anchors.
        return WhisperCueRetimer.retime(planned, transcriptDurationSeconds: transcript.durationSeconds)
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
        videoURL: URL
    ) throws -> URL {
        let cues = sourceCues(from: transcript)
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

enum LocalASRSubtitleTimingPlanner {
    static let minimumCueSeconds = 0.3
    private static let sentenceTailSeconds = 0.45
    private static let phraseTailSeconds = 0.2
    static let maximumCJKCueSeconds = 4.5
    static let hardMaximumCJKCueSeconds = 5.5
    static let maximumLatinCueSeconds = SubtitleTimingPlanner.normalReadableCueSeconds
    private static let maximumCJKUnits = 18
    private static let hardMaximumCJKUnits = 28
    private static let maximumLatinTokens = 14
    private static let largeSpeechGapSeconds = 0.65

    /// Japanese kana / punctuation that must not START a subtitle line (particles, small kana,
    /// long-vowel mark, closing punctuation). Breaking right before one of these produces the
    /// unnatural "leading-が / lone-ね" splits whisper's token stream otherwise yields.
    private static let cjkLeadingProhibited: Set<Character> = [
        "を", "が", "は", "に", "へ", "と", "で", "も", "の", "ね", "よ", "さ", "わ", "ぞ", "ぜ", "ん",
        "っ", "ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゎ", "ー", "〜",
        "、", "。", "，", "．", "・", "！", "？", "」", "』", "）", "”", "’"
    ]

    /// A cue with at most this many visible characters is too short to stand alone (e.g. 「顔」,
    /// 「ね」, a lone 「えらい」) and is merged into the temporally-closest neighbour.
    private static let loneMergeMaxVisibleChars = 3
    /// Only merge a lone short cue into a neighbour within this gap (same utterance), so merging
    /// never drags a word across a long pause (which would make it appear early).
    private static let loneMergeMaxGapSeconds = 1.0

    /// Merge lone, too-short groups into the neighbour they are closest to in time. whisper splits
    /// off single morphemes (especially before/after its own timing gaps); without this they become
    /// jarring 1-character cues like 「顔」 separated from 「洗って」.
    private static func mergeShortGroups(
        _ groups: [[SubtitleCueSourceFragment]]
    ) -> [[SubtitleCueSourceFragment]] {
        guard groups.count > 1 else { return groups }
        var result: [[SubtitleCueSourceFragment]] = []
        var index = 0
        while index < groups.count {
            let group = groups[index]
            let text = joinedText(group)
            let isShort = SubtitleTimingPlanner.visibleCharacters(text) <= loneMergeMaxVisibleChars && !endsSentence(text)
            if isShort {
                let gapPrev = result.last.map { group.first!.startSeconds - $0.last!.endSeconds }
                    ?? Double.greatestFiniteMagnitude
                let nextGroup = index + 1 < groups.count ? groups[index + 1] : nil
                let gapNext = nextGroup.map { $0.first!.startSeconds - group.last!.endSeconds }
                    ?? Double.greatestFiniteMagnitude
                // Prefer the smaller-gap side; only merge within the same-utterance gap and cue cap.
                if gapPrev <= gapNext, gapPrev <= loneMergeMaxGapSeconds,
                   let previous = result.last, fitsMergedCue(previous + group) {
                    result[result.count - 1] = previous + group
                    index += 1
                    continue
                }
                if gapNext < gapPrev, gapNext <= loneMergeMaxGapSeconds,
                   let nextGroup, fitsMergedCue(group + nextGroup) {
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

    private static func fitsMergedCue(_ fragments: [SubtitleCueSourceFragment]) -> Bool {
        guard let first = fragments.first, let last = fragments.last else { return false }
        let text = joinedText(fragments)
        let duration = last.endSeconds - first.startSeconds
        if containsCJK(text) {
            return duration <= hardMaximumCJKCueSeconds
                && SubtitleTimingPlanner.timingTokens(text).count <= hardMaximumCJKUnits
        }
        return duration <= maximumLatinCueSeconds
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
        transcriptDurationSeconds: Double?
    ) -> [SubtitleCue] {
        let ordered = fragments
            .filter { shouldKeep($0) }
            .sorted { $0.startSeconds == $1.startSeconds ? $0.endSeconds < $1.endSeconds : $0.startSeconds < $1.startSeconds }
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
                if shouldBreak(before: fragment, current: current, candidate: candidate, gap: gap) {
                    flushCurrent()
                }
            }
            current.append(fragment)
            if endsSentence(fragment.text) {
                flushCurrent()
            }
        }
        flushCurrent()
        groups = mergeShortGroups(groups)

        var cues: [SubtitleCue] = []
        for group in groups {
            guard let cue = makeCue(
                index: cues.count + 1,
                fragments: group,
                transcriptDurationSeconds: transcriptDurationSeconds
            ) else { continue }
            cues.append(cue)
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

    private static func shouldKeep(_ fragment: SubtitleCueSourceFragment) -> Bool {
        guard !fragment.text.isEmpty else { return false }
        guard fragment.endSeconds >= fragment.startSeconds else { return false }
        // Drop no-speech fragments (a lone "?", "...", "♪" etc.) outright — they carry no readable
        // content and otherwise become standalone cues that linger to the cue cap.
        if isPurePunctuation(fragment.text) { return false }
        return true
    }

    private static func shouldBreak(
        before next: SubtitleCueSourceFragment,
        current: [SubtitleCueSourceFragment],
        candidate: [SubtitleCueSourceFragment],
        gap: Double
    ) -> Bool {
        guard let first = current.first, let last = current.last else { return false }
        if gap > largeSpeechGapSeconds { return true }

        let candidateText = joinedText(candidate)
        let candidateDuration = next.endSeconds - first.startSeconds
        if containsCJK(candidateText) {
            let units = SubtitleTimingPlanner.timingTokens(candidateText).count
            // Hard ceilings always break.
            if candidateDuration > hardMaximumCJKCueSeconds { return true }
            if units > hardMaximumCJKUnits { return true }
            // Soft ceilings break only at a natural boundary: never split mid-word (morphological
            // word boundary via NaturalLanguage), and never right before a leading particle / small
            // kana / closing punctuation. Otherwise extend to the hard ceiling, so words like
            // 「いこう」「カード」「たくさん」 stay whole and 「だ|よ」/ lone 「ね」 tails stay attached.
            if candidateDuration > maximumCJKCueSeconds || units > maximumCJKUnits {
                let junction = joinedText(current).count
                let midWord = CJKWordBoundary.straddles(candidateText, at: junction)
                return !(midWord || hasWeakBoundary(left: last.text, right: next.text))
            }
            return false
        }

        if candidateDuration > maximumLatinCueSeconds { return true }
        if SubtitleTimingPlanner.speechTokens(candidateText).count > maximumLatinTokens,
           !hasWeakBoundary(left: last.text, right: next.text) {
            return true
        }
        return false
    }

    private static func makeCue(
        index: Int,
        fragments: [SubtitleCueSourceFragment],
        transcriptDurationSeconds: Double?
    ) -> SubtitleCue? {
        guard let first = fragments.first, let last = fragments.last else { return nil }
        let text = joinedText(fragments)
        guard !text.isEmpty else { return nil }

        let start = first.startSeconds
        var end = last.endSeconds + (endsSentence(text) ? sentenceTailSeconds : phraseTailSeconds)
        if let transcriptDurationSeconds {
            end = min(end, transcriptDurationSeconds)
        }
        end = min(end, start + (containsCJK(text) ? hardMaximumCJKCueSeconds : maximumLatinCueSeconds))
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
        let parts = fragments.map(\.text)
        let separator = parts.contains(where: containsCJK) ? "" : " "
        return parts.joined(separator: separator)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsCJK(_ text: String) -> Bool {
        SubtitleTimingPlanner.containsCJKText(text)
    }

    private static func hasWeakBoundary(left: String, right: String) -> Bool {
        // CJK: never break right before a leading particle / small kana / closing punctuation.
        if let firstChar = right.trimmingCharacters(in: .whitespacesAndNewlines).first,
           cjkLeadingProhibited.contains(firstChar) {
            return true
        }
        let leftTokens = SubtitleTimingPlanner.wordTokens(left)
        let rightTokens = SubtitleTimingPlanner.wordTokens(right)
        guard let last = leftTokens.last, let first = rightTokens.first else { return false }
        return SubtitleTimingPlanner.isWeakBoundary(leftToken: last, rightToken: first)
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
    /// Gap kept before the next cue's onset so adjacent cues never overlap.
    public static let interCueGuardSeconds = 0.08
    /// Maximum extra hold past the last spoken token. whisper ends words noticeably earlier
    /// than human captions, so holding toward the next onset cuts the dominant early-cutoff
    /// failures; capped so a long pause never produces a long idle hold.
    public static let holdToNextSeconds = 0.7
    private static let minimumCueSeconds = LocalASRSubtitleTimingPlanner.minimumCueSeconds
    private static let epsilon = 0.001

    private struct RawCue {
        let start: Double
        let end: Double
        let lastTokenEnd: Double
        let text: String
        let fragments: [SubtitleCueSourceFragment]
        let cap: Double
    }

    public static func retime(_ cues: [SubtitleCue], transcriptDurationSeconds: Double?) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        var raws: [RawCue] = []
        raws.reserveCapacity(cues.count)
        for cue in cues {
            guard let start = srtTimeToSeconds(cue.start), let end = srtTimeToSeconds(cue.end) else {
                return cues // unparseable input: leave untouched rather than corrupt timing
            }
            let cap = SubtitleTimingPlanner.containsCJKText(cue.text)
                ? LocalASRSubtitleTimingPlanner.hardMaximumCJKCueSeconds
                : LocalASRSubtitleTimingPlanner.maximumLatinCueSeconds
            raws.append(RawCue(
                start: start,
                end: end,
                lastTokenEnd: cue.sourceFragments.last?.endSeconds ?? end,
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
            var start = raw.start + onsetDelaySeconds
            start = min(start, max(raw.start, raw.end - minimumCueSeconds))
            if index > 0 { start = max(start, previousEnd) }
            start = max(start, 0)

            // Disappearance: extend the cue toward the next real onset to absorb whisper's early
            // word ends, capped at holdToNextSeconds past the last token (so a long pause cannot
            // produce a long idle hold) and at the next onset minus a guard (so cues never overlap).
            let ceiling = hasNext ? nextStart - interCueGuardSeconds : Double.greatestFiniteMagnitude
            var end = max(raw.end, min(ceiling, raw.lastTokenEnd + holdToNextSeconds))
            if let duration = transcriptDurationSeconds { end = min(end, duration) }
            end = min(end, start + raw.cap)
            end = max(end, start + minimumCueSeconds) // minimum readable duration (before overlap clamp)
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
}

public protocol LocalASRSubtitleGenerator: Sendable {
    func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> URL
}

public enum ASRPromptBuilder {
    public static func defaultPrompt(videoURL: URL, languageCode: String) -> String? {
        let title = videoURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !title.isEmpty {
            parts.append("title=\(title)")
        }
        if !language.isEmpty, language.lowercased() != "auto" {
            parts.append("language=\(language)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
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

public protocol ASRAudioExtractor: Sendable {
    func extractAudio(
        plan: ASRAudioExtractionPlan,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> URL
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

public struct WhisperCppLocalASRSubtitleGenerator: LocalASRSubtitleGenerator {
    public typealias PromptProvider = @Sendable (URL, String) -> String?

    public let ffmpegURL: URL
    public let workDirectoryURL: URL
    public let modelID: String

    private let recognizer: any SpeechRecognizer
    private let promptProvider: PromptProvider?
    private let audioExtractor: any ASRAudioExtractor

    public init(
        ffmpegURL: URL,
        workDirectoryURL: URL,
        recognizer: any SpeechRecognizer,
        modelID: String,
        promptProvider: PromptProvider? = nil,
        audioExtractor: any ASRAudioExtractor = ProcessASRAudioExtractor()
    ) {
        self.ffmpegURL = ffmpegURL
        self.workDirectoryURL = workDirectoryURL
        self.recognizer = recognizer
        self.modelID = modelID
        self.promptProvider = promptProvider
        self.audioExtractor = audioExtractor
    }

    public func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        control: TaskControlToken?,
        progress: @escaping @Sendable (ASRProgress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        try await control?.gate()
        try FileManager.default.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)

        let prompt = promptProvider?(videoFile, languageCode)
        let audioURL = audioURL(for: videoFile, languageCode: languageCode)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            progress(ASRProgress(phase: .audioExtract, completedUnits: 1, totalUnits: 1))
        } else {
            let plan = ASRAudioExtractionPlan(ffmpegURL: ffmpegURL, inputURL: videoFile, outputURL: audioURL)
            _ = try await audioExtractor.extractAudio(plan: plan, control: control, progress: progress)
        }

        let request = ASRRequest(
            audioURL: audioURL,
            languageCode: languageCode,
            modelID: modelID,
            prompt: prompt,
            vadEnabled: true,
            wordTimestamps: true,
            cacheKey: cacheKey(for: videoFile, languageCode: languageCode, prompt: prompt)
        )
        let transcript = try await recognizer.transcribe(request, control: control, progress: progress)
        progress(ASRProgress(phase: .subtitleSegment, completedUnits: 0, totalUnits: 1))
        let outputURL = try ASRTranscriptMapper.writeLocalASRSourceSRT(transcript: transcript, videoURL: videoFile)
        progress(ASRProgress(phase: .subtitleSegment, completedUnits: 1, totalUnits: 1))
        return outputURL
    }

    private func audioURL(for videoFile: URL, languageCode: String) -> URL {
        workDirectoryURL
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(stableFileStem(audioSeed(videoFile: videoFile, languageCode: languageCode))).wav", isDirectory: false)
    }

    private func cacheKey(for videoFile: URL, languageCode: String, prompt: String?) -> String {
        "local-asr:\(stableFileStem("\(audioSeed(videoFile: videoFile, languageCode: languageCode))\n\(prompt ?? "")"))"
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
            promptProvider: { videoURL, languageCode in
                ASRPromptBuilder.defaultPrompt(videoURL: videoURL, languageCode: languageCode)
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
    public let arguments: [String]

    public var executableURL: URL { runtime.executableURL }

    public var outputJSONURL: URL {
        outputBaseURL.deletingPathExtension().appendingPathExtension("json")
    }

    public init(
        runtime: ASRRuntimeInfo,
        modelURL: URL,
        request: ASRRequest,
        outputBaseURL: URL
    ) {
        self.runtime = runtime
        self.modelURL = modelURL
        self.request = request
        self.outputBaseURL = outputBaseURL.deletingPathExtension()
        var arguments = [
            "-m", modelURL.path,
            "-f", request.audioURL.path,
            request.wordTimestamps ? "-ojf" : "-oj",
            "-of", self.outputBaseURL.path,
            "-pp"
        ]
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
        guard let range = line.range(
            of: #"([0-9]+(?:\.[0-9]+)?)\s*%"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let token = String(line[range])
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(token), value.isFinite else { return nil }
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
        var dtwStarts: [Double?] = []
        var maxEnd: Double?

        for segment in segments {
            if let interval = interval(in: segment, offsetValuesAreMilliseconds: true) {
                maxEnd = max(maxEnd ?? interval.end, interval.end)
            }
            let tokenEntries = parseTokenEntries(in: segment)
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

    private func parseTokenEntries(in segment: [String: Any]) -> [(word: ASRWord, dtwStart: Double?)] {
        let tokens = (segment["tokens"] as? [[String: Any]])
            ?? (segment["words"] as? [[String: Any]])
            ?? []
        return tokens.compactMap { token in
            guard let text = cleanText(token["text"] as? String),
                  let interval = interval(in: token, offsetValuesAreMilliseconds: true) else {
                return nil
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
            return (word, dtwStart)
        }
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
                languageCode: request.languageCode
           ) {
            progress(ASRProgress(phase: .speechRecognition, completedUnits: 1, totalUnits: 1))
            return cached
        }

        try fm.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        let transcriptID = request.cacheKey ?? UUID().uuidString
        let outputBaseURL = outputDirectoryURL.appendingPathComponent(Self.stableFileStem(transcriptID), isDirectory: false)

        func run(_ planRequest: ASRRequest) async throws -> (plan: WhisperCppCommandPlan, result: ASRCommandResult) {
            let plan = WhisperCppCommandPlan(
                runtime: runtime,
                modelURL: modelURL,
                request: planRequest,
                outputBaseURL: outputBaseURL
            )
            let result = try await commandRunner.runWhisper(plan: plan, control: control) { line in
                if let parsed = ASRProgressLineParser.whisperCppProgress(from: line) {
                    progress(parsed)
                }
            }
            try Task.checkCancellation()
            return (plan, result)
        }

        var (plan, result) = try await run(request)
        let usedDTW = request.wordTimestamps
            && request.dtwTokenTimestamps
            && WhisperDTWPreset.preset(forModelID: request.modelID) != nil
        if usedDTW, result.status != 0 || !fm.fileExists(atPath: plan.outputJSONURL.path) {
            // Fail-safe: if a model build rejects `-dtw`/`-nfa`, retry once without it so a DTW
            // incompatibility degrades to plain offsets instead of failing the whole run.
            (plan, result) = try await run(request.disablingDTW())
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
        languageCode: String?
    ) throws -> ASRTranscript? {
        let requestedLanguageCode = Self.normalizedCacheLanguage(languageCode)
        guard let entry = try readEntry(cacheKey: cacheKey),
              entry.audioFingerprint == audioFingerprint,
              entry.modelID == modelID,
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
