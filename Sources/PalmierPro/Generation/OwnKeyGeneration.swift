import Foundation

/// Generation that runs on the user's own provider key instead of the Palmier backend.
enum OwnKeyGeneration {
    static func handles(_ modelId: String) -> Bool {
        ElevenLabsRunner.handles(modelId) || OpenRouterRunner.handles(modelId)
    }

    /// OpenRouter and/or ElevenLabs key present — AI UI works without Palmier backend.
    @MainActor
    static var keyConfigured: Bool {
        OpenRouterService.shared.hasKey || ElevenLabsService.shared.hasKey
    }

    @MainActor
    static func run(
        modelId: String,
        buildParams: ([String]) -> BackendGenerationParams,
        references: [MediaAsset],
        trimmedSource: TrimmedSource?
    ) async throws -> [URL] {
        if ElevenLabsRunner.handles(modelId) {
            guard case .audio(let params) = buildParams([]) else {
                throw ElevenLabsAPI.APIError(message: "ElevenLabs models generate audio only.")
            }
            let file = try await ElevenLabsRunner.run(
                modelId: modelId,
                params: params,
                sourceURL: references.first?.url,
                trimmedSource: trimmedSource
            )
            return [file]
        }
        // OpenRouter takes references inline as data URLs, so they never pass through an upload service.
        let dataURLs = try await referenceDataURLs(references)
        return try await OpenRouterRunner.run(catalogId: modelId, params: buildParams(dataURLs))
    }

    @MainActor
    private static func referenceDataURLs(_ references: [MediaAsset]) async throws -> [String] {
        guard !references.isEmpty else { return [] }
        guard references.allSatisfy({ $0.type == .image }) else {
            throw OpenRouterAPI.APIError(message: "OpenRouter models accept image references only.")
        }
        let urls = references.map(\.url)
        let encoded = await Task.detached(priority: .userInitiated) {
            urls.map(OpenRouterAPI.dataURL(for:))
        }.value
        return try encoded.enumerated().map { index, dataURL in
            guard let dataURL else {
                throw OpenRouterAPI.APIError(
                    message: "Could not read reference image \(references[index].name)."
                )
            }
            return dataURL
        }
    }
}
