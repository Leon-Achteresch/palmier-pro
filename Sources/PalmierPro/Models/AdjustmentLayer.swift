import Foundation

enum AdjustmentLayer {
    static let displayName = "Adjustment Layer"
    static let defaultDurationSeconds: Double = 5.0

    static func clip(startFrame: Int, durationFrames: Int) -> Clip {
        Clip(
            mediaRef: "",
            mediaType: .adjustment,
            sourceClipType: .adjustment,
            startFrame: max(0, startFrame),
            durationFrames: max(1, durationFrames)
        )
    }
}

extension Clip {
    var isAdjustmentLayer: Bool { mediaType == .adjustment }

    var adjustmentEffects: [Effect] {
        guard isAdjustmentLayer else { return [] }
        return (effects ?? []).filter(\.enabled)
    }
}
