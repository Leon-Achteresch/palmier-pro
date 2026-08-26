import Foundation

/// Generates music from music tab and places it on the timeline
struct MusicGenerationSubmission {
    let model: AudioModelConfig
    let prompt: String?
    let source: EditorViewModel.TimelineSpan
    let spanSeconds: Double
    let name: String?

    enum Phase {
        case generating

        var label: String {
            switch self {
            case .generating: L10n.key("Generating…")
            }
        }
    }

    @MainActor
    func run(
        service: GenerationService,
        projectURL: URL?,
        editor: EditorViewModel,
        onPhase: @MainActor (Phase) -> Void = { _ in },
        onFinished: @escaping @MainActor () -> Void = {}
    ) async throws {
        let durationSeconds = max(1, Int(spanSeconds.rounded()))
        let params = AudioGenerationParams(
            prompt: prompt ?? "",
            voice: nil,
            lyrics: nil,
            styleInstructions: nil,
            instrumental: false,
            durationSeconds: durationSeconds
        )

        var genInput = GenerationInput(
            prompt: prompt ?? "",
            model: model.id,
            duration: durationSeconds,
            aspectRatio: ""
        )
        genInput.audioInput = AudioModelConfig.Input.text.rawValue
        genInput.createdAt = Date()

        onPhase(.generating)
        let startFrame = source.startFrame
        let placeholderId = AudioGenerationSubmission.make(
            genInput: genInput, model: model, params: params, name: name ?? model.displayName
        ).submit(
            service: service,
            projectURL: projectURL,
            editor: editor,
            onComplete: { asset in
                editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                onFinished()
            },
            onFailure: { onFinished() }
        )
        editor.placeGeneratingAudioClip(
            placeholderId: placeholderId, startFrame: startFrame, spanSeconds: spanSeconds,
            actionName: "Add Music"
        )
    }
}
