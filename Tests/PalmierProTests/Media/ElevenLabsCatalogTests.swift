import Foundation
import Testing
@testable import PalmierPro

private func params(
    prompt: String = "",
    voice: String? = nil,
    instrumental: Bool = false,
    durationSeconds: Int? = nil
) -> AudioGenerationParams {
    AudioGenerationParams(
        prompt: prompt,
        voice: voice,
        lyrics: nil,
        styleInstructions: nil,
        instrumental: instrumental,
        durationSeconds: durationSeconds
    )
}

@Test func elevenLabsCatalogExposesEveryModelWithAccountVoices() {
    let entries = ElevenLabsCatalog.entries(voices: [.init(id: "v1", name: "Nova")])
    let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    #expect(entries.count == 5)
    #expect(entries.allSatisfy { ElevenLabsCatalog.isElevenLabsModel($0.id) && !$0.paidOnly })

    guard case .audio(let speech)? = byId[ElevenLabsCatalog.speechId]?.uiCapabilities else {
        Issue.record("speech model missing")
        return
    }
    #expect(speech.voices == ["Nova"])
    #expect(speech.defaultVoice == "Nova")

    guard case .audio(let music)? = byId[ElevenLabsCatalog.musicId]?.uiCapabilities else {
        Issue.record("music model missing")
        return
    }
    #expect(music.supportsInstrumental)
    #expect(music.durationRange?.minimum == 3 && music.durationRange?.maximum == 600)
}

@Test func elevenLabsModelsMapToTheirApiOperation() throws {
    let source = URL(fileURLWithPath: "/tmp/take.wav")

    #expect(try ElevenLabsRunner.operation(
        modelId: ElevenLabsCatalog.speechId,
        params: params(prompt: "  Hello  "), voiceId: "v1", sourceURL: nil
    ) == .speech(text: "Hello", voiceId: "v1"))

    #expect(try ElevenLabsRunner.operation(
        modelId: ElevenLabsCatalog.soundEffectId,
        params: params(prompt: "rain", durationSeconds: 8), voiceId: "v1", sourceURL: nil
    ) == .soundEffect(text: "rain", durationSeconds: 8))

    #expect(try ElevenLabsRunner.operation(
        modelId: ElevenLabsCatalog.musicId,
        params: params(prompt: "lofi", instrumental: true, durationSeconds: 0),
        voiceId: "v1", sourceURL: nil
    ) == .music(prompt: "lofi", durationSeconds: nil, instrumental: true))

    #expect(try ElevenLabsRunner.operation(
        modelId: ElevenLabsCatalog.voiceChangerId,
        params: params(voice: "Nova"), voiceId: "v1", sourceURL: source
    ) == .changeVoice(source: source, voiceId: "v1"))
}

@Test func elevenLabsOperationsRejectMissingPromptOrSource() {
    #expect(throws: ElevenLabsAPI.APIError.self) {
        try ElevenLabsRunner.operation(
            modelId: ElevenLabsCatalog.speechId,
            params: params(prompt: "   "), voiceId: "v1", sourceURL: nil
        )
    }
    #expect(throws: ElevenLabsAPI.APIError.self) {
        try ElevenLabsRunner.operation(
            modelId: ElevenLabsCatalog.voiceIsolationId,
            params: params(), voiceId: "v1", sourceURL: nil
        )
    }
}
