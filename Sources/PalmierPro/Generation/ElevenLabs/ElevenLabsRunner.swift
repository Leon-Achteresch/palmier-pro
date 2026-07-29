import Foundation

/// Turns a generation request into an ElevenLabs API call made with the user's own key.
enum ElevenLabsRunner {
    static func handles(_ modelId: String) -> Bool {
        ElevenLabsCatalog.isElevenLabsModel(modelId)
    }

    @MainActor
    static func run(
        modelId: String,
        params: AudioGenerationParams,
        sourceURL: URL?,
        trimmedSource: TrimmedSource?
    ) async throws -> URL {
        guard let apiKey = ElevenLabsService.shared.currentKey() else {
            throw ElevenLabsAPI.APIError(message: "Add your ElevenLabs API key in Settings › Models.")
        }
        let voiceId = ElevenLabsService.shared.voiceId(named: params.voice)

        var extracted: URL?
        defer {
            if let extracted {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: extracted) }
            }
        }
        var preparedSource = sourceURL
        if let sourceURL,
           ClipType(fileExtension: sourceURL.pathExtension.lowercased()) == .video
            || trimmedSource?.hasTrim == true {
            let audioOnly = try await AudioTrackExtractor.extract(
                sourceURL: sourceURL,
                trimmedSource: trimmedSource
            )
            extracted = audioOnly
            preparedSource = audioOnly
        }

        let operation = try operation(
            modelId: modelId,
            params: params,
            voiceId: voiceId,
            sourceURL: preparedSource
        )
        return try await ElevenLabsAPI.run(operation, apiKey: apiKey)
    }

    static func operation(
        modelId: String,
        params: AudioGenerationParams,
        voiceId: String,
        sourceURL: URL?
    ) throws -> ElevenLabsAPI.Operation {
        let prompt = params.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = params.durationSeconds.flatMap { $0 > 0 ? $0 : nil }

        func requirePrompt() throws -> String {
            guard !prompt.isEmpty else {
                throw ElevenLabsAPI.APIError(message: "This ElevenLabs model needs a prompt.")
            }
            return prompt
        }
        func requireSource() throws -> URL {
            guard let sourceURL else {
                throw ElevenLabsAPI.APIError(message: "This ElevenLabs model needs source audio.")
            }
            return sourceURL
        }

        switch modelId {
        case ElevenLabsCatalog.speechId:
            return .speech(text: try requirePrompt(), voiceId: voiceId)
        case ElevenLabsCatalog.soundEffectId:
            return .soundEffect(text: try requirePrompt(), durationSeconds: duration)
        case ElevenLabsCatalog.musicId:
            return .music(
                prompt: try requirePrompt(),
                durationSeconds: duration,
                instrumental: params.instrumental
            )
        case ElevenLabsCatalog.voiceIsolationId:
            return .isolateVoice(source: try requireSource())
        case ElevenLabsCatalog.voiceChangerId:
            return .changeVoice(source: try requireSource(), voiceId: voiceId)
        default:
            throw ElevenLabsAPI.APIError(message: "Unknown ElevenLabs model '\(modelId)'.")
        }
    }
}
