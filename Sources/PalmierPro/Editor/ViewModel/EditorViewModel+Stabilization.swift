import Foundation

extension EditorViewModel {

    func stabilizationWriteTargets(
        clipIds: Set<String>,
        enabled: Bool,
        smoothing: Double? = nil
    ) -> Set<String> {
        let fps = timeline.fps
        return clipIds.filter { id in
            guard let clip = clipFor(id: id) else { return false }
            guard enabled else { return clip.stabilization != nil }
            let strength = ClipStabilization.clampedSmoothing(
                smoothing ?? clip.stabilization?.smoothing ?? ClipStabilization.defaultSmoothing
            )
            return !clip.stabilizationMatches(smoothing: strength, fps: fps)
        }
    }

    func stabilizationRetryTargets(clipIds: Set<String>, smoothing: Double? = nil) -> Set<String> {
        clipIds.filter { id in
            guard stabilizationJobs.job(forClip: id)?.state == .failed else { return false }
            return !stabilizationWriteTargets(clipIds: [id], enabled: true, smoothing: smoothing).contains(id)
        }
    }

    @discardableResult
    func setStabilization(
        clipIds: Set<String>,
        enabled: Bool,
        smoothing: Double? = nil,
        actionName: String
    ) -> Set<String> {
        let writes = stabilizationWriteTargets(clipIds: clipIds, enabled: enabled, smoothing: smoothing)
        let retries = enabled ? stabilizationRetryTargets(clipIds: clipIds, smoothing: smoothing) : []
        for id in writes.union(retries) { stabilizationJobs.forget(clipId: id) }
        if !writes.isEmpty {
            mutateClips(ids: writes, actionName: actionName) { clip in
                guard enabled else {
                    clip.stabilization = nil
                    return
                }
                clip.stabilization = .requested(smoothing: ClipStabilization.clampedSmoothing(
                    smoothing ?? clip.stabilization?.smoothing ?? ClipStabilization.defaultSmoothing
                ))
            }
        }
        resumePendingStabilizations()
        return writes
    }

    func resumePendingStabilizations() {
        var requested: Set<String> = []
        for candidate in timelines {
            for track in candidate.tracks {
                for clip in track.clips where clip.stabilization != nil {
                    requested.insert(clip.id)
                    startStabilizationIfNeeded(for: clip, fps: candidate.fps)
                }
            }
        }
        stabilizationJobs.forgetAll(except: requested)
    }

    func startStabilizationIfNeeded(for clip: Clip, fps: Int) {
        guard let request = clip.stabilization else { return }
        guard !request.isAnalyzed || clip.stabilizationIsStale(fps: fps) else { return }
        guard !stabilizationJobs.hasTask(forClip: clip.id) else { return }
        let signature = clip.stabilizationSignature(fps: fps)
        if let previous = stabilizationJobs.job(forClip: clip.id),
           previous.signature == signature, previous.state == .failed { return }

        let clipId = clip.id
        let snapshot = clip
        let resolver = mediaResolver.snapshot()
        stabilizationJobs.begin(
            clipId: clipId,
            mediaRef: clip.mediaRef,
            smoothing: request.smoothing,
            signature: signature
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let analysis = try await StabilizationAnalyzer.request(
                    for: snapshot, resolver: resolver, fps: fps
                )
                let result = try await StabilizationAnalyzer.analyze(analysis) { fraction in
                    Task { @MainActor [weak self] in
                        self?.stabilizationJobs.report(progress: fraction, forClip: clipId)
                    }
                }
                try Task.checkCancellation()
                self.commitStabilization(result, clipId: clipId, signature: signature)
            } catch is CancellationError {
                return
            } catch {
                self.stabilizationJobs.fail(clipId: clipId, reason: error.localizedDescription)
                Log.preview.error("stabilize failed clipId=\(clipId): \(error.localizedDescription)")
            }
        }
        stabilizationJobs.track(task, forClip: clipId)
    }

    private func commitStabilization(_ result: ClipStabilization, clipId: String, signature: String) {
        guard let location = stabilizationLocation(ofClip: clipId) else { return }
        let clip = timelines[location.timeline].tracks[location.track].clips[location.clip]
        guard clip.stabilization != nil,
              clip.stabilizationSignature(fps: timelines[location.timeline].fps) == signature else { return }
        timelines[location.timeline].tracks[location.track].clips[location.clip].stabilization = result
        stabilizationJobs.complete(
            clipId: clipId,
            cropPercent: result.cropPercent,
            analyzedSeconds: result.startSourceSeconds...max(result.startSourceSeconds, result.endSourceSeconds)
        )
        videoEngine?.refreshVisuals()
    }

    private func stabilizationLocation(ofClip id: String) -> (timeline: Int, track: Int, clip: Int)? {
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                if let ci = timelines[ti].tracks[tr].clips.firstIndex(where: { $0.id == id }) {
                    return (ti, tr, ci)
                }
            }
        }
        return nil
    }
}
