import Foundation
import Testing
@testable import PalmierPro

@Test func geminiCatalogExposesGenerateEditAndImageModels() {
    let entries = GeminiOmniCatalog.entries()
    let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    #expect(entries.count == 3)
    #expect(entries.allSatisfy { GeminiOmniCatalog.isGeminiModel($0.id) && !$0.paidOnly })

    guard case .video(let generate)? = byId[GeminiOmniCatalog.generateId]?.uiCapabilities else {
        Issue.record("generate model missing")
        return
    }
    #expect(!generate.requiresSourceVideo)
    #expect(generate.supportsFirstFrame)
    #expect(generate.maxReferenceImages == 7)

    guard let editEntry = byId[GeminiOmniCatalog.videoEditId],
          case .video(let editCaps) = editEntry.uiCapabilities else {
        Issue.record("edit model missing")
        return
    }
    let edit = VideoModelConfig(entry: editEntry, caps: editCaps)
    #expect(edit.isEdit)

    guard case .image(let image)? = byId[GeminiOmniCatalog.imageEditId]?.uiCapabilities else {
        Issue.record("image model missing")
        return
    }
    #expect(image.supportsImageReference)
    #expect(image.maxImages == 1)
}

@Test func geminiRunnerBuildsInteractionRequests() throws {
    let reference = GeminiOmniAPI.Part.inlineImage(data: Data([1]), mime: "image/png")

    let textToVideo = try GeminiOmniRunner.videoGenerateRequest(
        prompt: "  a calm ocean  ", aspectRatio: "16:9", imageParts: []
    )
    #expect(textToVideo.task == "text_to_video")
    #expect(textToVideo.parts == [.text("a calm ocean")])
    #expect(textToVideo.aspectRatio == "16:9")
    #expect(textToVideo.uriDelivery)

    let imageToVideo = try GeminiOmniRunner.videoGenerateRequest(
        prompt: "animate this", aspectRatio: "9:16", imageParts: [reference]
    )
    #expect(imageToVideo.task == "image_to_video")
    #expect(imageToVideo.parts == [reference, .text("animate this")])

    let edit = try GeminiOmniRunner.videoEditRequest(
        prompt: "replace the red car with a blue truck",
        sourceFileURI: "files/abc",
        imageParts: [reference]
    )
    #expect(edit.task == "edit")
    #expect(edit.parts == [
        .videoFile(uri: "files/abc"),
        reference,
        .text("replace the red car with a blue truck"),
    ])

    #expect(throws: GeminiOmniAPI.APIError.self) {
        try GeminiOmniRunner.videoEditRequest(prompt: "   ", sourceFileURI: "files/abc", imageParts: [])
    }
}

@Test func geminiInteractionBodySerializesPartsAndConfig() throws {
    let request = try GeminiOmniRunner.videoEditRequest(
        prompt: "cut the intro",
        sourceFileURI: "files/abc",
        imageParts: []
    )
    let body = GeminiOmniAPI.body(for: request)

    #expect(body["model"] as? String == GeminiOmniAPI.model)
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.first?["type"] as? String == "video")
    #expect(input.first?["uri"] as? String == "files/abc")
    #expect(input.last?["type"] as? String == "text")

    let responseFormat = try #require(body["response_format"] as? [String: Any])
    #expect(responseFormat["type"] as? String == "video")
    #expect(responseFormat["delivery"] as? String == "uri")

    let generationConfig = try #require(body["generation_config"] as? [String: Any])
    let videoConfig = try #require(generationConfig["video_config"] as? [String: Any])
    #expect(videoConfig["task"] as? String == "edit")

    let plainText = GeminiOmniAPI.body(
        for: try GeminiOmniRunner.videoGenerateRequest(prompt: "a fox", aspectRatio: nil, imageParts: [])
    )
    #expect(plainText["input"] as? String == "a fox")
}

@Test func geminiImageEditUsesGenerateContentShape() throws {
    let body = GeminiOmniAPI.generateContentBody(
        prompt: "remove the logo",
        imageParts: [.inlineImage(data: Data([1]), mime: "image/png")]
    )
    let contents = try #require(body["contents"] as? [[String: Any]])
    let parts = try #require(contents.first?["parts"] as? [[String: Any]])
    #expect(parts.count == 2)
    let inline = try #require(parts.first?["inline_data"] as? [String: Any])
    #expect(inline["mime_type"] as? String == "image/png")
    #expect(parts.last?["text"] as? String == "remove the logo")
}
