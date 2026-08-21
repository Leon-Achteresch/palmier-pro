import AVFoundation

struct TransitionPlan: Sendable {
    let style: TransitionStyle
    let direction: TransitionDirection?
    let window: TransitionWindow
}

/// Immutable per-clip snapshot read on the render queue — never the live timeline.
struct LayerPlan: Sendable {
    indirect enum Source: Sendable {
        case track(CMPersistentTrackID)
        case text
        case adjustment
        /// Nested timeline: children composite into a `canvas`-sized unit, then the nest clip's pipeline applies.
        case group(children: [LayerPlan], canvas: CGSize)
        case transition(from: LayerPlan, to: LayerPlan, plan: TransitionPlan)
    }
    let source: Source
    let clip: Clip
    let natSize: CGSize
    let preferredTransform: CGAffineTransform
    var mediaTag: String?

    var trackID: CMPersistentTrackID? {
        if case .track(let id) = source { return id }
        return nil
    }

    func collectTrackIDs(into ids: inout [CMPersistentTrackID]) {
        switch source {
        case .track(let id): ids.append(id)
        case .text, .adjustment: break
        case .group(let children, _):
            for child in children { child.collectTrackIDs(into: &ids) }
        case .transition(let from, let to, _):
            from.collectTrackIDs(into: &ids)
            to.collectTrackIDs(into: &ids)
        }
    }
}

/// One timeline segment between clip boundaries. Layers are ordered bottom → top.
final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    // Values are sampled per frame; never let AVFoundation cache one frame per instruction.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [LayerPlan]
    let renderSize: CGSize
    let fps: Int

    private let spanLock = NSLock()
    private var resolvedSpan: RenderCacheSpan??

    var renderCacheSpan: RenderCacheSpan? {
        spanLock.lock()
        defer { spanLock.unlock() }
        if let resolvedSpan { return resolvedSpan }
        let span = RenderCacheDigest.span(for: self)
        resolvedSpan = .some(span)
        return span
    }

    init(timeRange: CMTimeRange, layers: [LayerPlan], renderSize: CGSize, fps: Int) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderSize = renderSize
        self.fps = fps
        var all: [CMPersistentTrackID] = []
        for layer in layers { layer.collectTrackIDs(into: &all) }
        var seen = Set<CMPersistentTrackID>()
        self.requiredSourceTrackIDs = all.compactMap {
            seen.insert($0).inserted ? NSNumber(value: $0) : nil
        }
        super.init()
    }
}
