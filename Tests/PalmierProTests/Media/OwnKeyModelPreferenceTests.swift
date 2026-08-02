import Foundation
import Testing
@testable import PalmierPro

private struct FakeModel {
    let id: String
    let paidOnly: Bool
}

@MainActor
@Test func preferUsableModelPicksFreeModelForUnpaidAccount() {
    let models = [
        FakeModel(id: "backend-paid", paidOnly: true),
        FakeModel(id: "own-key", paidOnly: false),
    ]
    #expect(preferUsableModel(models, paidOnly: \.paidOnly)?.id == "own-key")
}

@MainActor
@Test func preferUsableModelFallsBackToFirstWhenNoneUsable() {
    let models = [
        FakeModel(id: "backend-paid", paidOnly: true),
        FakeModel(id: "backend-paid-2", paidOnly: true),
    ]
    #expect(preferUsableModel(models, paidOnly: \.paidOnly)?.id == "backend-paid")
    #expect(preferUsableModel([], paidOnly: \FakeModel.paidOnly) == nil)
}

@MainActor
@Test func editActionUnblocksWhenOwnKeyEditModelExists() {
    ModelCatalog.shared.setGeminiEntries(GeminiOmniCatalog.entries())
    defer { ModelCatalog.shared.setGeminiEntries([]) }

    #expect(VideoModelConfig.edit?.id == GeminiOmniCatalog.videoEditId)
    #expect(ImageModelConfig.imageEdit?.id == GeminiOmniCatalog.imageEditId)
    #expect(!EditAction.edit.paidBlocked(for: .video))
    #expect(!EditAction.edit.paidBlocked(for: .image))
}
