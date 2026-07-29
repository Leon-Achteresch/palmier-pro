import Foundation

/// Image and video models served through the user's own OpenRouter key.
enum OpenRouterCatalog {
    static let providerName = "OpenRouter (your API key)"
    private static let idPrefix = "openrouter:"

    static func isOpenRouterModel(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static func catalogId(for modelId: String) -> String { idPrefix + modelId }

    /// The OpenRouter model id behind a catalog id.
    static func modelId(for catalogId: String) -> String {
        String(catalogId.dropFirst(idPrefix.count))
    }

    static func entries(
        imageModels: [OpenRouterAPI.ImageModel],
        videoModels: [OpenRouterAPI.VideoModel]
    ) -> [CatalogEntry] {
        var definitions: [[String: Any]] = []

        for model in imageModels {
            var capabilities: [String: Any] = [
                "aspectRatios": model.aspectRatios,
                "supportsImageReference": model.maxReferences > 0,
                "maxImages": max(1, model.maxImages),
            ]
            if let resolutions = model.resolutions { capabilities["resolutions"] = resolutions }
            if let qualities = model.qualities { capabilities["qualities"] = qualities }
            definitions.append(definition(
                id: model.id,
                kind: "image",
                responseShape: "images",
                displayName: model.name,
                description: model.description,
                capabilities: capabilities
            ))
        }

        for model in videoModels {
            var capabilities: [String: Any] = [
                "supportsPrompt": true,
                "durations": model.durations,
                "aspectRatios": model.aspectRatios,
                "supportsFirstFrame": model.supportsFirstFrame,
                "supportsLastFrame": model.supportsLastFrame,
                // ponytail: /videos/models advertises no input_references capability, so allow a few and let OpenRouter reject unsupported models
                "maxReferenceImages": 4,
                "maxReferenceVideos": 0,
                "maxReferenceAudios": 0,
                "framesAndReferencesExclusive": false,
                "referenceTagNoun": "reference",
                "requiresSourceVideo": false,
                "requiresReferenceImage": false,
            ]
            if let resolutions = model.resolutions { capabilities["resolutions"] = resolutions }
            definitions.append(definition(
                id: model.id,
                kind: "video",
                responseShape: "video",
                displayName: model.name,
                description: model.description,
                capabilities: capabilities
            ))
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: definitions)
            return try JSONDecoder().decode([CatalogEntry].self, from: data)
        } catch {
            Log.generation.error("OpenRouter catalog decode failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func definition(
        id: String,
        kind: String,
        responseShape: String,
        displayName: String,
        description: String?,
        capabilities: [String: Any]
    ) -> [String: Any] {
        var definition: [String: Any] = [
            "id": catalogId(for: id),
            "kind": kind,
            "displayName": displayName,
            "providerName": providerName,
            "allowedEndpoints": [],
            "responseShape": responseShape,
            "paidOnly": false,
            "uiCapabilities": capabilities,
        ]
        if let description { definition["description"] = description }
        return definition
    }
}
