import AVFoundation

struct RenderPrefetchRequest: @unchecked Sendable {
    let asset: AVAsset
    let videoComposition: AVVideoComposition
    let fps: Int
    let priorityFrame: Int
    let report: @Sendable (RenderCacheStatus) -> Void
}

final class RenderPrefetchSequence: @unchecked Sendable {
    static let shared = RenderPrefetchSequence()

    private let lock = NSLock()
    private var value = 0

    static func next() -> Int { shared.next() }

    private func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

actor RenderPrefetcher {

    static let shared = RenderPrefetcher()

    private var job: Task<Void, Never>?
    private var token: RenderPrefetchToken?
    private var generation = 0

    var isWarmPassActive: Bool { job != nil }

    func start(_ request: RenderPrefetchRequest, generation: Int) {
        guard generation >= self.generation else { return }
        self.generation = generation
        stop()
        let token = RenderPrefetchToken()
        self.token = token
        job = Task { [weak self] in
            await withTaskCancellationHandler {
                await Self.run(request, token: token)
            } onCancel: {
                token.cancel()
            }
            await self?.completed(token)
        }
    }

    func cancel(generation: Int) {
        guard generation >= self.generation else { return }
        self.generation = generation
        stop()
    }

    private func stop() {
        token?.cancel()
        token = nil
        job?.cancel()
        job = nil
    }

    private func completed(_ finished: RenderPrefetchToken) {
        guard token === finished else { return }
        token = nil
        job = nil
    }

    private static func run(_ request: RenderPrefetchRequest, token: RenderPrefetchToken) async {
        try? await Task.sleep(for: RenderCachePolicy.settleDelay)
        guard !Task.isCancelled, !token.isCancelled else { return }
        guard let tracks = try? await request.asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            return
        }
        guard !Task.isCancelled, !token.isCancelled else { return }

        request.report(status(isWarming: true))
        let plan = RenderWarmPlan(
            asset: request.asset,
            videoTracks: tracks,
            videoComposition: request.videoComposition,
            fps: request.fps,
            priorityFrame: request.priorityFrame
        )
        let outcome = await RenderSpanWarmer.warm(plan, token: token)
        let final = status(isWarming: false)
        request.report(final)
        guard outcome.warmedFrames > 0 || outcome.spans > 0 else { return }
        Log.preview.info(
            """
            render cache warmed spans=\(outcome.spans) rendered=\(outcome.renderedFrames) \
            promoted=\(outcome.promotedFrames) cancelled=\(outcome.cancelled) \
            memory=\(final.memoryBytes / (1024 * 1024))MB
            """
        )
    }

    static func status(isWarming: Bool) -> RenderCacheStatus {
        let memory = RenderFrameCache.shared.statistics
        return RenderCacheStatus(
            cachedSpans: memory.spans,
            cachedFrames: memory.frames,
            memoryBytes: memory.bytes,
            diskBytes: RenderFrameStore.shared.byteCount(),
            isWarming: isWarming
        )
    }
}
