import Foundation

/// A transition needs both neighbours playing across its whole window, so each neighbour is
/// extended past the cut into its own handle. Extensions live on their own lane, never in the
/// timeline: they are derived from a `ResolvedTransition` on every build.
enum TransitionExtension {

    static func headClipId(_ transitionId: String) -> String { "\(transitionId)#head" }
    static func tailClipId(_ transitionId: String) -> String { "\(transitionId)#tail" }

    /// The incoming clip pulled back to cover `[window.start, cut)` out of its head handle.
    static func headExtension(of source: Clip, window: TransitionWindow, id: String) -> Clip? {
        let frames = window.headFrames
        guard frames > 0,
              let consumed = ClipTransition.sourceFrames(timelineFrames: frames, speed: source.speed)
        else { return nil }
        var clip = detached(source, id: id)
        clip.startFrame = window.startFrame
        clip.durationFrames = frames
        clip.trimStartFrame = max(0, source.trimStartFrame - consumed)
        clip.trimEndFrame = max(0, source.trimEndFrame + source.sourceFramesConsumed)
        clip.volumeTrack = source.volumeTrack?.rebased(by: -frames, fallback: 0)
        return clip
    }

    /// The outgoing clip carried on to cover `[cut, window.end)` out of its tail handle.
    static func tailExtension(of source: Clip, window: TransitionWindow, id: String) -> Clip? {
        let frames = window.tailFrames
        guard frames > 0,
              let consumed = ClipTransition.sourceFrames(timelineFrames: frames, speed: source.speed)
        else { return nil }
        var clip = detached(source, id: id)
        clip.startFrame = window.cutFrame
        clip.durationFrames = frames
        clip.trimStartFrame = max(0, source.trimStartFrame + source.sourceFramesConsumed)
        clip.trimEndFrame = max(0, source.trimEndFrame - consumed)
        clip.volumeTrack = source.volumeTrack?.rebased(by: source.durationFrames, fallback: 0)
        return clip
    }

    static func headClip(for resolved: ResolvedTransition) -> Clip? {
        silenced(headExtension(
            of: resolved.to, window: resolved.window, id: headClipId(resolved.transition.id)
        ))
    }

    static func tailClip(for resolved: ResolvedTransition) -> Clip? {
        silenced(tailExtension(
            of: resolved.from, window: resolved.window, id: tailClipId(resolved.transition.id)
        ))
    }

    static func renderClip(_ clip: Clip) -> Clip {
        var out = clip
        out.fadeInFrames = 0
        out.fadeOutFrames = 0
        return out
    }

    static func extensionClips(for track: Track) -> [Clip] {
        track.resolvedTransitions
            .flatMap { [headClip(for: $0), tailClip(for: $0)].compactMap { $0 } }
            .sorted { $0.startFrame < $1.startFrame }
    }

    private static func detached(_ clip: Clip, id: String) -> Clip {
        var out = renderClip(clip)
        out.id = id
        out.linkGroupId = nil
        out.captionGroupId = nil
        out.multicamGroupId = nil
        return out
    }

    /// Video handles composite only; their audio side is owned by the audio crossfade lanes.
    private static func silenced(_ clip: Clip?) -> Clip? {
        guard var clip else { return nil }
        clip.volume = 0
        clip.volumeTrack = nil
        return clip
    }
}
