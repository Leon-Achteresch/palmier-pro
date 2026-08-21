import AVFoundation

final class RenderPrefetchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct RenderWarmPlan: @unchecked Sendable {
    let asset: AVAsset
    let videoTracks: [AVAssetTrack]
    let videoComposition: AVVideoComposition
    let fps: Int
    let priorityFrame: Int
}

struct RenderWarmOutcome: Sendable, Equatable {
    var spans = 0
    var warmedFrames = 0
    var promotedFrames = 0
    var renderedFrames = 0
    var cancelled = false
}

enum RenderSpanWarmer {

    private static let queue = DispatchQueue(label: "io.palmier.render-cache.warm", qos: .utility)

    static func warm(
        _ plan: RenderWarmPlan,
        token: RenderPrefetchToken,
        memory: RenderFrameCache = .shared,
        store: RenderFrameStore = .shared
    ) async -> RenderWarmOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: perform(plan, token: token, memory: memory, store: store))
            }
        }
    }

    static func plannedSpans(in videoComposition: AVVideoComposition, priorityFrame: Int) -> [RenderCacheSpan] {
        let spans = videoComposition.instructions
            .compactMap { ($0 as? CompositorInstruction)?.renderCacheSpan }
        return spans.sorted { distance($0, from: priorityFrame) < distance($1, from: priorityFrame) }
    }

    private static func distance(_ span: RenderCacheSpan, from frame: Int) -> Int {
        if span.frames.contains(frame) { return 0 }
        return frame < span.frames.lowerBound
            ? span.frames.lowerBound - frame
            : frame - span.frames.upperBound
    }

    private static func perform(
        _ plan: RenderWarmPlan,
        token: RenderPrefetchToken,
        memory: RenderFrameCache,
        store: RenderFrameStore
    ) -> RenderWarmOutcome {
        var outcome = RenderWarmOutcome()
        let spans = plannedSpans(in: plan.videoComposition, priorityFrame: plan.priorityFrame)
        memory.retain(digests: Set(spans.map(\.digest)))
        guard !plan.videoTracks.isEmpty else { return outcome }

        var budget = RenderCachePolicy.warmBudget(renderSize: plan.videoComposition.renderSize)
        var diskBudget = RenderCachePolicy.diskWriteBudgetPerPass
        for span in spans.prefix(RenderCachePolicy.warmedSpanLimit) {
            if token.isCancelled {
                outcome.cancelled = true
                break
            }
            guard budget > 0 else { break }
            let frames = span.frames.prefix(min(budget, RenderCachePolicy.framesPerSpanLimit))
            let missing = frames.filter { !memory.contains(RenderCacheKey(spanDigest: span.digest, frame: $0)) }
            guard !missing.isEmpty else { continue }
            outcome.spans += 1

            var pending: [Int] = []
            for frame in missing {
                if token.isCancelled { break }
                let key = RenderCacheKey(spanDigest: span.digest, frame: frame)
                if let payload = store.payload(for: key), let buffer = payload.makeBuffer() {
                    memory.store(buffer, for: key)
                    outcome.promotedFrames += 1
                    budget -= 1
                } else {
                    pending.append(frame)
                }
            }
            if token.isCancelled {
                outcome.cancelled = true
                break
            }
            guard !pending.isEmpty, budget > 0 else { continue }
            let rendered = render(
                span: span, frames: pending, plan: plan, token: token,
                budget: budget, diskBudget: &diskBudget, memory: memory, store: store
            )
            outcome.renderedFrames += rendered
            budget -= rendered
            if token.isCancelled {
                outcome.cancelled = true
                break
            }
        }
        outcome.warmedFrames = outcome.promotedFrames + outcome.renderedFrames
        return outcome
    }

    private static func render(
        span: RenderCacheSpan,
        frames: [Int],
        plan: RenderWarmPlan,
        token: RenderPrefetchToken,
        budget: Int,
        diskBudget: inout Int,
        memory: RenderFrameCache,
        store: RenderFrameStore
    ) -> Int {
        guard let first = frames.first, let last = frames.last, plan.fps > 0 else { return 0 }
        let timescale = CMTimeScale(plan.fps)
        let readRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(first), timescale: timescale),
            end: CMTime(value: CMTimeValue(last + 1), timescale: timescale)
        )
        guard let reader = try? AVAssetReader(asset: plan.asset) else { return 0 }
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: plan.videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: RenderFramePayload.pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )
        output.videoComposition = plan.videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        reader.timeRange = readRange
        guard reader.startReading() else { return 0 }
        defer { reader.cancelReading() }

        let wanted = Set(frames)
        var stored = 0
        var persisted = 0
        while stored < budget, !token.isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let frame = FrameRenderer.frameIndex(
                    at: CMSampleBufferGetPresentationTimeStamp(sample), fps: plan.fps
                )
                guard wanted.contains(frame) else { return }
                let key = RenderCacheKey(spanDigest: span.digest, frame: frame)
                guard !memory.contains(key), let payload = RenderFramePayload.payload(from: buffer) else { return }
                guard let copy = payload.makeBuffer() else { return }
                memory.store(copy, for: key)
                if payload.byteCount <= diskBudget - persisted, store.store(payload, for: key) {
                    persisted += payload.byteCount
                }
                stored += 1
            }
        }
        diskBudget -= persisted
        return stored
    }
}
