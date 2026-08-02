import Foundation

extension Notification.Name {
    static let geminiAPIKeyChanged = Notification.Name("geminiAPIKeyChanged")
}

enum GeminiKeychain {
    private static let account = "gemini-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .geminiAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .geminiAPIKeyChanged, object: nil)
    }
}

enum GeminiOmniAPI {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Part: Equatable, Sendable {
        case text(String)
        case inlineImage(data: Data, mime: String)
        case videoFile(uri: String)
    }

    struct Request: Equatable, Sendable {
        let parts: [Part]
        let task: String?
        let responseType: String
        let aspectRatio: String?
        let uriDelivery: Bool
    }

    static let model = "gemini-omni-flash-preview"
    static let imageModel = "gemini-3.1-flash-image"
    private static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    private static let uploadURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
    private static let requestTimeout: TimeInterval = 180
    private static let interactionRequestTimeout: TimeInterval = 1800
    private static let pollInterval: Duration = .seconds(5)
    private static let jobTimeout: Duration = .seconds(1800)

    static func body(for request: Request) -> [String: Any] {
        var body: [String: Any] = ["model": model]
        if request.parts.count == 1, case .text(let text) = request.parts[0] {
            body["input"] = text
        } else {
            body["input"] = request.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text):
                    ["type": "text", "text": text]
                case .inlineImage(let data, let mime):
                    ["type": "image", "data": data.base64EncodedString(), "mime_type": mime]
                case .videoFile(let uri):
                    ["type": "video", "uri": uri]
                }
            }
        }
        var responseFormat: [String: Any] = ["type": request.responseType]
        if let aspectRatio = request.aspectRatio, !aspectRatio.isEmpty {
            responseFormat["aspect_ratio"] = aspectRatio
        }
        if request.uriDelivery {
            responseFormat["delivery"] = "uri"
        }
        body["response_format"] = responseFormat
        if let task = request.task {
            body["generation_config"] = ["video_config": ["task": task]]
        }
        return body
    }

    @concurrent
    static func run(_ request: Request, apiKey: String) async throws -> [URL] {
        var interaction = try await decode(
            Interaction.self,
            from: urlRequest(
                url: baseURL.appending(path: "interactions"),
                method: "POST",
                body: body(for: request),
                apiKey: apiKey,
                timeout: interactionRequestTimeout
            )
        )

        let deadline = ContinuousClock.now + jobTimeout
        while !interaction.isTerminal {
            try Task.checkCancellation()
            guard let id = interaction.id else {
                throw APIError(message: "Google returned an unexpected response.")
            }
            guard ContinuousClock.now < deadline else {
                throw APIError(message: "Gemini Omni generation timed out.")
            }
            try await Task.sleep(for: pollInterval)
            interaction = try await decode(
                Interaction.self,
                from: urlRequest(url: baseURL.appending(path: "interactions/\(id)"), apiKey: apiKey)
            )
        }

        if interaction.status == "failed" {
            throw APIError(message: interaction.error?.message ?? "Gemini Omni generation failed.")
        }

        let outputs = interaction.outputParts
        guard !outputs.isEmpty else {
            throw APIError(message: "Gemini Omni returned no media.")
        }

        var files: [URL] = []
        for part in outputs {
            if let base64 = part.data, let bytes = Data(base64Encoded: base64) {
                files.append(try writeTemporaryFile(bytes, extension: fileExtension(forMime: part.mime_type)))
            } else if let uri = part.uri {
                files.append(try await downloadOutput(uri: uri, mime: part.mime_type, apiKey: apiKey))
            }
        }
        guard !files.isEmpty else {
            throw APIError(message: "Gemini Omni returned no media.")
        }
        return files
    }

    static func generateContentBody(prompt: String, imageParts: [Part]) -> [String: Any] {
        var parts: [[String: Any]] = imageParts.compactMap { part in
            guard case .inlineImage(let data, let mime) = part else { return nil }
            return ["inline_data": ["mime_type": mime, "data": data.base64EncodedString()]]
        }
        parts.append(["text": prompt])
        return ["contents": [["parts": parts]]]
    }

    @concurrent
    static func generateImage(prompt: String, imageParts: [Part], apiKey: String) async throws -> [URL] {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct ResponsePart: Decodable {
                        struct InlineData: Decodable {
                            let mimeType: String?
                            let data: String?
                        }
                        let inlineData: InlineData?
                    }
                    let parts: [ResponsePart]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        let response = try await decode(
            Response.self,
            from: urlRequest(
                url: baseURL.appending(path: "models/\(imageModel):generateContent"),
                method: "POST",
                body: generateContentBody(prompt: prompt, imageParts: imageParts),
                apiKey: apiKey
            )
        )
        let files = try (response.candidates ?? [])
            .flatMap { $0.content?.parts ?? [] }
            .compactMap { part -> URL? in
                guard let inline = part.inlineData,
                      let base64 = inline.data,
                      let bytes = Data(base64Encoded: base64) else { return nil }
                return try writeTemporaryFile(bytes, extension: fileExtension(forMime: inline.mimeType))
            }
        guard !files.isEmpty else {
            throw APIError(message: "Gemini returned no image.")
        }
        return files
    }

    @concurrent
    static func uploadFile(fileURL: URL, mimeType: String, apiKey: String) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        var start = URLRequest(url: keyed(uploadURL, apiKey: apiKey), timeoutInterval: requestTimeout)
        start.httpMethod = "POST"
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(size)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": fileURL.lastPathComponent]]
        )
        let (_, startResponse) = try await URLSession.shared.data(for: start)
        guard let http = startResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let sessionURLString = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let sessionURL = URL(string: sessionURLString) else {
            throw APIError(message: "Google file upload could not start.")
        }

        var upload = URLRequest(url: sessionURL, timeoutInterval: interactionRequestTimeout)
        upload.httpMethod = "POST"
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        let (uploadData, uploadResponse) = try await URLSession.shared.upload(for: upload, fromFile: fileURL)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
              (200..<300).contains(uploadHTTP.statusCode) else {
            let status = (uploadResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError(message: errorMessage(uploadData, status: status))
        }
        guard let uploaded = try? JSONDecoder().decode(FileEnvelope.self, from: uploadData).resolved else {
            throw APIError(message: "Google returned an unexpected upload response.")
        }

        let active = try await awaitActiveFile(named: uploaded.name, initial: uploaded, apiKey: apiKey)
        return active.uri ?? uploaded.uri ?? ""
    }

    private static func awaitActiveFile(
        named name: String,
        initial: FileResource,
        apiKey: String
    ) async throws -> FileResource {
        var file = initial
        let deadline = ContinuousClock.now + jobTimeout
        while file.state == "PROCESSING" {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw APIError(message: "Google file processing timed out.")
            }
            try await Task.sleep(for: pollInterval)
            file = try await decode(
                FileEnvelope.self,
                from: urlRequest(url: baseURL.appending(path: name), apiKey: apiKey)
            ).resolved
        }
        guard file.state != "FAILED" else {
            throw APIError(message: "Google could not process the uploaded file.")
        }
        return file
    }

    private static func downloadOutput(uri: String, mime: String?, apiKey: String) async throws -> URL {
        var downloadURLString = uri
        if !uri.contains(":download"), let range = uri.range(of: "files/") {
            let name = String(uri[range.lowerBound...])
            let file = try await awaitActiveFile(
                named: name,
                initial: FileResource(name: name, state: "PROCESSING", uri: uri, downloadUri: nil),
                apiKey: apiKey
            )
            downloadURLString = file.downloadUri ?? "\(baseURL.absoluteString)/\(name):download?alt=media"
        }
        guard let url = URL(string: downloadURLString) else {
            throw APIError(message: "Gemini Omni returned an invalid file URL.")
        }
        let request = URLRequest(url: keyed(url, apiKey: apiKey), timeoutInterval: interactionRequestTimeout)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw APIError(message: "Gemini Omni file download failed (HTTP \(http.statusCode)).")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-omni-\(UUID().uuidString).\(fileExtension(forMime: mime))")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private struct Interaction: Decodable {
        struct Step: Decodable {
            let type: String?
            let content: [ContentPart]?
        }
        struct ContentPart: Decodable {
            let type: String?
            let mime_type: String?
            let data: String?
            let uri: String?
        }
        struct ErrorPayload: Decodable {
            let message: String?
        }

        let id: String?
        let status: String?
        let steps: [Step]?
        let error: ErrorPayload?

        var isTerminal: Bool {
            status == nil || status == "completed" || status == "failed"
        }

        var outputParts: [ContentPart] {
            (steps ?? [])
                .filter { $0.type == "model_output" }
                .flatMap { $0.content ?? [] }
                .filter { $0.type == "video" || $0.type == "image" }
        }
    }

    private struct FileResource: Decodable {
        let name: String
        let state: String?
        let uri: String?
        let downloadUri: String?
    }

    private struct FileEnvelope: Decodable {
        let file: FileResource?
        let name: String?
        let state: String?
        let uri: String?
        let downloadUri: String?

        var resolved: FileResource {
            file ?? FileResource(name: name ?? "", state: state, uri: uri, downloadUri: downloadUri)
        }
    }

    private static func keyed(_ url: URL, apiKey: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: apiKey)]
        return components.url!
    }

    private static func urlRequest(
        url: URL,
        method: String = "GET",
        body: [String: Any]? = nil,
        apiKey: String,
        timeout: TimeInterval = requestTimeout
    ) throws -> URLRequest {
        var request = URLRequest(url: keyed(url, apiKey: apiKey), timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "Google did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: errorMessage(data, status: http.statusCode))
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError(message: "Google returned an unexpected response.")
        }
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        if status == 400 || status == 401 || status == 403 {
            if let message = googleErrorText(data) {
                return "Google: \(message)"
            }
            return "Google rejected the API key. Check it in Settings › Models."
        }
        if let message = googleErrorText(data) {
            return "Google: \(message)"
        }
        return "Google request failed (HTTP \(status))."
    }

    private static func googleErrorText(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return json["message"] as? String
    }

    static func fileExtension(forMime mime: String?) -> String {
        switch mime {
        case "video/mp4", nil: "mp4"
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/webp": "webp"
        default: mime?.hasPrefix("image/") == true ? "png" : "mp4"
        }
    }

    static func videoMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": "video/quicktime"
        case "webm": "video/webm"
        default: "video/mp4"
        }
    }

    private static func writeTemporaryFile(_ data: Data, extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-omni-\(UUID().uuidString).\(pathExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
