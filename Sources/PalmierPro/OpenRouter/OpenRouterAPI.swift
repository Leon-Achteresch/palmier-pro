import Foundation

extension Notification.Name {
    static let openRouterAPIKeyChanged = Notification.Name("openRouterAPIKeyChanged")
}

enum OpenRouterKeychain {
    private static let account = "openrouter-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .openRouterAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .openRouterAPIKeyChanged, object: nil)
    }
}

/// Image and video generation on the user's own OpenRouter key.
enum OpenRouterAPI {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct ImageModel: Sendable {
        let id: String
        let name: String
        let description: String?
        let aspectRatios: [String]
        let resolutions: [String]?
        let qualities: [String]?
        let maxImages: Int
        let maxReferences: Int
    }

    struct VideoModel: Sendable {
        let id: String
        let name: String
        let description: String?
        let durations: [Int]
        let resolutions: [String]?
        let aspectRatios: [String]
        let supportsFirstFrame: Bool
        let supportsLastFrame: Bool
        let supportsAudio: Bool
    }

    struct FrameImage: Sendable {
        let dataURL: String
        let position: String
    }

    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    private static let requestTimeout: TimeInterval = 120
    private static let videoPollInterval: Duration = .seconds(5)
    private static let videoTimeout: Duration = .seconds(1800)

    // MARK: - Catalog

    @concurrent
    static func imageModels() async throws -> [ImageModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                struct Parameters: Decodable {
                    struct Enum: Decodable { let values: [String]? }
                    struct Range: Decodable { let max: Int? }
                    let aspect_ratio: Enum?
                    let resolution: Enum?
                    let quality: Enum?
                    let n: Range?
                    let input_references: Range?
                }
                let id: String
                let name: String
                let description: String?
                let supported_parameters: Parameters?
            }
            let data: [Entry]
        }
        let entries = try await decode(Response.self, from: request(path: "images/models", apiKey: nil))
        return entries.data.map { entry in
            let parameters = entry.supported_parameters
            return ImageModel(
                id: entry.id,
                name: entry.name,
                description: entry.description,
                aspectRatios: parameters?.aspect_ratio?.values ?? [],
                resolutions: parameters?.resolution?.values,
                qualities: parameters?.quality?.values,
                maxImages: parameters?.n?.max ?? 1,
                maxReferences: parameters?.input_references?.max ?? 0
            )
        }
    }

    @concurrent
    static func videoModels() async throws -> [VideoModel] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: String
                let name: String
                let description: String?
                let supported_durations: [Int]?
                let supported_resolutions: [String]?
                let supported_aspect_ratios: [String]?
                let supported_frame_images: [String]?
                let generate_audio: Bool?
            }
            let data: [Entry]
        }
        let entries = try await decode(Response.self, from: request(path: "videos/models", apiKey: nil))
        return entries.data.map { entry in
            let frames = entry.supported_frame_images ?? []
            return VideoModel(
                id: entry.id,
                name: entry.name,
                description: entry.description,
                durations: entry.supported_durations ?? [],
                resolutions: entry.supported_resolutions,
                aspectRatios: entry.supported_aspect_ratios ?? [],
                supportsFirstFrame: frames.contains("first_frame"),
                supportsLastFrame: frames.contains("last_frame"),
                supportsAudio: entry.generate_audio ?? false
            )
        }
    }

    // MARK: - Generation

    @concurrent
    static func generateImages(
        model: String,
        prompt: String,
        count: Int,
        aspectRatio: String?,
        resolution: String?,
        quality: String?,
        referenceDataURLs: [String],
        apiKey: String
    ) async throws -> [URL] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let b64_json: String?
                let media_type: String?
            }
            let data: [Entry]
        }
        var body: [String: Any] = ["model": model, "prompt": prompt, "n": max(1, count)]
        if let aspectRatio, !aspectRatio.isEmpty { body["aspect_ratio"] = aspectRatio }
        if let resolution, !resolution.isEmpty { body["resolution"] = resolution }
        if let quality, !quality.isEmpty { body["quality"] = quality }
        if !referenceDataURLs.isEmpty {
            body["input_references"] = referenceDataURLs.map(imageContentPart)
        }

        let response = try await decode(
            Response.self,
            from: request(path: "images", method: "POST", body: body, apiKey: apiKey)
        )
        let files = try response.data.compactMap { entry -> URL? in
            guard let base64 = entry.b64_json, let bytes = Data(base64Encoded: base64) else { return nil }
            return try writeTemporaryFile(bytes, extension: fileExtension(forMediaType: entry.media_type))
        }
        guard !files.isEmpty else { throw APIError(message: "OpenRouter returned no image data.") }
        return files
    }

    /// Submits a video job, polls it to completion, and downloads the finished file.
    @concurrent
    static func generateVideo(
        model: String,
        prompt: String,
        durationSeconds: Int?,
        resolution: String?,
        aspectRatio: String?,
        generateAudio: Bool?,
        frameImages: [FrameImage],
        referenceDataURLs: [String],
        apiKey: String
    ) async throws -> URL {
        struct Submission: Decodable {
            let id: String
            let status: String?
        }
        struct Job: Decodable {
            let status: String
            let unsigned_urls: [String]?
            let error: String?
        }

        var body: [String: Any] = ["model": model, "prompt": prompt]
        if let durationSeconds, durationSeconds > 0 { body["duration"] = durationSeconds }
        if let resolution, !resolution.isEmpty { body["resolution"] = resolution }
        if let aspectRatio, !aspectRatio.isEmpty { body["aspect_ratio"] = aspectRatio }
        if let generateAudio { body["generate_audio"] = generateAudio }
        if !frameImages.isEmpty {
            body["frame_images"] = frameImages.map { frame in
                var part = imageContentPart(frame.dataURL)
                part["frame_type"] = frame.position
                return part
            }
        }
        if !referenceDataURLs.isEmpty {
            body["input_references"] = referenceDataURLs.map(imageContentPart)
        }

        let submission = try await decode(
            Submission.self,
            from: request(path: "videos", method: "POST", body: body, apiKey: apiKey)
        )

        let deadline = ContinuousClock.now + videoTimeout
        while true {
            try Task.checkCancellation()
            let job = try await decode(
                Job.self,
                from: request(path: "videos/\(submission.id)", apiKey: apiKey)
            )
            switch job.status {
            case "completed":
                guard let urlString = job.unsigned_urls?.first, let url = URL(string: urlString) else {
                    throw APIError(message: "OpenRouter finished the video but returned no file.")
                }
                return try await downloadVideo(from: url, apiKey: apiKey)
            case "failed", "cancelled":
                throw APIError(message: job.error ?? "OpenRouter video generation failed.")
            default:
                guard ContinuousClock.now < deadline else {
                    throw APIError(message: "OpenRouter video generation timed out.")
                }
                try await Task.sleep(for: videoPollInterval)
            }
        }
    }

    private static func downloadVideo(from url: URL, apiKey: String) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw APIError(message: "OpenRouter video download failed (HTTP \(http.statusCode)).")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrouter-\(UUID().uuidString).mp4")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    // MARK: - Plumbing

    static func imageContentPart(_ url: String) -> [String: Any] {
        ["type": "image_url", "image_url": ["url": url]]
    }

    /// Base64 data URL for a local image, so references never leave through an upload service.
    static func dataURL(for imageURL: URL) -> String? {
        guard let encoded = ImageEncoder.encode(url: imageURL) else { return nil }
        return "data:\(encoded.mime);base64,\(encoded.data.base64EncodedString())"
    }

    private static func request(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        apiKey: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: requestTimeout)
        request.httpMethod = method
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("Palmier Pro", forHTTPHeaderField: "X-Title")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "OpenRouter did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: errorMessage(data, status: http.statusCode))
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError(message: "OpenRouter returned an unexpected response.")
        }
    }

    static func errorMessage(_ data: Data, status: Int) -> String {
        if status == 401 || status == 403 {
            return "OpenRouter rejected the API key. Check it in Settings › Agent."
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return "OpenRouter: \(message)"
            }
            if let message = json["message"] as? String {
                return "OpenRouter: \(message)"
            }
        }
        return "OpenRouter request failed (HTTP \(status))."
    }

    private static func fileExtension(forMediaType mediaType: String?) -> String {
        switch mediaType {
        case "image/jpeg": "jpg"
        case "image/webp": "webp"
        default: "png"
        }
    }

    private static func writeTemporaryFile(_ data: Data, extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrouter-\(UUID().uuidString).\(pathExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
