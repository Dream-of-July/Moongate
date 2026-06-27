import Foundation

public enum CloudASRResponseFormat: String, Codable, Sendable {
    case json
    case text
    case srt
    case verboseJSON = "verbose_json"
    case vtt
}

public enum CloudASRModelCapabilities {
    public static func supportsDirectSubtitleOutput(_ modelID: String) -> Bool {
        normalized(modelID) == "whisper-1"
    }

    public static func requiresAlignment(_ modelID: String) -> Bool {
        let value = normalized(modelID)
        return !value.isEmpty && !supportsDirectSubtitleOutput(value)
    }

    private static func normalized(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct CloudASRTranscriptionRequest: Equatable, Sendable {
    public let audioURL: URL
    public let languageCode: String?
    public let modelID: String
    public let prompt: String?
    public let responseFormat: CloudASRResponseFormat

    public init(
        audioURL: URL,
        languageCode: String? = nil,
        modelID: String,
        prompt: String? = nil,
        responseFormat: CloudASRResponseFormat = .srt
    ) {
        self.audioURL = audioURL
        self.languageCode = languageCode
        self.modelID = modelID
        self.prompt = prompt
        self.responseFormat = responseFormat
    }
}

public enum CloudASRError: Error, Equatable, Sendable {
    case missingCredential
    case missingModel
    case unsupportedSRTModel(String)
    case invalidBaseURL
    case requestFailed(statusCode: Int, message: String)
    case emptyResponse
    case missingTranscriptText
    case missingAlignmentGuide
}

public protocol CloudASRHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCloudASRHTTPTransport: CloudASRHTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudASRError.requestFailed(statusCode: -1, message: "Unexpected response")
        }
        return (data, http)
    }
}

public struct OpenAICloudASRClient: Sendable {
    public let baseURL: URL
    public let authToken: String
    public let transport: any CloudASRHTTPTransport

    public init(
        baseURL: URL,
        authToken: String,
        transport: any CloudASRHTTPTransport = URLSessionCloudASRHTTPTransport()
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.transport = transport
    }

    public func transcribeToSRT(
        _ request: CloudASRTranscriptionRequest,
        outputURL: URL
    ) async throws -> URL {
        let urlRequest = try Self.makeTranscriptionURLRequest(
            request,
            baseURL: baseURL,
            authToken: authToken
        )
        let (data, response) = try await transport.data(for: urlRequest)
        guard response.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw CloudASRError.requestFailed(statusCode: response.statusCode, message: message)
        }
        guard !data.isEmpty else { throw CloudASRError.emptyResponse }
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    public func transcribeToAlignedSRT(
        _ request: CloudASRTranscriptionRequest,
        guideSubtitleURL: URL,
        outputURL: URL
    ) async throws -> URL {
        let jsonRequest = CloudASRTranscriptionRequest(
            audioURL: request.audioURL,
            languageCode: request.languageCode,
            modelID: request.modelID,
            prompt: request.prompt,
            responseFormat: .json
        )
        let urlRequest = try Self.makeTranscriptionURLRequest(
            jsonRequest,
            baseURL: baseURL,
            authToken: authToken
        )
        let (data, response) = try await transport.data(for: urlRequest)
        guard response.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw CloudASRError.requestFailed(statusCode: response.statusCode, message: message)
        }
        guard !data.isEmpty else { throw CloudASRError.emptyResponse }
        let transcript = try Self.transcriptText(fromJSONData: data)
        let guideRaw = try String(contentsOf: guideSubtitleURL, encoding: .utf8)
        let guideCues = cleanCues(parseSubtitleCues(guideRaw, fileName: guideSubtitleURL.lastPathComponent))
        let aligned = try CloudTranscriptAligner.align(transcript: transcript, guideCues: guideCues)
        try serializeSRT(aligned).write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    public static func makeTranscriptionURLRequest(
        _ request: CloudASRTranscriptionRequest,
        baseURL: URL,
        authToken: String,
        boundary: String = "moongate-\(UUID().uuidString)"
    ) throws -> URLRequest {
        let model = request.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw CloudASRError.missingModel }
        let token = normalizedBearerToken(authToken)
        guard !token.isEmpty else { throw CloudASRError.missingCredential }
        try validateModel(model, responseFormat: request.responseFormat)

        let endpoint = try endpointURL(baseURL: baseURL, endpointPath: "/v1/audio/transcriptions")
        let audioData = try Data(contentsOf: request.audioURL)
        var body = Data()
        appendFormField(name: "model", value: model, boundary: boundary, to: &body)
        appendFormField(name: "response_format", value: request.responseFormat.rawValue, boundary: boundary, to: &body)
        if let language = normalizedOptional(request.languageCode) {
            appendFormField(name: "language", value: language, boundary: boundary, to: &body)
        }
        if let prompt = normalizedOptional(request.prompt) {
            appendFormField(name: "prompt", value: prompt, boundary: boundary, to: &body)
        }
        appendFileField(
            name: "file",
            filename: request.audioURL.lastPathComponent,
            data: audioData,
            boundary: boundary,
            to: &body
        )
        body.appendString("--\(boundary)--\r\n")

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        return urlRequest
    }

    private static func validateModel(_ model: String, responseFormat: CloudASRResponseFormat) throws {
        guard responseFormat == .srt || responseFormat == .vtt else { return }
        if CloudASRModelCapabilities.supportsDirectSubtitleOutput(model) { return }
        throw CloudASRError.unsupportedSRTModel(model)
    }

    private static func transcriptText(fromJSONData data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(CloudASRJSONTranscript.self, from: data)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CloudASRError.missingTranscriptText }
        return text
    }

    private static func endpointURL(baseURL: URL, endpointPath: String) throws -> URL {
        let trimmedEndpoint = endpointPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        guard components?.scheme != nil, components?.host != nil else {
            throw CloudASRError.invalidBaseURL
        }
        let existingPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let path: String
        if existingPath.isEmpty {
            path = trimmedEndpoint
        } else if trimmedEndpoint.hasPrefix(existingPath + "/") {
            path = trimmedEndpoint
        } else {
            path = [existingPath, trimmedEndpoint].joined(separator: "/")
        }
        components?.path = "/" + path
        guard let url = components?.url else { throw CloudASRError.invalidBaseURL }
        return url
    }

    private static func normalizedBearerToken(_ raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return token
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func appendFormField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString(value)
        body.appendString("\r\n")
    }

    private static func appendFileField(
        name: String,
        filename: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        body.appendString("\r\n")
    }
}

private struct CloudASRJSONTranscript: Decodable {
    let text: String
}

public enum CloudTranscriptAligner {
    public static func align(transcript: String, guideCues: [SubtitleCue]) throws -> [SubtitleCue] {
        let normalizedTranscript = collapseWhitespace(transcript)
        guard !normalizedTranscript.isEmpty else { throw CloudASRError.missingTranscriptText }
        let guide = guideCues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !guide.isEmpty else { throw CloudASRError.missingAlignmentGuide }

        let joinWithoutSpaces = prefersCharacterUnits(normalizedTranscript)
        let units = transcriptUnits(normalizedTranscript, characterMode: joinWithoutSpaces)
        guard !units.isEmpty else { throw CloudASRError.missingTranscriptText }

        let weights = guide.map { max(1, timingUnitCount($0.text, characterMode: joinWithoutSpaces)) }
        let totalWeight = max(1, weights.reduce(0, +))
        var cursor = 0
        var produced: [SubtitleCue] = []
        produced.reserveCapacity(guide.count)

        for (offset, cue) in guide.enumerated() {
            let remainingCues = guide.count - offset
            let remainingUnits = units.count - cursor
            guard remainingUnits > 0 else { break }
            let targetCount: Int
            if offset == guide.count - 1 {
                targetCount = remainingUnits
            } else {
                let proportional = Int((Double(units.count) * Double(weights[offset]) / Double(totalWeight)).rounded())
                targetCount = min(max(1, proportional), max(1, remainingUnits - (remainingCues - 1)))
            }
            let end = min(units.count, cursor + targetCount)
            let text = joinUnits(Array(units[cursor..<end]), withoutSpaces: joinWithoutSpaces)
            produced.append(SubtitleCue(
                index: produced.count + 1,
                start: cue.start,
                end: cue.end,
                text: text,
                sourceFragments: cue.sourceFragments
            ))
            cursor = end
        }

        if cursor < units.count, let last = produced.indices.last {
            let tail = joinUnits(Array(units[cursor...]), withoutSpaces: joinWithoutSpaces)
            let existing = produced[last].text
            produced[last].text = joinUnits([existing, tail], withoutSpaces: joinWithoutSpaces)
        }
        return produced
    }

    private static func transcriptUnits(_ text: String, characterMode: Bool) -> [String] {
        if characterMode {
            return text
                .filter { !$0.isWhitespace }
                .map(String.init)
        }
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func timingUnitCount(_ text: String, characterMode: Bool) -> Int {
        transcriptUnits(collapseWhitespace(text), characterMode: characterMode).count
    }

    private static func joinUnits(_ units: [String], withoutSpaces: Bool) -> String {
        withoutSpaces ? units.joined() : units.joined(separator: " ")
    }

    private static func prefersCharacterUnits(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return false }
        let cjk = scalars.filter { scalar in
            let value = scalar.value
            return (0x3040...0x30FF).contains(value)
                || (0x3400...0x9FFF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
        }
        return Double(cjk.count) / Double(scalars.count) >= 0.35
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct GeneratedCloudASRSource: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}

public protocol CloudASRSubtitleGenerator: Sendable {
    func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata?,
        control: TaskControlToken?
    ) async throws -> GeneratedCloudASRSource
}

public struct OpenAICloudASRSubtitleGenerator: CloudASRSubtitleGenerator {
    public let client: OpenAICloudASRClient
    public let modelID: String

    public init(client: OpenAICloudASRClient, modelID: String) {
        self.client = client
        self.modelID = modelID
    }

    public func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata?,
        control: TaskControlToken?
    ) async throws -> GeneratedCloudASRSource {
        try Task.checkCancellation()
        try await control?.gate()
        let normalizedLanguage = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognitionProfile = ASRPromptBuilder.recognitionProfile(
            videoURL: videoFile,
            languageCode: normalizedLanguage
        )
        let prompt = ASRPromptBuilder.defaultPrompt(
            videoURL: videoFile,
            languageCode: normalizedLanguage,
            recognitionProfile: recognitionProfile,
            metadata: promptMetadata
        )
        let outputURL = try Self.outputURL(for: videoFile, languageCode: normalizedLanguage)
        let request = CloudASRTranscriptionRequest(
            audioURL: videoFile,
            languageCode: normalizedLanguage.lowercased() == "auto" ? nil : normalizedLanguage,
            modelID: modelID,
            prompt: prompt,
            responseFormat: .srt
        )
        let url = try await client.transcribeToSRT(request, outputURL: outputURL)
        try Task.checkCancellation()
        try await control?.gate()
        return GeneratedCloudASRSource(url: url)
    }

    fileprivate static func outputURL(for videoFile: URL, languageCode: String) throws -> URL {
        let directory = videoFile.deletingLastPathComponent()
        let language = sanitizedLanguageCode(languageCode)
        let base = videoFile.deletingPathExtension().lastPathComponent
        let stem = "\(base).cloud-asr.\(language)"
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension("srt")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(index)").appendingPathExtension("srt")
            index += 1
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return candidate
    }

    private static func sanitizedLanguageCode(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "auto" : trimmed
        let mapped = source.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        return String(mapped).lowercased()
    }
}

public struct AlignedOpenAICloudASRSubtitleGenerator: CloudASRSubtitleGenerator {
    public let client: OpenAICloudASRClient
    public let modelID: String
    public let timingGuideGenerator: any LocalASRSubtitleGenerator

    public init(
        client: OpenAICloudASRClient,
        modelID: String,
        timingGuideGenerator: any LocalASRSubtitleGenerator
    ) {
        self.client = client
        self.modelID = modelID
        self.timingGuideGenerator = timingGuideGenerator
    }

    public func generateSourceSubtitle(
        videoFile: URL,
        languageCode: String,
        promptMetadata: ASRPromptMetadata?,
        control: TaskControlToken?
    ) async throws -> GeneratedCloudASRSource {
        try Task.checkCancellation()
        try await control?.gate()
        let normalizedLanguage = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let guide = try await timingGuideGenerator.generateSourceSubtitle(
            videoFile: videoFile,
            languageCode: normalizedLanguage,
            promptMetadata: promptMetadata,
            control: control,
            progress: { _ in }
        )
        if guide.confidence?.hasSevereQualityBlocker == true {
            throw CloudASRError.missingAlignmentGuide
        }
        let recognitionProfile = ASRPromptBuilder.recognitionProfile(
            videoURL: videoFile,
            languageCode: normalizedLanguage
        )
        let prompt = ASRPromptBuilder.defaultPrompt(
            videoURL: videoFile,
            languageCode: normalizedLanguage,
            recognitionProfile: recognitionProfile,
            metadata: promptMetadata
        )
        let outputURL = try OpenAICloudASRSubtitleGenerator.outputURL(for: videoFile, languageCode: normalizedLanguage)
        let request = CloudASRTranscriptionRequest(
            audioURL: videoFile,
            languageCode: normalizedLanguage.lowercased() == "auto" ? nil : normalizedLanguage,
            modelID: modelID,
            prompt: prompt,
            responseFormat: .json
        )
        let url = try await client.transcribeToAlignedSRT(
            request,
            guideSubtitleURL: guide.url,
            outputURL: outputURL
        )
        try Task.checkCancellation()
        try await control?.gate()
        return GeneratedCloudASRSource(url: url)
    }
}

public enum CloudASRGeneratorFactory {
    public static func make(
        settings: AppSettings,
        localASRGenerator: (any LocalASRSubtitleGenerator)? = nil
    ) -> (any CloudASRSubtitleGenerator)? {
        guard settings.cloudASREnabled, settings.cloudASRConsentAccepted else { return nil }
        let base = settings.cloudASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.cloudASRModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.cloudASRAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base), !model.isEmpty, !token.isEmpty else { return nil }
        let client = OpenAICloudASRClient(baseURL: baseURL, authToken: token)
        if CloudASRModelCapabilities.requiresAlignment(model) {
            guard let localASRGenerator else { return nil }
            return AlignedOpenAICloudASRSubtitleGenerator(
                client: client,
                modelID: model,
                timingGuideGenerator: localASRGenerator
            )
        }
        guard CloudASRModelCapabilities.supportsDirectSubtitleOutput(model) else { return nil }
        return OpenAICloudASRSubtitleGenerator(
            client: client,
            modelID: model
        )
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}
