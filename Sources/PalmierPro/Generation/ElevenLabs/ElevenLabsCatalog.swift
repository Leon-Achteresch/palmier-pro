import Foundation

/// Catalog entries served straight from the user's own ElevenLabs key.
enum ElevenLabsCatalog {
    static let speechId = "elevenlabs-key-speech"
    static let soundEffectId = "elevenlabs-key-sound-effects"
    static let musicId = "elevenlabs-key-music"
    static let voiceIsolationId = "elevenlabs-key-voice-isolation"
    static let voiceChangerId = "elevenlabs-key-voice-changer"

    static let providerName = "ElevenLabs (your API key)"

    private static let modelIds: Set<String> = [
        speechId, soundEffectId, musicId, voiceIsolationId, voiceChangerId,
    ]

    static func isElevenLabsModel(_ id: String) -> Bool { modelIds.contains(id) }

    static func entries(voices: [ElevenLabsAPI.Voice]) -> [CatalogEntry] {
        let names = voices.map(\.name)
        var speech: [String: Any] = [
            "category": "tts",
            "supportsLyrics": false,
            "supportsInstrumental": false,
            "supportsStyleInstructions": false,
            "minPromptLength": 1,
            "inputs": ["text"],
            "promptLabel": "Text to speak",
        ]
        if let first = names.first {
            speech["voices"] = names
            speech["defaultVoice"] = first
        }
        var voiceChanger: [String: Any] = [
            "category": "general",
            "supportsLyrics": false,
            "supportsInstrumental": false,
            "supportsStyleInstructions": false,
            "minPromptLength": 0,
            "inputs": ["audio", "video"],
            "promptLabel": "Not used",
            "minSeconds": 1,
            "maxSeconds": 3600,
        ]
        if let first = names.first {
            voiceChanger["voices"] = names
            voiceChanger["defaultVoice"] = first
        }

        let definitions: [[String: Any]] = [
            definition(
                id: speechId,
                displayName: "ElevenLabs Speech",
                description: "Text to speech with any voice on your ElevenLabs account.",
                capabilities: speech
            ),
            definition(
                id: soundEffectId,
                displayName: "ElevenLabs Sound Effects",
                description: "Sound effects and foley from a text description.",
                capabilities: [
                    "category": "sfx",
                    "supportsLyrics": false,
                    "supportsInstrumental": false,
                    "supportsStyleInstructions": false,
                    "minPromptLength": 1,
                    "inputs": ["text"],
                    "promptLabel": "Describe the sound",
                    "durationRange": ["minimum": 1, "maximum": 30, "defaultValue": 5],
                ]
            ),
            definition(
                id: musicId,
                displayName: "ElevenLabs Music",
                description: "Music from a text description, with an optional instrumental mix.",
                capabilities: [
                    "category": "music",
                    "supportsLyrics": false,
                    "supportsInstrumental": true,
                    "supportsStyleInstructions": false,
                    "minPromptLength": 1,
                    "inputs": ["text"],
                    "promptLabel": "Describe the music",
                    "durationRange": ["minimum": 3, "maximum": 600, "defaultValue": 60],
                ]
            ),
            definition(
                id: voiceIsolationId,
                displayName: "ElevenLabs Voice Isolation",
                description: "Strips background noise and leaves clean speech.",
                capabilities: [
                    "category": "cleanup",
                    "supportsLyrics": false,
                    "supportsInstrumental": false,
                    "supportsStyleInstructions": false,
                    "minPromptLength": 0,
                    "inputs": ["audio", "video"],
                    "promptLabel": "Not used",
                    "minSeconds": 1,
                    "maxSeconds": 3600,
                ]
            ),
            definition(
                id: voiceChangerId,
                displayName: "ElevenLabs Voice Changer",
                description: "Re-performs existing speech in another voice, keeping the delivery.",
                capabilities: voiceChanger
            ),
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: definitions)
            return try JSONDecoder().decode([CatalogEntry].self, from: data)
        } catch {
            assertionFailure("ElevenLabs catalog definitions are malformed: \(error)")
            Log.generation.error("ElevenLabs catalog decode failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func definition(
        id: String,
        displayName: String,
        description: String,
        capabilities: [String: Any]
    ) -> [String: Any] {
        [
            "id": id,
            "kind": "audio",
            "displayName": displayName,
            "providerName": providerName,
            "description": description,
            "allowedEndpoints": [],
            "responseShape": "audio",
            "paidOnly": false,
            "uiCapabilities": capabilities,
        ]
    }
}
