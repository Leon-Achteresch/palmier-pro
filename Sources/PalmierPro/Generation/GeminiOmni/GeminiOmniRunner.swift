import Foundation

enum GeminiOmniRunner {
    static func handles(_ modelId: String) -> Bool {
        GeminiOmniCatalog.isGeminiModel(modelId)
    }

    @MainActor
    static func run(
        catalogId: String,
        params: GenerationParams,
        references: [MediaAsset],
        trimmedSource: TrimmedSource?
    ) async throws -> [URL] {
        guard let apiKey = GeminiOmniService.shared.currentKey() else {
            throw GeminiOmniAPI.APIError(message: "Add your Google AI API key in Settings › Models.")
        }

        switch params {
        case .image(let image):
            let parts = try await imageParts(for: references.filter { $0.type == .image })
            return try await GeminiOmniAPI.generateImage(
                prompt: try requiredPrompt(image.prompt),
                imageParts: parts,
                apiKey: apiKey
            )

        case .video(let video):
            if catalogId == GeminiOmniCatalog.videoEditId {
                return try await runVideoEdit(
                    video: video,
                    references: references,
                    trimmedSource: trimmedSource,
                    apiKey: apiKey
                )
            }
            let parts = try await imageParts(for: references.filter { $0.type == .image })
            let request = try videoGenerateRequest(
                prompt: video.prompt,
                aspectRatio: video.aspectRatio,
                imageParts: parts
            )
            return try await GeminiOmniAPI.run(request, apiKey: apiKey)

        case .audio, .upscale:
            throw GeminiOmniAPI.APIError(message: "Gemini Omni handles image and video generation only.")
        }
    }

    @MainActor
    private static func runVideoEdit(
        video: VideoGenerationParams,
        references: [MediaAsset],
        trimmedSource: TrimmedSource?,
        apiKey: String
    ) async throws -> [URL] {
        guard let source = references.first, source.type == .video else {
            throw GeminiOmniAPI.APIError(message: "Gemini Omni Flash Edit needs a source video.")
        }
        let refParts = try await imageParts(for: references.dropFirst().filter { $0.type == .image })

        var uploadURL = source.url
        var extracted: URL?
        defer {
            if let extracted {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: extracted) }
            }
        }
        if let trim = trimmedSource, trim.hasTrim {
            let trimmed = try await VideoTrimExtractor.extract(trim)
            extracted = trimmed
            uploadURL = trimmed
        }

        let fileURI = try await GeminiOmniAPI.uploadFile(
            fileURL: uploadURL,
            mimeType: GeminiOmniAPI.videoMimeType(for: uploadURL),
            apiKey: apiKey
        )
        let request = try videoEditRequest(
            prompt: video.prompt,
            sourceFileURI: fileURI,
            imageParts: refParts
        )
        return try await GeminiOmniAPI.run(request, apiKey: apiKey)
    }

    static func videoGenerateRequest(
        prompt: String,
        aspectRatio: String?,
        imageParts: [GeminiOmniAPI.Part]
    ) throws -> GeminiOmniAPI.Request {
        GeminiOmniAPI.Request(
            parts: imageParts + [.text(try requiredPrompt(prompt))],
            task: imageParts.isEmpty ? "text_to_video" : "image_to_video",
            responseType: "video",
            aspectRatio: aspectRatio,
            uriDelivery: true
        )
    }

    static func videoEditRequest(
        prompt: String,
        sourceFileURI: String,
        imageParts: [GeminiOmniAPI.Part]
    ) throws -> GeminiOmniAPI.Request {
        GeminiOmniAPI.Request(
            parts: [.videoFile(uri: sourceFileURI)] + imageParts + [.text(try requiredPrompt(prompt))],
            task: "edit",
            responseType: "video",
            aspectRatio: nil,
            uriDelivery: true
        )
    }

    private static func requiredPrompt(_ prompt: String) throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GeminiOmniAPI.APIError(message: "Gemini Omni needs a prompt describing the result.")
        }
        return trimmed
    }

    @MainActor
    private static func imageParts(for assets: [MediaAsset]) async throws -> [GeminiOmniAPI.Part] {
        guard !assets.isEmpty else { return [] }
        let urls = assets.map(\.url)
        let names = assets.map(\.name)
        let encoded = await Task.detached(priority: .userInitiated) {
            urls.map(ImageEncoder.encode(url:))
        }.value
        return try encoded.enumerated().map { index, output in
            guard let output else {
                throw GeminiOmniAPI.APIError(message: "Could not read reference image \(names[index]).")
            }
            return .inlineImage(data: output.data, mime: output.mime)
        }
    }
}
