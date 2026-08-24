import CoreGraphics
import Foundation

/// Expands a nest carrier one level: child clips remapped into parent frames.
enum NestFlattener {
    static let maxDepth = 8

    struct Flattened: Sendable {
        /// Child visual tracks, child track order preserved (text clips and transitions included).
        var videoTracks: [Track] = []
        /// Unmuted child audio tracks; clips within a track never overlap.
        var audioTracks: [[Clip]] = []
        var childCanvas: CGSize = .zero
    }

    /// `carrier` = the video `.sequence` clip or its linked audio clip.
    static func flatten(carrier: Clip, child: Timeline, visual: Bool) -> Flattened {
        var out = Flattened()
        out.childCanvas = CGSize(width: child.width, height: child.height)
        let window = carrier.trimStartFrame..<(carrier.trimStartFrame + carrier.durationFrames)
        let shift = carrier.startFrame - carrier.trimStartFrame

        for track in child.tracks {
            if visual {
                guard track.type == .video, !track.hidden else { continue }
                let clips = track.clips
                    .sorted { $0.startFrame < $1.startFrame }
                    .compactMap { remap($0, window: window, shift: shift, nestId: carrier.id) }
                if !clips.isEmpty {
                    var flat = track
                    flat.id = nestScoped(track.id, nestId: carrier.id)
                    flat.clips = clips
                    flat.transitions = remapTransitions(
                        track.transitions, nestId: carrier.id, survivors: Set(clips.map(\.id))
                    )
                    out.videoTracks.append(flat)
                }
            } else {
                guard track.type == .audio, !track.muted else { continue }
                let clips = track.clips
                    .sorted { $0.startFrame < $1.startFrame }
                    .compactMap { remap($0, window: window, shift: shift, nestId: carrier.id) }
                if !clips.isEmpty { out.audioTracks.append(clips) }
            }
        }
        return out
    }

    /// Unique per nest instance so the same child nested twice can't collide.
    private static func nestScoped(_ id: String, nestId: String) -> String { "\(nestId)/\(id)" }

    /// Transitions follow their clips into the parent. A transition whose neighbour fell outside the
    /// carrier window is dropped here; the rest are re-validated by `Track.resolve` like any other.
    private static func remapTransitions(
        _ transitions: [ClipTransition], nestId: String, survivors: Set<String>
    ) -> [ClipTransition] {
        transitions.compactMap { transition in
            var out = transition
            out.id = nestScoped(transition.id, nestId: nestId)
            out.fromClipId = nestScoped(transition.fromClipId, nestId: nestId)
            out.toClipId = nestScoped(transition.toClipId, nestId: nestId)
            guard survivors.contains(out.fromClipId), survivors.contains(out.toClipId) else { return nil }
            return out
        }
    }

    private static func remap(_ clip: Clip, window: Range<Int>, shift: Int, nestId: String) -> Clip? {
        let start = max(clip.startFrame, window.lowerBound)
        let end = min(clip.endFrame, window.upperBound)
        guard end > start else { return nil }

        var c = clip
        let headCut = start - clip.startFrame
        if headCut > 0 {
            c.trimStartFrame += Int((Double(headCut) * c.speed).rounded())
            c.fadeInFrames = 0
            shiftKeyframeTracks(&c, by: headCut)
        }
        if end < clip.endFrame { c.fadeOutFrames = 0 }
        c.startFrame = start + shift
        c.durationFrames = end - start
        c.clampFadesToDuration()
        c.clampKeyframesToDuration()
        c.id = nestScoped(clip.id, nestId: nestId)
        return c
    }

    private static func shiftKeyframeTracks(_ clip: inout Clip, by headCut: Int) {
        clip.opacityTrack = clip.opacityTrack?.rebased(by: headCut, fallback: clip.opacity)
        clip.volumeTrack = clip.volumeTrack?.rebased(by: headCut, fallback: 0)
        clip.positionTrack = clip.positionTrack?.rebased(by: headCut, fallback: AnimPair(a: 0, b: 0))
        clip.scaleTrack = clip.scaleTrack?.rebased(by: headCut, fallback: AnimPair(a: 1, b: 1))
        clip.rotationTrack = clip.rotationTrack?.rebased(by: headCut, fallback: 0)
        clip.cropTrack = clip.cropTrack?.rebased(by: headCut, fallback: clip.crop)
        clip.speedTrack = clip.speedTrack?.rebased(by: headCut, fallback: clip.speed)
        clip.setBlurKeyframeTrack(
            clip.blurKeyframeTrack?.rebased(by: headCut, fallback: clip.staticBlurRadius)
        )
    }
}
