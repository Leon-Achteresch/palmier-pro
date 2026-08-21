import Foundation

enum TransitionStyle: String, Codable, Sendable, CaseIterable {
    case crossDissolve
    case dipToBlack
    case dipToWhite
    case wipe
    case slide
    case push

    var requiresDirection: Bool {
        switch self {
        case .wipe, .slide, .push: true
        case .crossDissolve, .dipToBlack, .dipToWhite: false
        }
    }

    var displayName: String {
        switch self {
        case .crossDissolve: "Cross Dissolve"
        case .dipToBlack: "Dip to Black"
        case .dipToWhite: "Dip to White"
        case .wipe: "Wipe"
        case .slide: "Slide"
        case .push: "Push"
        }
    }
}

enum TransitionDirection: String, Codable, Sendable, CaseIterable {
    case left, right, up, down
}

enum TransitionAlignment: String, Codable, Sendable, CaseIterable {
    case centered, startAtCut, endAtCut
}

struct ClipTransition: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var style: TransitionStyle
    var direction: TransitionDirection?
    var durationFrames: Int
    var alignment: TransitionAlignment = .centered
    var fromClipId: String
    var toClipId: String
}

struct TransitionWindow: Sendable, Equatable {
    let cutFrame: Int
    let startFrame: Int
    let durationFrames: Int

    var endFrame: Int { startFrame + durationFrames }
    var headFrames: Int { cutFrame - startFrame }
    var tailFrames: Int { endFrame - cutFrame }

    func contains(frame: Int) -> Bool { frame >= startFrame && frame < endFrame }

    func overlaps(_ other: TransitionWindow) -> Bool {
        startFrame < other.endFrame && other.startFrame < endFrame
    }

    func progress(at frame: Int) -> Double {
        guard durationFrames > 0 else { return 1 }
        let t = (Double(frame - startFrame) + 0.5) / Double(durationFrames)
        return min(1, max(0, t))
    }
}

struct ResolvedTransition: Sendable, Equatable {
    let transition: ClipTransition
    let from: Clip
    let to: Clip
    let window: TransitionWindow

    var id: String { transition.id }
}

enum TransitionRefusal: Error, Equatable, Sendable {
    case notOnVideoTrack
    case clipNotFound(String)
    case clipsOnDifferentTracks
    case sameClip
    case invalidDuration(Int)
    case missingDirection(TransitionStyle)
    case unexpectedDirection(TransitionStyle)
    case unsupportedMedia(clipId: String, mediaType: ClipType)
    case invalidSpeed(clipId: String)
    case notAdjacent(fromEndFrame: Int, toStartFrame: Int)
    case windowExceedsClip(clipId: String, neededFrames: Int, availableFrames: Int)
    case insufficientHandles(clipId: String, neededSourceFrames: Int, availableSourceFrames: Int)
    case fadeOnCutEdge(clipId: String)
    case blendModeOnNeighbour(clipId: String)
    case cutAlreadyHasTransition(String)
    case overlapsTransition(String)

    var code: String {
        switch self {
        case .notOnVideoTrack: "not_on_video_track"
        case .clipNotFound: "clip_not_found"
        case .clipsOnDifferentTracks: "clips_on_different_tracks"
        case .sameClip: "same_clip"
        case .invalidDuration: "invalid_duration"
        case .missingDirection: "missing_direction"
        case .unexpectedDirection: "unexpected_direction"
        case .unsupportedMedia: "unsupported_media"
        case .invalidSpeed: "invalid_speed"
        case .notAdjacent: "not_adjacent"
        case .windowExceedsClip: "window_exceeds_clip"
        case .insufficientHandles: "insufficient_handles"
        case .fadeOnCutEdge: "fade_on_cut_edge"
        case .blendModeOnNeighbour: "blend_mode_on_neighbour"
        case .cutAlreadyHasTransition: "cut_already_has_transition"
        case .overlapsTransition: "overlaps_transition"
        }
    }

    var message: String {
        switch self {
        case .notOnVideoTrack:
            "Transitions attach to a cut on a video track."
        case .clipNotFound(let id):
            "Clip not found: \(id)."
        case .clipsOnDifferentTracks:
            "Both clips must live on the same video track."
        case .sameClip:
            "fromClipId and toClipId must be two different clips."
        case .invalidDuration(let frames):
            "durationFrames \(frames) is out of range — use \(ClipTransition.minimumDurationFrames)…\(ClipTransition.maximumDurationFrames) frames."
        case .missingDirection(let style):
            "Style '\(style.rawValue)' requires a direction (left, right, up, down)."
        case .unexpectedDirection(let style):
            "Style '\(style.rawValue)' takes no direction."
        case .unsupportedMedia(let id, let type):
            "Clip \(id) is '\(type.rawValue)' media; transitions support video, image, and lottie clips."
        case .invalidSpeed(let id):
            "Clip \(id) has an unusable speed."
        case .notAdjacent(let fromEnd, let toStart):
            "Clips are not adjacent — the outgoing clip ends at \(fromEnd) but the incoming clip starts at \(toStart). Close the gap or overlap first."
        case .windowExceedsClip(let id, let needed, let available):
            "The transition needs \(needed) frames inside clip \(id), which is only \(available) frames long. Shorten the transition or lengthen the clip."
        case .insufficientHandles(let id, let needed, let available):
            "Clip \(id) has \(available) source frames of handle where the transition needs \(needed). Trim the clip back to expose more media, or shorten the transition."
        case .fadeOnCutEdge(let id):
            "Clip \(id) has a fade on the cut edge. Remove the fade before adding a transition."
        case .blendModeOnNeighbour(let id):
            "Clip \(id) uses a blend mode; transitions composite source-over. Reset the blend mode first."
        case .cutAlreadyHasTransition(let id):
            "That cut already carries transition \(id). Remove it before adding another."
        case .overlapsTransition(let id):
            "The requested span overlaps transition \(id) on the same track. Shorten one of them."
        }
    }
}

extension ClipTransition {
    static let minimumDurationFrames = 2
    static let maximumDurationFrames = 3600

    func window(cutFrame: Int) -> TransitionWindow {
        let head: Int
        switch alignment {
        case .centered: head = durationFrames / 2
        case .startAtCut: head = 0
        case .endAtCut: head = durationFrames
        }
        return TransitionWindow(cutFrame: cutFrame, startFrame: cutFrame - head, durationFrames: durationFrames)
    }

    static func sourceFrames(timelineFrames: Int, speed: Double) -> Int? {
        guard timelineFrames >= 0, speed.isFinite, speed > 0 else { return nil }
        let raw = (Double(timelineFrames) * speed).rounded(.up)
        guard raw.isFinite, raw <= Double(Int.max / 2) else { return nil }
        return Int(raw)
    }
}

extension Clip {
    var hasBoundedSourceHandles: Bool {
        switch mediaType {
        case .video, .audio, .sequence, .motion: true
        case .image, .lottie, .text, .adjustment: false
        }
    }

    var supportsTransitions: Bool {
        switch mediaType {
        case .video, .image, .lottie, .motion: true
        case .audio, .text, .sequence, .adjustment: false
        }
    }

    var headHandleSourceFrames: Int {
        hasBoundedSourceHandles ? max(0, trimStartFrame) : Int.max
    }

    var tailHandleSourceFrames: Int {
        hasBoundedSourceHandles ? max(0, trimEndFrame) : Int.max
    }
}

extension Track {
    var resolvedTransitions: [ResolvedTransition] {
        guard !transitions.isEmpty else { return [] }
        var accepted: [ResolvedTransition] = []
        for transition in transitions {
            guard let resolved = try? resolve(transition, against: accepted) else { continue }
            accepted.append(resolved)
        }
        return accepted.sorted { $0.window.startFrame < $1.window.startFrame }
    }

    func resolvedTransition(id: String) -> ResolvedTransition? {
        resolvedTransitions.first { $0.id == id }
    }

    func resolve(_ transition: ClipTransition, against others: [ResolvedTransition]) throws(TransitionRefusal) -> ResolvedTransition {
        guard type == .video else { throw TransitionRefusal.notOnVideoTrack }
        guard transition.durationFrames >= ClipTransition.minimumDurationFrames,
              transition.durationFrames <= ClipTransition.maximumDurationFrames else {
            throw TransitionRefusal.invalidDuration(transition.durationFrames)
        }
        if transition.style.requiresDirection {
            guard transition.direction != nil else { throw TransitionRefusal.missingDirection(transition.style) }
        } else {
            guard transition.direction == nil else { throw TransitionRefusal.unexpectedDirection(transition.style) }
        }
        guard transition.fromClipId != transition.toClipId else { throw TransitionRefusal.sameClip }
        guard let from = clips.first(where: { $0.id == transition.fromClipId }) else {
            throw TransitionRefusal.clipNotFound(transition.fromClipId)
        }
        guard let to = clips.first(where: { $0.id == transition.toClipId }) else {
            throw TransitionRefusal.clipNotFound(transition.toClipId)
        }
        for clip in [from, to] {
            guard clip.supportsTransitions else {
                throw TransitionRefusal.unsupportedMedia(clipId: clip.id, mediaType: clip.mediaType)
            }
            guard clip.speed.isFinite, clip.speed > 0, clip.durationFrames > 0 else {
                throw TransitionRefusal.invalidSpeed(clipId: clip.id)
            }
            guard clip.blendMode == nil || clip.blendMode == .normal else {
                throw TransitionRefusal.blendModeOnNeighbour(clipId: clip.id)
            }
        }
        guard from.endFrame == to.startFrame else {
            throw TransitionRefusal.notAdjacent(fromEndFrame: from.endFrame, toStartFrame: to.startFrame)
        }
        guard from.fadeOutFrames == 0 else { throw TransitionRefusal.fadeOnCutEdge(clipId: from.id) }
        guard to.fadeInFrames == 0 else { throw TransitionRefusal.fadeOnCutEdge(clipId: to.id) }

        let window = transition.window(cutFrame: from.endFrame)
        guard window.headFrames <= from.durationFrames else {
            throw TransitionRefusal.windowExceedsClip(
                clipId: from.id, neededFrames: window.headFrames, availableFrames: from.durationFrames
            )
        }
        guard window.tailFrames <= to.durationFrames else {
            throw TransitionRefusal.windowExceedsClip(
                clipId: to.id, neededFrames: window.tailFrames, availableFrames: to.durationFrames
            )
        }
        guard let neededHead = ClipTransition.sourceFrames(timelineFrames: window.headFrames, speed: to.speed) else {
            throw TransitionRefusal.invalidSpeed(clipId: to.id)
        }
        guard neededHead <= to.headHandleSourceFrames else {
            throw TransitionRefusal.insufficientHandles(
                clipId: to.id, neededSourceFrames: neededHead, availableSourceFrames: to.headHandleSourceFrames
            )
        }
        guard let neededTail = ClipTransition.sourceFrames(timelineFrames: window.tailFrames, speed: from.speed) else {
            throw TransitionRefusal.invalidSpeed(clipId: from.id)
        }
        guard neededTail <= from.tailHandleSourceFrames else {
            throw TransitionRefusal.insufficientHandles(
                clipId: from.id, neededSourceFrames: neededTail, availableSourceFrames: from.tailHandleSourceFrames
            )
        }
        for other in others where other.id != transition.id {
            if other.transition.fromClipId == transition.fromClipId && other.transition.toClipId == transition.toClipId {
                throw TransitionRefusal.cutAlreadyHasTransition(other.id)
            }
            guard !other.window.overlaps(window) else {
                throw TransitionRefusal.overlapsTransition(other.id)
            }
        }
        return ResolvedTransition(transition: transition, from: from, to: to, window: window)
    }

    @discardableResult
    mutating func pruneInvalidTransitions() -> [ClipTransition] {
        guard !transitions.isEmpty else { return [] }
        let surviving = Set(resolvedTransitions.map(\.id))
        guard surviving.count != transitions.count else { return [] }
        let dropped = transitions.filter { !surviving.contains($0.id) }
        transitions.removeAll { !surviving.contains($0.id) }
        return dropped
    }
}

extension Timeline {
    var resolvedTransitions: [(trackIndex: Int, resolved: ResolvedTransition)] {
        tracks.enumerated().flatMap { index, track in
            track.resolvedTransitions.map { (index, $0) }
        }
    }

    func trackIndexOfTransition(id: String) -> Int? {
        tracks.firstIndex { $0.transitions.contains { $0.id == id } }
    }

    var transitionsByTrackId: [String: [ClipTransition]] {
        Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.transitions) })
    }

    mutating func applyTransitions(byTrackId map: [String: [ClipTransition]]) {
        for index in tracks.indices {
            guard let stored = map[tracks[index].id] else { continue }
            tracks[index].transitions = stored
        }
    }

    @discardableResult
    mutating func pruneInvalidTransitions() -> [ClipTransition] {
        var dropped: [ClipTransition] = []
        for index in tracks.indices where !tracks[index].transitions.isEmpty {
            dropped.append(contentsOf: tracks[index].pruneInvalidTransitions())
        }
        return dropped
    }
}
