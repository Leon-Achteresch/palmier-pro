import Foundation

enum TransitionExtension {

    static func headClipId(_ transitionId: String) -> String { "\(transitionId)#head" }
    static func tailClipId(_ transitionId: String) -> String { "\(transitionId)#tail" }

    static func headClip(for resolved: ResolvedTransition) -> Clip? {
        let frames = resolved.window.headFrames
        guard frames > 0,
              let consumed = ClipTransition.sourceFrames(timelineFrames: frames, speed: resolved.to.speed)
        else { return nil }
        var clip = stripped(resolved.to)
        clip.id = headClipId(resolved.transition.id)
        clip.startFrame = resolved.window.startFrame
        clip.durationFrames = frames
        clip.trimStartFrame = max(0, resolved.to.trimStartFrame - consumed)
        clip.trimEndFrame = max(0, resolved.to.trimEndFrame + resolved.to.sourceFramesConsumed)
        return clip
    }

    static func tailClip(for resolved: ResolvedTransition) -> Clip? {
        let frames = resolved.window.tailFrames
        guard frames > 0,
              let consumed = ClipTransition.sourceFrames(timelineFrames: frames, speed: resolved.from.speed)
        else { return nil }
        var clip = stripped(resolved.from)
        clip.id = tailClipId(resolved.transition.id)
        clip.startFrame = resolved.window.cutFrame
        clip.durationFrames = frames
        clip.trimStartFrame = max(0, resolved.from.trimStartFrame + resolved.from.sourceFramesConsumed)
        clip.trimEndFrame = max(0, resolved.from.trimEndFrame - consumed)
        return clip
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

    private static func stripped(_ clip: Clip) -> Clip {
        var out = renderClip(clip)
        out.linkGroupId = nil
        out.captionGroupId = nil
        out.multicamGroupId = nil
        out.volume = 0
        return out
    }
}
