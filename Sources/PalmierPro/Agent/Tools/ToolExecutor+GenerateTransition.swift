import Foundation

private struct GenerateTransitionInput: DecodableToolArgs {
    let afterClipId: String
    let prompt: String?
    let name: String?
    let model: String?
    let duration: Int?
    let aspectRatio: String?
    let resolution: String?
    let folder: String?

    static let allowedKeys: Set<String> = [
        "afterClipId", "prompt", "name", "model", "duration",
        "aspectRatio", "resolution", "folder",
    ]
}

extension ToolExecutor {
    func generateTransition(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: GenerateTransitionInput = try decodeToolArgs(args, path: "generate_transition")

        let modelId = try input.model ?? defaultTransitionModelId()
        guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Use list_models with type='video'.")
        }
        guard !model.requiresSourceVideo, model.supportsFirstFrame, model.supportsLastFrame else {
            throw ToolError(
                "Model '\(model.id)' must support first and last frames without a source video. "
                + "Pick one from list_models where supportsFirstFrame and supportsLastFrame are true."
            )
        }
        try requireGenerationAccess(modelId: model.id)

        let site: TransitionSite
        switch editor.transitionSite(afterClipId: input.afterClipId) {
        case .failure(let reason):
            throw ToolError(reason)
        case .success(let resolved):
            site = resolved
        }

        let durationHint = input.duration.map(Double.init)
        let gap: GapSelection
        switch editor.ensureTransitionGap(
            afterClipId: input.afterClipId,
            durationSeconds: durationHint,
            model: model
        ) {
        case .failure(let reason):
            throw ToolError(reason)
        case .success(let resolved):
            gap = resolved
        }

        let placement = PendingTransitionPlacement(
            timelineId: editor.activeTimelineId,
            trackIndex: gap.trackIndex,
            gapStartFrame: gap.range.start,
            gapLengthFrames: gap.range.length
        )
        let generationDuration = EditorViewModel.nearestSupportedDuration(
            seconds: editor.transitionGapSeconds(lengthFrames: placement.gapLengthFrames),
            in: model.durations
        )
        let aspectRatio = input.aspectRatio
            ?? EditorViewModel.closestAspectRatio(
                width: editor.timeline.width,
                height: editor.timeline.height,
                in: model.aspectRatios
            )
        let resolution = input.resolution ?? model.resolutions?.first
        if let err = model.validate(
            duration: generationDuration,
            aspectRatio: aspectRatio,
            resolution: resolution
        ) {
            throw ToolError(err)
        }

        let prompt = {
            let trimmed = input.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? EditorViewModel.defaultTransitionPrompt : trimmed
        }()

        let startFrame = placement.gapStartFrame - 1
        let endFrame = placement.gapStartFrame + placement.gapLengthFrames
        guard editor.transitionSeedIsCurrent(placement) else {
            throw ToolError("The transition gap changed before frames could be captured.")
        }
        let first = try await editor.captureFrameToMedia(
            source: .timeline(frame: startFrame),
            name: "Transition start (frame \(startFrame))"
        )
        try Task.checkCancellation()
        guard editor.transitionSeedIsCurrent(placement) else {
            throw ToolError("The transition gap changed before frames could be captured.")
        }
        let last = try await editor.captureFrameToMedia(
            source: .timeline(frame: endFrame),
            name: "Transition end (frame \(endFrame))"
        )
        try Task.checkCancellation()
        guard editor.transitionSeedIsCurrent(placement) else {
            throw ToolError("The transition gap changed before generation could start.")
        }

        let inputAssets = VideoGenerationSubmission.InputAssets(frames: [first.asset, last.asset])
        if let err = inputAssets.validate(for: model) {
            throw ToolError(err)
        }

        let genInput = GenerationInput(
            prompt: prompt,
            model: model.id,
            duration: generationDuration,
            aspectRatio: aspectRatio,
            resolution: resolution
        )
        let folderId = try resolveFolder(
            args,
            editor: editor,
            fallbackReferences: [first.asset, last.asset]
        )
        let editorRef = editor
        let placeholderId = VideoGenerationSubmission.make(
            genInput: genInput,
            model: model,
            inputAssets: inputAssets,
            placeholderDuration: Double(max(1, generationDuration)),
            name: input.name,
            folderId: folderId,
            generateAudio: true
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: { [weak editorRef] asset in
                editorRef?.finalizeTransitionClip(placeholderId: asset.id, asset: asset)
            }
        )

        guard editor.transitionSeedIsCurrent(placement) else {
            throw ToolError("The transition gap changed; the generated clip landed in Media instead of the timeline.")
        }
        let clipId = editor.placeGeneratingTransitionClip(
            placeholderId: placeholderId,
            placement: placement
        )

        var payload: [String: Any] = [
            "status": "started",
            "mediaRef": placeholderId,
            "model": model.id,
            "durationSeconds": generationDuration,
            "aspectRatio": aspectRatio,
            "gap": [
                "trackIndex": placement.trackIndex,
                "startFrame": placement.gapStartFrame,
                "endFrame": placement.gapStartFrame + placement.gapLengthFrames,
            ],
            "startFrameMediaRef": first.asset.id,
            "endFrameMediaRef": last.asset.id,
            "afterClipId": site.afterClipId,
        ]
        if let resolution { payload["resolution"] = resolution }
        if let clipId { payload["clipId"] = clipId }
        if let next = site.nextClipId { payload["nextClipId"] = next }
        guard let json = Self.jsonString(payload) else {
            throw ToolError("Failed to encode transition receipt.")
        }
        return .ok(json)
    }

    private func defaultTransitionModelId() throws -> String {
        guard let model = VideoModelConfig.allModels.first(where: {
            !$0.requiresSourceVideo && $0.supportsFirstFrame && $0.supportsLastFrame
        }) else {
            throw ToolError(
                "No video model supports first and last frames. "
                + "Use list_models or tell the user to add an API key."
            )
        }
        return model.id
    }
}
