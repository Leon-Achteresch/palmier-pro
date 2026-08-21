import Foundation

extension EditorViewModel {
    /// Called after Settings clears disk caches: session memoization must not outlive them.
    func resetAnalysisSessionState() {
        denoiseBaked.removeAll()
        denoiseFailed.removeAll()
        mediaVisualCache.resetSessionState()
        stabilizationJobs.reset()
        enhancePendingDenoises()
        resumePendingStabilizations()
    }

    func setDenoise(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, actionName: String) {
        let clamped = amount.map { min(1, max(0, $0)) }
        if enabled {
            for id in clipIds {
                if let ref = clipFor(id: id)?.mediaRef { denoiseFailed.remove(ref) }
            }
        }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            if let i = stack.firstIndex(where: { $0.type == Clip.denoiseEffectType }) {
                stack[i].enabled = enabled
                if let clamped { stack[i].params["amount"] = EffectParam(value: clamped) }
            } else if enabled {
                stack.append(Effect(type: Clip.denoiseEffectType, enabled: true, params: [
                    "amount": EffectParam(value: clamped ?? Clip.defaultDenoiseAmount),
                ]))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    static func studioBakeKey(_ mediaRef: String) -> String { "\(mediaRef)#studio" }

    func setStudioVoice(clipIds: Set<String>, enabled: Bool, actionName: String) {
        if enabled {
            for id in clipIds {
                if let ref = clipFor(id: id)?.mediaRef { denoiseFailed.remove(Self.studioBakeKey(ref)) }
            }
        }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            if let i = stack.firstIndex(where: { $0.type == Clip.studioVoiceEffectType }) {
                stack[i].enabled = enabled
            } else if enabled {
                stack.append(Effect(type: Clip.studioVoiceEffectType, enabled: true))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    func enhancePendingDenoises() {
        for track in timeline.tracks {
            for clip in track.clips where clip.hasDenoiseEnabled || clip.hasStudioVoiceEnabled {
                enhanceAudioIfNeeded(for: clip)
            }
        }
    }

    func enhanceAudioIfNeeded(for clip: Clip) {
        if clip.hasStudioVoiceEnabled {
            bakeEnhancement(
                mediaRef: clip.mediaRef,
                key: Self.studioBakeKey(clip.mediaRef),
                cached: AudioEnhancer.cachedStudioURL,
                bake: AudioEnhancer.studioAudio
            )
        } else if clip.hasDenoiseEnabled, clip.denoiseAmount > 0 {
            bakeEnhancement(
                mediaRef: clip.mediaRef,
                key: clip.mediaRef,
                cached: AudioEnhancer.cachedDenoisedURL,
                bake: AudioEnhancer.denoisedAudio
            )
        }
    }

    private func bakeEnhancement(
        mediaRef: String,
        key: String,
        cached: @Sendable (URL, String) -> URL?,
        bake: @escaping @Sendable (URL, String) async throws -> URL
    ) {
        guard !denoiseBaked.contains(key),
              !denoiseInFlight.contains(key), !denoiseFailed.contains(key),
              let url = mediaResolver.resolveURL(for: mediaRef)
        else { return }
        if cached(url, mediaRef) != nil {
            denoiseBaked.insert(key)
            return
        }
        denoiseInFlight.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            var failed = false
            do {
                _ = try await bake(url, mediaRef)
            } catch {
                failed = true
                Log.preview.error("audio enhance bake failed mediaRef=\(mediaRef): \(error.localizedDescription)")
            }
            await MainActor.run { [self] in
                guard let self else { return }
                self.denoiseInFlight.remove(key)
                if failed {
                    self.denoiseFailed.insert(key)
                } else {
                    self.denoiseBaked.insert(key)
                    // Rebuild to pick up the baked audio without pausing active playback.
                    self.videoEngine?.rebuild()
                }
            }
        }
    }
}
