import Foundation

extension Notification.Name {
    static let elevenLabsAPIKeyChanged = Notification.Name("elevenLabsAPIKeyChanged")
}

enum ElevenLabsKeychain {
    private static let account = "elevenlabs-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .elevenLabsAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .elevenLabsAPIKeyChanged, object: nil)
    }
}

/// Direct calls to the ElevenLabs REST API with the user's own key.
enum ElevenLabsAPI {
    struct Voice: Sendable, Hashable {
        let id: String
        let name: String
    }

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum Operation: Sendable, Equatable {
        case speech(text: String, voiceId: String)
        case soundEffect(text: String, durationSeconds: Int?)
        case music(prompt: String, durationSeconds: Int?, instrumental: Bool)
        case isolateVoice(source: URL)
        case changeVoice(source: URL, voiceId: String)
    }

    /// ElevenLabs' premade "Rachel" voice, used when the account's voice list is unavailable.
    static let fallbackVoiceId = "21m00Tcm4TlvDq8ikWAM"

    private static let host = URL(string: "https://api.elevenlabs.io")!
    private static let outputFormat = "mp3_44100_128"
    private static let speechModelId = "eleven_multilingual_v2"
    private static let requestTimeout: TimeInterval = 600

    @concurrent
    static func voices(apiKey: String) async throws -> [Voice] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let voice_id: String
                let name: String?
            }
            let voices: [Entry]
        }
        var request = URLRequest(
            url: host.appending(path: "/v2/voices")
                .appending(queryItems: [URLQueryItem(name: "page_size", value: "100")])
        )
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let data = try await send(request)
        return try JSONDecoder().decode(Response.self, from: data).voices.map {
            Voice(id: $0.voice_id, name: $0.name ?? $0.voice_id)
        }
    }

    /// Runs one operation and returns a temporary MP3 file.
    @concurrent
    static func run(_ operation: Operation, apiKey: String) async throws -> URL {
        let request: URLRequest
        switch operation {
        case .speech(let text, let voiceId):
            request = try jsonRequest(
                path: "/v1/text-to-speech/\(voiceId)",
                body: ["text": text, "model_id": speechModelId],
                apiKey: apiKey
            )
        case .soundEffect(let text, let durationSeconds):
            var body: [String: Any] = ["text": text]
            if let durationSeconds { body["duration_seconds"] = durationSeconds }
            request = try jsonRequest(path: "/v1/sound-generation", body: body, apiKey: apiKey)
        case .music(let prompt, let durationSeconds, let instrumental):
            var body: [String: Any] = ["prompt": prompt, "force_instrumental": instrumental]
            if let durationSeconds { body["music_length_ms"] = durationSeconds * 1000 }
            request = try jsonRequest(path: "/v1/music", body: body, apiKey: apiKey)
        case .isolateVoice(let source):
            request = try multipartRequest(path: "/v1/audio-isolation", fileURL: source, apiKey: apiKey)
        case .changeVoice(let source, let voiceId):
            request = try multipartRequest(
                path: "/v1/speech-to-speech/\(voiceId)",
                fileURL: source,
                apiKey: apiKey
            )
        }
        return try writeTemporaryMP3(try await send(request))
    }

    private static func audioURL(_ path: String) -> URL {
        host.appending(path: path)
            .appending(queryItems: [URLQueryItem(name: "output_format", value: outputFormat)])
    }

    private static func jsonRequest(
        path: String,
        body: [String: Any],
        apiKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: audioURL(path), timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func multipartRequest(
        path: String,
        fileURL: URL,
        apiKey: String
    ) throws -> URLRequest {
        let boundary = "palmier-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: audioURL(path), timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "ElevenLabs did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: errorMessage(data, status: http.statusCode))
        }
        return data
    }

    private static func errorMessage(_ data: Data, status: Int) -> String {
        if status == 401 || status == 403 {
            return "ElevenLabs rejected the API key. Check it in Settings › Models."
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? [String: Any],
               let message = detail["message"] as? String {
                return "ElevenLabs: \(message)"
            }
            if let detail = json["detail"] as? String {
                return "ElevenLabs: \(detail)"
            }
        }
        return "ElevenLabs request failed (HTTP \(status))."
    }

    private static func writeTemporaryMP3(_ data: Data) throws -> URL {
        guard !data.isEmpty else { throw APIError(message: "ElevenLabs returned no audio.") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-\(UUID().uuidString).mp3")
        try data.write(to: url, options: .atomic)
        return url
    }
}
