import Foundation

struct TransitionSite: Equatable {
    let trackIndex: Int
    let afterClipId: String
    let nextClipId: String?
    let cutFrame: Int
    let existingGapLengthFrames: Int?
}

enum TransitionOutcome<T> {
    case success(T)
    case failure(String)
}

extension EditorViewModel {
    static let maxTransitionSeconds: Double = 15
    static let defaultTransitionDurationSeconds = 4

    static let defaultTransitionPrompt = """
        Create a seamless transition between the first frame and the last frame, one continuous \
        take. No weird movements, effects, or artifacts. Natural and consistent motion that makes \
        sense. No music, just appropriate SFX.
        """

    func transitionGapSeconds(lengthFrames: Int) -> Double {
        Double(lengthFrames) / Double(max(1, timeline.fps))
    }

    static func nearestSupportedDuration(seconds: Double, in durations: [Int]) -> Int {
        durations.min { abs(Double($0) - seconds) < abs(Double($1) - seconds) }
            ?? max(1, Int(seconds.rounded()))
    }

    static func closestAspectRatio(width: Int, height: Int, in allowed: [String]) -> String {
        guard !allowed.isEmpty else { return "16:9" }
        guard width > 0, height > 0 else { return allowed[0] }
        let target = Double(width) / Double(height)
        return allowed.min { abs(Self.aspectRatioValue($0) - target) < abs(Self.aspectRatioValue($1) - target) }
            ?? allowed[0]
    }

    private static func aspectRatioValue(_ ratio: String) -> Double {
        let parts = ratio.split(separator: ":")
        guard parts.count == 2,
              let a = Double(parts[0]),
              let b = Double(parts[1]),
              b != 0 else { return 16.0 / 9.0 }
        return a / b
    }

    func defaultTransitionModel() -> VideoModelConfig? {
        VideoModelConfig.allModels.first {
            !$0.requiresSourceVideo && $0.supportsFirstFrame && $0.supportsLastFrame
        }
    }

    func aiTransitionAvailability(for gap: GapSelection) -> (model: VideoModelConfig?, refusal: String?) {
        guard timeline.tracks.indices.contains(gap.trackIndex), gap.range.start > 0,
              gap.range.length > 0, timeline.tracks[gap.trackIndex].type == .video else { return (nil, nil) }
        let seconds = transitionGapSeconds(lengthFrames: gap.range.length)
        guard seconds <= Self.maxTransitionSeconds else {
            return (nil, "Transitions are limited to \(Int(Self.maxTransitionSeconds)) seconds. This gap is \(String(format: "%.1f", seconds)) seconds.")
        }
        guard aiEditAllowed else {
            return (nil, "Sign in or add an OpenRouter API key in Settings › Agent.")
        }
        let model = defaultTransitionModel()
        return (model, model == nil ? "No video model supports first and last frames." : nil)
    }

    func aiTransitionAvailability(afterClipId: String) -> (model: VideoModelConfig?, refusal: String?) {
        switch transitionSite(afterClipId: afterClipId) {
        case .failure(let reason):
            return (nil, reason)
        case .success(let site):
            guard aiEditAllowed else {
                return (nil, "Sign in or add an OpenRouter API key in Settings › Agent.")
            }
            let model = defaultTransitionModel()
            guard let model else {
                return (nil, "No video model supports first and last frames.")
            }
            if let gapFrames = site.existingGapLengthFrames {
                let seconds = transitionGapSeconds(lengthFrames: gapFrames)
                if seconds > Self.maxTransitionSeconds {
                    return (nil, "Transitions are limited to \(Int(Self.maxTransitionSeconds)) seconds. This gap is \(String(format: "%.1f", seconds)) seconds.")
                }
            }
            return (model, nil)
        }
    }

    func transitionSite(afterClipId: String) -> TransitionOutcome<TransitionSite> {
        guard let loc = findClip(id: afterClipId) else {
            return .failure("Clip not found: \(afterClipId)")
        }
        let track = timeline.tracks[loc.trackIndex]
        guard track.type == .video else {
            return .failure("AI transitions only work on video tracks.")
        }
        let clip = track.clips[loc.clipIndex]
        guard clip.mediaType.isVisual else {
            return .failure("AI transitions need a video or image clip before the cut.")
        }
        let cutFrame = clip.endFrame
        guard cutFrame > 0 else {
            return .failure("The clip before the transition must end after frame 0.")
        }
        let following = track.clips
            .filter { $0.startFrame >= cutFrame }
            .sorted { $0.startFrame < $1.startFrame }
        guard let next = following.first else {
            return .failure("No clip follows this one — add the next shot before creating a transition.")
        }
        guard next.mediaType.isVisual else {
            return .failure("The next clip after the cut must be video or image.")
        }
        let gapLength = next.startFrame - cutFrame
        return .success(TransitionSite(
            trackIndex: loc.trackIndex,
            afterClipId: clip.id,
            nextClipId: next.id,
            cutFrame: cutFrame,
            existingGapLengthFrames: gapLength > 0 ? gapLength : nil
        ))
    }

    func ensureTransitionGap(
        afterClipId: String,
        durationSeconds: Double?,
        model: VideoModelConfig
    ) -> TransitionOutcome<GapSelection> {
        switch transitionSite(afterClipId: afterClipId) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let site):
            if let gapFrames = site.existingGapLengthFrames {
                let seconds = transitionGapSeconds(lengthFrames: gapFrames)
                guard seconds <= Self.maxTransitionSeconds else {
                    return .failure("Transitions are limited to \(Int(Self.maxTransitionSeconds)) seconds. This gap is \(String(format: "%.1f", seconds)) seconds.")
                }
                return .success(GapSelection(
                    trackIndex: site.trackIndex,
                    range: FrameRange(start: site.cutFrame, end: site.cutFrame + gapFrames)
                ))
            }
            let requested = durationSeconds ?? Double(Self.defaultTransitionDurationSeconds)
            let snapped = Self.nearestSupportedDuration(seconds: requested, in: model.durations)
            guard Double(snapped) <= Self.maxTransitionSeconds else {
                return .failure("Transitions are limited to \(Int(Self.maxTransitionSeconds)) seconds.")
            }
            let lengthFrames = max(1, secondsToFrame(seconds: Double(snapped), fps: timeline.fps))
            switch openGap(
                trackIndex: site.trackIndex,
                atFrame: site.cutFrame,
                lengthFrames: lengthFrames,
                actionName: "Open Transition Gap"
            ) {
            case .opened(let gap):
                return .success(gap)
            case .refused(let reason):
                return .failure(reason)
            }
        }
    }

    func beginAITransition(gap: GapSelection) {
        guard let model = aiTransitionAvailability(for: gap).model else { return }
        seedAITransition(gap: gap, model: model)
    }

    func beginAITransition(afterClipId: String, durationSeconds: Double? = nil) {
        guard let model = aiTransitionAvailability(afterClipId: afterClipId).model else { return }
        switch ensureTransitionGap(afterClipId: afterClipId, durationSeconds: durationSeconds, model: model) {
        case .failure(let reason):
            mediaPanelToast = MediaPanelToast(message: reason)
        case .success(let gap):
            seedAITransition(gap: gap, model: model)
        }
    }

    private func seedAITransition(gap: GapSelection, model: VideoModelConfig) {
        let placement = PendingTransitionPlacement(
            timelineId: timeline.id,
            trackIndex: gap.trackIndex,
            gapStartFrame: gap.range.start,
            gapLengthFrames: gap.range.length
        )
        let duration = Self.nearestSupportedDuration(
            seconds: transitionGapSeconds(lengthFrames: placement.gapLengthFrames),
            in: model.durations
        )
        cancelPendingTransitionSeed()
        transitionSeedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let startFrame = placement.gapStartFrame - 1
                let endFrame = placement.gapStartFrame + placement.gapLengthFrames
                guard transitionSeedIsCurrent(placement) else { return }
                let first = try await captureFrameToMedia(
                    source: .timeline(frame: startFrame),
                    name: "Transition start (frame \(startFrame))"
                )
                try Task.checkCancellation()
                guard transitionSeedIsCurrent(placement) else { return }
                let last = try await captureFrameToMedia(
                    source: .timeline(frame: endFrame),
                    name: "Transition end (frame \(endFrame))"
                )
                try Task.checkCancellation()
                guard transitionSeedIsCurrent(placement) else { return }
                var stored = GenerationInput(
                    prompt: Self.defaultTransitionPrompt, model: model.id,
                    duration: duration,
                    aspectRatio: Self.closestAspectRatio(
                        width: timeline.width, height: timeline.height, in: model.aspectRatios
                    ),
                    resolution: model.resolutions?.first
                )
                stored.imageURLAssetIds = [first.asset.id, last.asset.id]
                seedGenerationPanel(asset: first.asset, stored: stored, transitionPlacement: placement)
            } catch is CancellationError {
            } catch {
                mediaPanelToast = MediaPanelToast(message: error.localizedDescription)
            }
        }
    }

    func transitionSeedIsCurrent(_ placement: PendingTransitionPlacement) -> Bool {
        activeTimelineId == placement.timelineId && transitionGapIsEmpty(placement)
    }

    func cancelPendingTransitionSeed() {
        transitionSeedTask?.cancel()
        transitionSeedTask = nil
    }

    @discardableResult
    func placeGeneratingTransitionClip(placeholderId: String, placement: PendingTransitionPlacement) -> String? {
        guard transitionSeedIsCurrent(placement),
              let asset = mediaAssets.first(where: { $0.id == placeholderId }) else {
            refuseWithToast("The gap is no longer available, so the transition will land in Media instead.")
            return nil
        }
        let before = timeline
        let ids = undo.withoutRegistration {
            placeClip(
                asset: asset,
                trackIndex: placement.trackIndex,
                startFrame: placement.gapStartFrame,
                durationFrames: placement.gapLengthFrames,
                addLinkedAudio: false
            )
        }
        guard let clipId = ids.first else {
            timeline = before
            return nil
        }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "AI Transition")
        notifyTimelineChanged()
        return clipId
    }

    func finalizeTransitionClip(placeholderId: String, asset: MediaAsset) {
        patchGeneratingClips(placeholderId: placeholderId) { clip, fps in
            let realFrames = max(1, secondsToFrame(seconds: asset.duration, fps: fps))
            clip.speed = Double(realFrames) / Double(max(1, clip.durationFrames))
            clip.trimStartFrame = 0
            clip.trimEndFrame = 0
        }
    }

    private func transitionGapIsEmpty(_ placement: PendingTransitionPlacement) -> Bool {
        guard timeline.tracks.indices.contains(placement.trackIndex) else { return false }
        let end = placement.gapStartFrame + placement.gapLengthFrames
        return !timeline.tracks[placement.trackIndex].clips.contains {
            $0.startFrame < end && $0.endFrame > placement.gapStartFrame
        }
    }
}
