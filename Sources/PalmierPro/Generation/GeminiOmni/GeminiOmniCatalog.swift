import Foundation

enum GeminiOmniCatalog {
    static let providerName = "Google Gemini (your API key)"
    private static let idPrefix = "gemini-omni:"

    static let generateId = idPrefix + "flash"
    static let videoEditId = idPrefix + "flash-edit"
    static let imageEditId = idPrefix + "flash-image"

    static func isGeminiModel(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static func entries() -> [CatalogEntry] {
        let definitions: [[String: Any]] = [
            definition(
                id: generateId,
                kind: "video",
                responseShape: "video",
                displayName: "Gemini Omni Flash",
                description: "Conversational video generation from text or images on your Google AI key.",
                capabilities: [
                    "supportsPrompt": true,
                    "durations": [Int](),
                    "aspectRatios": ["16:9", "9:16"],
                    "supportsFirstFrame": true,
                    "supportsLastFrame": false,
                    "maxReferenceImages": 7,
                    "maxReferenceVideos": 0,
                    "maxReferenceAudios": 0,
                    "framesAndReferencesExclusive": false,
                    "referenceTagNoun": "reference",
                    "requiresSourceVideo": false,
                    "requiresReferenceImage": false,
                ]
            ),
            definition(
                id: videoEditId,
                kind: "video",
                responseShape: "video",
                displayName: "Gemini Omni Flash Edit",
                description: "Swap objects, rewrite scenes, and recut an existing video by describing the change.",
                capabilities: [
                    "supportsPrompt": true,
                    "durations": [Int](),
                    "aspectRatios": [String](),
                    "supportsFirstFrame": false,
                    "supportsLastFrame": false,
                    "maxReferenceImages": 7,
                    "maxReferenceVideos": 0,
                    "maxReferenceAudios": 0,
                    "framesAndReferencesExclusive": false,
                    "referenceTagNoun": "reference",
                    "requiresSourceVideo": true,
                    "requiresReferenceImage": false,
                ]
            ),
            definition(
                id: imageEditId,
                kind: "image",
                responseShape: "images",
                displayName: "Gemini Flash Image",
                description: "Edit images conversationally — replace, remove, or restyle elements.",
                capabilities: [
                    "aspectRatios": [String](),
                    "supportsImageReference": true,
                    "maxImages": 1,
                ]
            ),
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: definitions)
            return try JSONDecoder().decode([CatalogEntry].self, from: data)
        } catch {
            Log.generation.error("Gemini catalog decode failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func definition(
        id: String,
        kind: String,
        responseShape: String,
        displayName: String,
        description: String,
        capabilities: [String: Any]
    ) -> [String: Any] {
        [
            "id": id,
            "kind": kind,
            "displayName": displayName,
            "providerName": providerName,
            "description": description,
            "allowedEndpoints": [String](),
            "responseShape": responseShape,
            "paidOnly": false,
            "uiCapabilities": capabilities,
        ]
    }
}
