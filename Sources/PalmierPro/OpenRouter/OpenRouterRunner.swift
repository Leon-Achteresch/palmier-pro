import Foundation

/// Maps a generation request onto the OpenRouter image or video API.
enum OpenRouterRunner {
    static func handles(_ modelId: String) -> Bool {
        OpenRouterCatalog.isOpenRouterModel(modelId)
    }

    @MainActor
    static func run(catalogId: String, params: BackendGenerationParams) async throws -> [URL] {
        guard let apiKey = OpenRouterService.shared.currentKey() else {
            throw OpenRouterAPI.APIError(message: "Add your OpenRouter API key in Settings › Agent.")
        }
        let model = OpenRouterCatalog.modelId(for: catalogId)

        switch params {
        case .image(let image):
            guard !image.prompt.isEmpty else {
                throw OpenRouterAPI.APIError(message: "Image generation needs a prompt.")
            }
            return try await OpenRouterAPI.generateImages(
                model: model,
                prompt: image.prompt,
                count: image.numImages,
                aspectRatio: image.aspectRatio,
                resolution: image.resolution,
                quality: image.quality,
                referenceDataURLs: image.imageURLs,
                apiKey: apiKey
            )
        case .video(let video):
            guard !video.prompt.isEmpty else {
                throw OpenRouterAPI.APIError(message: "Video generation needs a prompt.")
            }
            guard video.sourceVideoURL == nil, video.referenceVideoURLs.isEmpty,
                  video.referenceAudioURLs.isEmpty else {
                throw OpenRouterAPI.APIError(
                    message: "OpenRouter video models take a prompt with optional first/last frame images only."
                )
            }
            var frames: [OpenRouterAPI.FrameImage] = []
            if let start = video.startFrameURL {
                frames.append(.init(dataURL: start, position: "first_frame"))
            }
            if let end = video.endFrameURL {
                frames.append(.init(dataURL: end, position: "last_frame"))
            }
            let file = try await OpenRouterAPI.generateVideo(
                model: model,
                prompt: video.prompt,
                durationSeconds: video.duration,
                resolution: video.resolution,
                aspectRatio: video.aspectRatio,
                generateAudio: video.generateAudio,
                frameImages: frames,
                referenceDataURLs: video.referenceImageURLs,
                apiKey: apiKey
            )
            return [file]
        case .audio, .upscale:
            throw OpenRouterAPI.APIError(message: "OpenRouter handles image and video generation only.")
        }
    }
}
