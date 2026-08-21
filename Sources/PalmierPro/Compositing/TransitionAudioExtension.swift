import Foundation

/// Which side of a cut a lane carries during a transition.
enum TransitionAudioRole: String, Sendable, Equatable {
    case outgoing
    case incoming
}

/// One handle lane clip and the transition side it plays for.
struct TransitionAudioHandle: Sendable, Equatable {
    let clip: Clip
    let transitionId: String
    let role: TransitionAudioRole
    /// The window this lane was cut for. A later refresh only ramps it when the window still matches.
    let window: TransitionWindow
}

/// One side of one transition window as a gain multiplier over absolute timeline frames.
struct TransitionGainCurve: Sendable, Equatable {
    let window: TransitionWindow
    let role: TransitionAudioRole

    func gain(atFrame frame: Int) -> Double {
        TransitionAudioExtension.equalPowerGain(role: role, window: window, frame: frame)
    }

    var breakpointFrames: [Int] { TransitionAudioExtension.breakpointFrames(in: window) }
}

/// A video transition hard-cuts the linked audio unless both neighbours can also be extended past
/// the cut. This resolves the audio side of an already-resolved video transition: the linked audio
/// clips, their handle lanes, and the equal-power gain each side follows across the window.
struct ResolvedAudioCrossfade: Sendable, Equatable {
    let transitionId: String
    let window: TransitionWindow
    let audioTrackIndex: Int
    let outgoing: Clip
    let incoming: Clip

    func curve(for role: TransitionAudioRole) -> TransitionGainCurve {
        TransitionGainCurve(window: window, role: role)
    }
}

enum TransitionAudioExtension {

    static func headClipId(_ transitionId: String) -> String { "\(transitionId)#audioHead" }
    static func tailClipId(_ transitionId: String) -> String { "\(transitionId)#audioTail" }

    /// Equal power: the two sides sum to constant acoustic power across the window, so a correlated
    /// pair does not dip in the middle the way a linear crossfade does.
    static func equalPowerGain(role: TransitionAudioRole, window: TransitionWindow, frame: Int) -> Double {
        guard window.durationFrames > 0 else { return role == .outgoing ? 0 : 1 }
        let raw = Double(frame - window.startFrame) / Double(window.durationFrames)
        let progress = min(1, max(0, raw))
        let angle = progress * .pi / 2
        return role == .outgoing ? cos(angle) : sin(angle)
    }

    static func breakpointFrames(in window: TransitionWindow) -> [Int] {
        guard window.durationFrames > 0 else { return [] }
        let interior = CompositionBuilder.smoothSubdivisions(from: window.startFrame, to: window.endFrame)
        return ([window.startFrame, window.endFrame] + interior).sorted()
    }

    /// Audio crossfades for every resolved video transition in `timeline` whose neighbours both
    /// carry linked audio that meets the cut cleanly and has enough handle on the far side.
    static func crossfades(in timeline: Timeline) -> [ResolvedAudioCrossfade] {
        let resolved = timeline.resolvedTransitions
        guard !resolved.isEmpty else { return [] }
        var byLinkGroup: [String: [(trackIndex: Int, clip: Clip)]] = [:]
        for (index, track) in timeline.tracks.enumerated() where track.type == .audio {
            for clip in track.clips {
                guard let group = clip.linkGroupId else { continue }
                byLinkGroup[group, default: []].append((index, clip))
            }
        }
        guard !byLinkGroup.isEmpty else { return [] }

        return resolved.compactMap { entry in
            crossfade(for: entry.resolved, linkedAudio: byLinkGroup)
        }
    }

    private static func crossfade(
        for resolved: ResolvedTransition,
        linkedAudio: [String: [(trackIndex: Int, clip: Clip)]]
    ) -> ResolvedAudioCrossfade? {
        guard let from = linkedPartner(of: resolved.from, in: linkedAudio),
              let to = linkedPartner(of: resolved.to, in: linkedAudio),
              from.trackIndex == to.trackIndex,
              from.clip.id != to.clip.id
        else { return nil }

        let window = resolved.window
        let outgoing = from.clip
        let incoming = to.clip
        guard outgoing.endFrame == window.cutFrame, incoming.startFrame == window.cutFrame else { return nil }
        guard outgoing.fadeOutFrames == 0, incoming.fadeInFrames == 0 else { return nil }
        for clip in [outgoing, incoming] {
            guard clip.durationFrames > 0, clip.speed.isFinite, clip.speed > 0 else { return nil }
            // A nest carrier's audio expands into child lanes; there is no single lane to extend.
            guard clip.sourceClipType != .sequence else { return nil }
            // A handle lane carries the dry source; a denoised neighbour would change timbre mid-fade.
            guard !clip.hasStudioVoiceEnabled, !(clip.hasDenoiseEnabled && clip.denoiseAmount > 0) else { return nil }
        }
        guard window.headFrames <= incoming.durationFrames, window.tailFrames <= outgoing.durationFrames else {
            return nil
        }
        guard let neededHead = ClipTransition.sourceFrames(timelineFrames: window.headFrames, speed: incoming.speed),
              neededHead <= incoming.headHandleSourceFrames,
              let neededTail = ClipTransition.sourceFrames(timelineFrames: window.tailFrames, speed: outgoing.speed),
              neededTail <= outgoing.tailHandleSourceFrames
        else { return nil }

        return ResolvedAudioCrossfade(
            transitionId: resolved.id,
            window: window,
            audioTrackIndex: from.trackIndex,
            outgoing: outgoing,
            incoming: incoming
        )
    }

    private static func linkedPartner(
        of clip: Clip, in linkedAudio: [String: [(trackIndex: Int, clip: Clip)]]
    ) -> (trackIndex: Int, clip: Clip)? {
        guard let group = clip.linkGroupId, let members = linkedAudio[group], members.count == 1 else { return nil }
        return members[0]
    }

    /// Handle lane clips for one audio track: the incoming audio pulled back before the cut and the
    /// outgoing audio carried past it, so both sides exist across the whole window.
    static func handles(forAudioTrackIndex index: Int, crossfades: [ResolvedAudioCrossfade]) -> [TransitionAudioHandle] {
        crossfades
            .filter { $0.audioTrackIndex == index }
            .flatMap { crossfade -> [TransitionAudioHandle] in
                var out: [TransitionAudioHandle] = []
                if let head = TransitionExtension.headExtension(
                    of: crossfade.incoming, window: crossfade.window, id: headClipId(crossfade.transitionId)
                ) {
                    out.append(TransitionAudioHandle(
                        clip: head, transitionId: crossfade.transitionId,
                        role: .incoming, window: crossfade.window
                    ))
                }
                if let tail = TransitionExtension.tailExtension(
                    of: crossfade.outgoing, window: crossfade.window, id: tailClipId(crossfade.transitionId)
                ) {
                    out.append(TransitionAudioHandle(
                        clip: tail, transitionId: crossfade.transitionId,
                        role: .outgoing, window: crossfade.window
                    ))
                }
                return out
            }
            .sorted { $0.clip.startFrame < $1.clip.startFrame }
    }
}
