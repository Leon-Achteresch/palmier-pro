import AVFoundation

enum TimelineLoudness {
    struct EmptyAudioError: LocalizedError {
        var errorDescription: String? { "No audio in the measured range." }
    }

    @MainActor
    static func measure(
        timeline: Timeline,
        resolver: MediaResolver,
        resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        missingMediaRefs: Set<String>,
        frameRange: Range<Int>? = nil
    ) async throws -> LoudnessMeasurement {
        guard timeline.fps > 0 else { throw EmptyAudioError() }
        let audioOnly = audioOnlyTimeline(timeline)
        guard audioOnly.tracks.contains(where: { !$0.clips.isEmpty }) else { throw EmptyAudioError() }
        let mediaURLs = resolver.expectedURLMap()
        let renderSize = CGSize(width: timeline.width, height: timeline.height)

        let result = try await CompositionBuilder.build(
            timeline: audioOnly,
            resolveURL: { mediaURLs[$0] },
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            renderSize: renderSize
        )
        for track in result.composition.tracks(withMediaType: .video) {
            result.composition.removeTrack(track)
        }
        let timescale = CMTimeScale(timeline.fps)
        let timeRange = frameRange.map {
            CMTimeRange(
                start: CMTime(value: CMTimeValue($0.lowerBound), timescale: timescale),
                duration: CMTime(value: CMTimeValue($0.count), timescale: timescale)
            )
        }
        guard let snapshot = result.composition.copy() as? AVComposition,
              let mix = result.audioMix.copy() as? AVAudioMix else {
            throw EmptyAudioError()
        }
        return try await LoudnessAnalyzer.measure(
            LoudnessAnalyzer.Input(asset: snapshot, audioMix: mix, timeRange: timeRange)
        )
    }

    @MainActor
    static func measure(
        clip: Clip,
        timeline: Timeline,
        resolver: MediaResolver,
        resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        missingMediaRefs: Set<String>
    ) async throws -> LoudnessMeasurement {
        var isolated = clip
        isolated.startFrame = 0
        var soloTimeline = timeline
        soloTimeline.tracks = [Track(type: .audio, clips: [isolated])]
        return try await measure(
            timeline: soloTimeline,
            resolver: resolver,
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs
        )
    }

    private static func audioOnlyTimeline(_ timeline: Timeline) -> Timeline {
        var copy = timeline
        copy.tracks = timeline.tracks.filter { $0.type == .audio }
        return copy
    }
}
