import Foundation

extension EditorViewModel {

    enum TrimScope: String, CaseIterable, Sendable {
        case both
        case videoOnly
        case audioOnly

        func includes(_ clip: Clip) -> Bool {
            switch self {
            case .both: true
            case .videoOnly: clip.mediaType != .audio
            case .audioOnly: clip.mediaType == .audio
            }
        }

        var lane: String {
            switch self {
            case .both: "linked"
            case .videoOnly: "picture"
            case .audioOnly: "audio"
            }
        }
    }

    func asymmetricTrimScope(forDragOn clip: Clip) -> TrimScope {
        clip.mediaType == .audio ? .audioOnly : .videoOnly
    }

    func trimTargets(clipId: String, scope: TrimScope, propagateToLinked: Bool) -> [Clip] {
        guard let lead = clipFor(id: clipId) else { return [] }
        var group = [lead]
        if propagateToLinked || scope != .both {
            group += linkedPartnerIds(of: clipId).compactMap { clipFor(id: $0) }
        }
        return group.filter { scope.includes($0) }
    }

    func trimTargetIds(clipId: String, scope: TrimScope, propagateToLinked: Bool) -> Set<String> {
        Set(trimTargets(clipId: clipId, scope: scope, propagateToLinked: propagateToLinked).map(\.id))
    }

    func trimHandle(for clip: Clip, edge: TrimEdge, respectingMulticam: Bool = true) -> Int {
        if respectingMulticam, let bounds = multicamTrimBounds(for: clip) {
            return edge == .left ? bounds.left : bounds.right
        }
        return edge == .left ? clip.trimStartFrame : effectiveTrimEnd(for: clip)
    }

    func trimHandles(for targets: [Clip], respectingMulticam: Bool) -> (left: Int, right: Int) {
        var left = Int.max
        var right = Int.max
        for clip in targets {
            left = min(left, trimHandle(for: clip, edge: .left, respectingMulticam: respectingMulticam))
            right = min(right, trimHandle(for: clip, edge: .right, respectingMulticam: respectingMulticam))
        }
        return (left, right)
    }

    func trimRefusal(clipId: String, edge: TrimEdge, deltaFrames: Int, scope: TrimScope) -> String? {
        guard clipFor(id: clipId) != nil else { return "Clip not found: \(clipId)." }
        let targets = trimTargets(clipId: clipId, scope: scope, propagateToLinked: true)
        guard !targets.isEmpty else {
            return "No \(scope.lane) clip is linked to \(clipId)."
        }
        if let multicam = targets.first(where: { $0.multicamGroupId != nil }) {
            return "Trimming \(multicam.id) would slip a multicam clip out of sync — switch angles with change_cam instead."
        }
        let shortens = edge == .left ? deltaFrames > 0 : deltaFrames < 0
        let magnitude = abs(deltaFrames)
        for clip in targets {
            if shortens {
                guard magnitude <= clip.durationFrames - 1 else {
                    return "Trimming \(magnitude) frames off \(clip.id) would leave less than 1 frame "
                        + "— at most \(max(0, clip.durationFrames - 1)) frames can come off."
                }
                continue
            }
            guard clip.mediaType != .image, !clip.mediaType.isSourcelessLayer else { continue }
            let sourceDelta = Int((Double(magnitude) * clip.speed).rounded())
            let handle = trimHandle(for: clip, edge: edge)
            guard sourceDelta <= handle else {
                return "Not enough source media on \(clip.id) to extend \(magnitude) frames "
                    + "— only \(handle) source frames of handle remain."
            }
        }
        return nil
    }
}
