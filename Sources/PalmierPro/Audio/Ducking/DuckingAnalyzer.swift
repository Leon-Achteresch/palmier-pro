import Foundation

enum AudioClipRole: String, Sendable, Equatable, CaseIterable {
    case dialog
    case bed
    case sfx
    case exempt
}

enum DuckingAnalyzer {
    static let sfxMaxSeconds: Double = 2.0

    static func mixableClips(in timeline: Timeline) -> [(trackIndex: Int, clip: Clip)] {
        var out: [(Int, Clip)] = []
        for (index, track) in timeline.tracks.enumerated() where track.type == .audio && !track.muted {
            for clip in track.clips
            where clip.mediaType == .audio && clip.sourceClipType != .sequence && clip.durationFrames > 0 {
                out.append((index, clip))
            }
        }
        return out
    }

    static func speechRanges(clip: Clip, spans: [VoiceActivity.Span], fps: Int) -> [FrameRange] {
        guard fps > 0 else { return [] }
        return spans.compactMap { span in
            guard span.end > span.start else { return nil }
            return clip.timelineRange(
                sourceStartFrame: span.start * Double(fps),
                sourceEndFrame: span.end * Double(fps)
            )
        }
    }

    static func speechCoverage(clip: Clip, spans: [VoiceActivity.Span], fps: Int) -> Double {
        guard clip.durationFrames > 0 else { return 0 }
        let clipRange = FrameRange(start: clip.startFrame, end: clip.endFrame)
        let merged = DuckingPlan.mergedSpeech(speechRanges(clip: clip, spans: spans, fps: fps), bridgeFrames: 0)
        let covered = merged.reduce(0) { total, range in
            total + max(0, min(range.end, clipRange.end) - max(range.start, clipRange.start))
        }
        return Double(covered) / Double(clip.durationFrames)
    }

    static func role(for clip: Clip, speechCoverage: Double?, fps: Int) -> AudioClipRole? {
        switch clip.duckingRole {
        case .dialog: return .dialog
        case .bed: return .bed
        case .exempt: return .exempt
        case .auto: break
        }
        guard let speechCoverage else { return nil }
        if speechCoverage >= DuckingLimits.dialogSpeechCoverage { return .dialog }
        guard fps > 0 else { return .bed }
        return Double(clip.durationFrames) / Double(fps) < sfxMaxSeconds ? .sfx : .bed
    }

    struct Analysis: Sendable {
        var spansByMediaRef: [String: [VoiceActivity.Span]] = [:]
        var rolesByClipId: [String: AudioClipRole] = [:]
        var coverageByClipId: [String: Double] = [:]
        var unanalyzedMediaRefs: Set<String> = []
    }

    static func analyze(timeline: Timeline, spansByMediaRef: [String: [VoiceActivity.Span]]) -> Analysis {
        var analysis = Analysis(spansByMediaRef: spansByMediaRef)
        for (_, clip) in mixableClips(in: timeline) {
            guard let spans = spansByMediaRef[clip.mediaRef] else {
                analysis.unanalyzedMediaRefs.insert(clip.mediaRef)
                if let explicit = role(for: clip, speechCoverage: nil, fps: timeline.fps) {
                    analysis.rolesByClipId[clip.id] = explicit
                }
                continue
            }
            let coverage = speechCoverage(clip: clip, spans: spans, fps: timeline.fps)
            analysis.coverageByClipId[clip.id] = coverage
            if let resolved = role(for: clip, speechCoverage: coverage, fps: timeline.fps) {
                analysis.rolesByClipId[clip.id] = resolved
            }
        }
        return analysis
    }

    static func plan(timeline: Timeline, analysis: Analysis) -> DuckingPlan {
        let settings = timeline.ducking.normalized
        guard settings.enabled, timeline.fps > 0 else { return .empty }
        let clips = mixableClips(in: timeline)
        guard !clips.isEmpty else { return .empty }

        var speech: [FrameRange] = []
        for (_, clip) in clips where analysis.rolesByClipId[clip.id] == .dialog {
            guard let spans = analysis.spansByMediaRef[clip.mediaRef] else { continue }
            speech.append(contentsOf: speechRanges(clip: clip, spans: spans, fps: timeline.fps))
        }
        let bridgeFrames = settings.frames(forMilliseconds: settings.holdMs, fps: timeline.fps)
        let merged = DuckingPlan.mergedSpeech(speech, bridgeFrames: bridgeFrames)
        guard !merged.isEmpty else { return .empty }

        let attackFrames = settings.frames(forMilliseconds: settings.attackMs, fps: timeline.fps)
        let releaseFrames = settings.frames(forMilliseconds: settings.releaseMs, fps: timeline.fps)
        var curves: [String: DuckingCurve] = [:]
        for (_, clip) in clips where analysis.rolesByClipId[clip.id] == .bed {
            let intervals = DuckingPlan.intervals(
                forSpeech: merged,
                clipRange: FrameRange(start: clip.startFrame, end: clip.endFrame),
                attackFrames: attackFrames,
                releaseFrames: releaseFrames
            )
            guard !intervals.isEmpty else { continue }
            curves[clip.id] = DuckingCurve(intervals: intervals, depthGain: settings.depthGain)
        }
        return DuckingPlan(curvesByClipId: curves)
    }

    @concurrent
    static func cachedSpeechSpans(
        for timeline: Timeline,
        resolveURL: @Sendable (String) -> URL?
    ) async -> [String: [VoiceActivity.Span]] {
        var out: [String: [VoiceActivity.Span]] = [:]
        for mediaRef in Set(mixableClips(in: timeline).map(\.clip.mediaRef)) {
            guard let url = resolveURL(mediaRef),
                  let analysis = VoiceActivity.cachedAnalysis(for: url, mediaRef: mediaRef) else { continue }
            out[mediaRef] = analysis.segments
        }
        return out
    }

    static func cachedPlan(
        for timeline: Timeline,
        resolveURL: @escaping @Sendable (String) -> URL?
    ) async -> DuckingPlan {
        guard timeline.ducking.enabled else { return .empty }
        let spans = await cachedSpeechSpans(for: timeline, resolveURL: resolveURL)
        guard !spans.isEmpty else { return .empty }
        return plan(timeline: timeline, analysis: analyze(timeline: timeline, spansByMediaRef: spans))
    }
}
