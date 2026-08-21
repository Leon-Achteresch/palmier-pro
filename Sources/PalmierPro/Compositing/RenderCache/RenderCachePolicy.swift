import Foundation

enum RenderCachePolicy {
    static let memoryByteLimit = 1024 * 1024 * 1024
    static let diskByteLimit: Int64 = 2 * 1024 * 1024 * 1024
    static let framesPerSpanLimit = 300
    static let warmedFrameLimit = 900
    static let warmedSpanLimit = 24
    static let diskWriteBudgetPerPass = 256 * 1024 * 1024
    static let settleDelay = Duration.milliseconds(400)

    static let heavyEffectTypes: Set<String> = [
        "key.subject",
        "key.occlusion",
        "key.chroma",
        "transition.subjectReveal",
        "color.lut",
        "color.hueCurves",
        "color.curves",
        "color.wheels",
        "blur.gaussian",
        "blur.motion",
        "blur.noiseReduction",
        "blur.sharpen",
        "stylize.glow",
        "stylize.grain",
        "detail.clarity",
        "distort.warp",
        "distort.perspective",
        MeshWarp.effectType,
        CornerPin.effectType,
        "mockup.iphone17",
        "mockup.macbook",
    ]

    static let costThreshold = 4

    static func warmBudget(renderSize: CGSize) -> Int {
        let width = Int(renderSize.width.rounded()), height = Int(renderSize.height.rounded())
        guard width > 0, height > 0 else { return 0 }
        let frameBytes = width * height * 4
        return max(1, min(warmedFrameLimit, memoryByteLimit / frameBytes))
    }

    static func isWorthCaching(layers: [LayerPlan]) -> Bool {
        cost(of: layers) >= costThreshold
    }

    static func cost(of layers: [LayerPlan]) -> Int {
        var total = 0
        for layer in layers {
            total += cost(of: layer)
            if total >= costThreshold * 4 { return total }
        }
        return total
    }

    private static func cost(of layer: LayerPlan) -> Int {
        var total = clipCost(layer.clip)
        switch layer.source {
        case .track, .text:
            break
        case .adjustment:
            total += 2
        case .group(let children, _):
            total += 2
            for child in children { total += cost(of: child) }
        case .transition(let from, let to, _):
            total += 3
            total += cost(of: from)
            total += cost(of: to)
        }
        return total
    }

    private static func clipCost(_ clip: Clip) -> Int {
        var total = 0
        for effect in clip.effects ?? [] where effect.enabled {
            total += heavyEffectTypes.contains(effect.type) ? 3 : 1
        }
        if clip.blendMode?.ciFilterName != nil { total += 1 }
        return total
    }
}
