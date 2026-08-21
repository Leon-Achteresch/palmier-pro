import AVFoundation

enum RenderCacheDigest {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let encoderLock = NSLock()

    static func span(for instruction: CompositorInstruction) -> RenderCacheSpan? {
        guard instruction.fps > 0,
              instruction.renderSize.width >= 1,
              instruction.renderSize.height >= 1,
              !instruction.layers.isEmpty,
              RenderCachePolicy.isWorthCaching(layers: instruction.layers),
              let frames = frameRange(of: instruction) else { return nil }

        var digest = StableDigest()
        digest.combine("ppr1")
        digest.combine(instruction.fps)
        digest.combine(instruction.renderSize)
        digest.combine(instruction.layers.count)
        for layer in instruction.layers {
            guard combine(layer, into: &digest) else { return nil }
        }
        return RenderCacheSpan(digest: digest.value, frames: frames)
    }

    static func frameRange(of instruction: CompositorInstruction) -> Range<Int>? {
        let range = instruction.timeRange
        guard range.isValid, !range.isEmpty,
              range.start.isNumeric, range.end.isNumeric,
              range.start.seconds >= 0, range.end.seconds.isFinite else { return nil }
        let start = FrameRenderer.frameIndex(at: range.start, fps: instruction.fps)
        let end = FrameRenderer.frameIndex(at: range.end, fps: instruction.fps)
        guard start >= 0, end > start else { return nil }
        return start..<end
    }

    private static func combine(_ layer: LayerPlan, into digest: inout StableDigest) -> Bool {
        guard let clipData = encodedClip(layer.clip) else { return false }
        digest.combine(clipData)
        digest.combine(layer.natSize)
        digest.combine(layer.preferredTransform)
        digest.combine(layer.mediaTag ?? "")
        switch layer.source {
        case .track(let id):
            digest.combine("track")
            digest.combine(id)
        case .text:
            digest.combine("text")
        case .adjustment:
            digest.combine("adjustment")
        case .group(let children, let canvas):
            digest.combine("group")
            digest.combine(canvas)
            digest.combine(children.count)
            for child in children {
                guard combine(child, into: &digest) else { return false }
            }
        case .transition(let from, let to, let plan):
            digest.combine("transition")
            digest.combine(plan.style.rawValue)
            digest.combine(plan.direction?.rawValue ?? "none")
            digest.combine(plan.window.startFrame)
            digest.combine(plan.window.cutFrame)
            digest.combine(plan.window.durationFrames)
            guard combine(from, into: &digest), combine(to, into: &digest) else { return false }
        }
        return true
    }

    private static func encodedClip(_ clip: Clip) -> Data? {
        encoderLock.lock()
        defer { encoderLock.unlock() }
        return try? encoder.encode(clip)
    }
}
