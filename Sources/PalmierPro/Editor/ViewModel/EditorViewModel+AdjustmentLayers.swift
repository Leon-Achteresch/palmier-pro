import Foundation

extension EditorViewModel {
    struct AdjustmentLayerSpec: Sendable {
        let trackIndex: Int
        let startFrame: Int
        let durationFrames: Int
    }

    @discardableResult
    func placeAdjustmentLayers(_ specs: [AdjustmentLayerSpec], refreshVisuals: Bool = true) -> [String] {
        guard !specs.isEmpty else { return [] }
        var createdIds = [String?](repeating: nil, count: specs.count)
        let orderedIndices = Dictionary(grouping: specs.indices, by: { specs[$0].trackIndex })
            .values.flatMap { indices in
                indices.sorted { specs[$0].startFrame < specs[$1].startFrame }
            }

        for i in orderedIndices {
            let spec = specs[i]
            guard timeline.tracks.indices.contains(spec.trackIndex) else { continue }
            let clip = AdjustmentLayer.clip(startFrame: spec.startFrame, durationFrames: spec.durationFrames)
            clearRegion(trackIndex: spec.trackIndex, start: clip.startFrame, end: clip.endFrame, prune: false)
            timeline.tracks[spec.trackIndex].clips.append(clip)
            createdIds[i] = clip.id
        }

        for i in Set(specs.map(\.trackIndex)) where timeline.tracks.indices.contains(i) {
            sortClips(trackIndex: i)
        }
        if refreshVisuals {
            videoEngine?.refreshVisuals()
        }
        return createdIds.compactMap { $0 }
    }

    @discardableResult
    func addAdjustmentLayer() -> String? {
        let span = adjustmentLayerSpan()
        var clipId: String?
        withTimelineSwap(actionName: "Add Adjustment Layer") {
            let trackIndex = insertTrack(at: 0, type: .video)
            clipId = placeAdjustmentLayers(
                [.init(trackIndex: trackIndex, startFrame: span.start, durationFrames: span.duration)],
                refreshVisuals: false
            ).first
        }
        if let clipId { selectedClipIds = [clipId] }
        return clipId
    }

    private func adjustmentLayerSpan() -> (start: Int, duration: Int) {
        if let range = validSelectedTimelineRange {
            return (range.startFrame, range.endFrame - range.startFrame)
        }
        let selected = timeline.tracks
            .flatMap(\.clips)
            .filter { selectedClipIds.contains($0.id) && $0.durationFrames > 0 }
        if let start = selected.map(\.startFrame).min(), let end = selected.map(\.endFrame).max(), end > start {
            return (start, end - start)
        }
        let fallback = max(1, secondsToFrame(seconds: AdjustmentLayer.defaultDurationSeconds, fps: timeline.fps))
        return (max(0, activeFrame), fallback)
    }
}
