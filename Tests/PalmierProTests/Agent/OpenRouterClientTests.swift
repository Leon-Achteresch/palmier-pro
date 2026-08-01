import Foundation
import Testing
@testable import PalmierPro

@Test func openRouterConvertsToolUseAndToolResultTurns() throws {
    let messages = [
        AnthropicMessage(role: .user, content: [["type": "text", "text": "trim it"]]),
        AnthropicMessage(role: .assistant, content: [
            ["type": "text", "text": "On it."],
            ["type": "tool_use", "id": "call_1", "name": "trim_clips", "input": ["clipId": "a1"]],
        ]),
        AnthropicMessage(role: .user, content: [
            ["type": "tool_result", "tool_use_id": "call_1",
             "content": [["type": "text", "text": "{\"status\":\"ok\"}"]], "is_error": false],
        ]),
    ]

    let converted = OpenRouterMessageConverter.convert(messages)

    #expect(converted.count == 3)
    #expect(converted[0]["role"] as? String == "user")

    let assistant = converted[1]
    #expect(assistant["content"] as? String == "On it.")
    let call = try #require((assistant["tool_calls"] as? [[String: Any]])?.first)
    #expect(call["id"] as? String == "call_1")
    let function = try #require(call["function"] as? [String: Any])
    #expect(function["name"] as? String == "trim_clips")
    #expect(function["arguments"] as? String == "{\"clipId\":\"a1\"}")

    let toolMessage = converted[2]
    #expect(toolMessage["role"] as? String == "tool")
    #expect(toolMessage["tool_call_id"] as? String == "call_1")
    #expect(toolMessage["content"] as? String == "{\"status\":\"ok\"}")
}

@Test func openRouterInlinesImagesAsDataURLParts() throws {
    let messages = [
        AnthropicMessage(role: .user, content: [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "QUJD"]],
            ["type": "text", "text": "what is this"],
        ]),
    ]

    let converted = OpenRouterMessageConverter.convert(messages)
    let parts = try #require(converted.first?["content"] as? [[String: Any]])
    let imagePart = try #require(parts.first)
    #expect(imagePart["type"] as? String == "image_url")
    #expect((imagePart["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,QUJD")
    #expect(parts.last?["text"] as? String == "what is this")
}

@Test func openRouterParsesToolCapableChatModels() throws {
    let json = """
    {
      "data": [
        {
          "id": "anthropic/claude-sonnet-5",
          "name": "Anthropic: Claude Sonnet 5",
          "reasoning": {
            "supported_efforts": ["max", "xhigh", "high", "medium", "low"],
            "default_effort": "high",
            "mandatory": false
          }
        },
        {
          "id": "openai/gpt-5.5",
          "name": "OpenAI: GPT-5.5",
          "reasoning": {
            "supported_efforts": null,
            "default_effort": "medium",
            "mandatory": false
          }
        },
        {"id": "acme/basic-chat", "name": "Basic Chat"}
      ]
    }
    """.data(using: .utf8)!

    let models = try OpenRouterAPI.parseChatModels(from: json)
    #expect(models.map(\.id) == ["anthropic/claude-sonnet-5", "openai/gpt-5.5", "acme/basic-chat"])
    #expect(models[0].supportsReasoning)
    #expect(models[0].supportedEfforts == ["max", "xhigh", "high", "medium", "low"])
    #expect(models[0].defaultEffort == "high")
    #expect(models[1].supportsReasoning)
    #expect(models[1].supportedEfforts == nil)
    #expect(models[2].supportsReasoning == false)
}

@Test func openRouterCatalogPrefixesIdsAndMapsCapabilities() throws {
    let entries = OpenRouterCatalog.entries(
        imageModels: [.init(
            id: "openai/gpt-image-2", name: "GPT Image 2", description: nil,
            aspectRatios: ["1:1", "16:9"], resolutions: ["1K"], qualities: ["low", "high"],
            maxImages: 10, maxReferences: 16
        )],
        videoModels: [.init(
            id: "google/veo-3.1", name: "Veo 3.1", description: nil,
            durations: [4, 6, 8], resolutions: ["720p", "1080p"], aspectRatios: ["16:9", "9:16"],
            supportsFirstFrame: true, supportsLastFrame: true, supportsAudio: true
        )]
    )

    #expect(entries.map(\.id) == ["openrouter:openai/gpt-image-2", "openrouter:google/veo-3.1"])
    #expect(entries.allSatisfy { OpenRouterCatalog.isOpenRouterModel($0.id) && !$0.paidOnly })
    #expect(OpenRouterCatalog.modelId(for: entries[1].id) == "google/veo-3.1")

    guard case .image(let image) = entries[0].uiCapabilities,
          case .video(let video) = entries[1].uiCapabilities else {
        Issue.record("unexpected capability kinds")
        return
    }
    #expect(image.maxImages == 10)
    #expect(image.supportsImageReference)
    #expect(image.qualities == ["low", "high"])
    #expect(video.durations == [4, 6, 8])
    #expect(video.supportsFirstFrame && video.supportsLastFrame)
    #expect(video.maxReferenceVideos == 0)
}
