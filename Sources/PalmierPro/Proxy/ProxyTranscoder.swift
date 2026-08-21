import AVFoundation

enum ProxyTranscodeError: LocalizedError {
    case noVideoTrack
    case unsupportedSize
    case presetUnavailable

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "Source has no video track"
        case .unsupportedSize: "Source has no usable frame size"
        case .presetUnavailable: "Proxy encoder unavailable for this source"
        }
    }
}

enum ProxyTranscoder {
    @concurrent
    static func transcode(source: URL, to outputURL: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProxyTranscodeError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let box = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displaySize = CGSize(width: abs(box.width), height: abs(box.height))
        guard let target = ProxyPlan.targetSize(displaySize: displaySize), displaySize.width >= 1 else {
            throw ProxyTranscodeError.unsupportedSize
        }
        try Task.checkCancellation()

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ProxyTranscodeError.presetUnavailable
        }
        let scale = target.width / displaySize.width
        let upright = preferredTransform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
        var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layerConfig.setTransform(upright.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instructionConfig = AVVideoCompositionInstruction.Configuration(
            backgroundColor: nil,
            enablePostProcessing: false,
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerConfig)],
            requiredSourceSampleDataTrackIDs: [],
            timeRange: CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        )
        let instruction = AVVideoCompositionInstruction(configuration: instructionConfig)
        var compositionConfig = try await AVVideoComposition.Configuration(
            for: asset, prototypeInstruction: instruction
        )
        compositionConfig.renderSize = target
        compositionConfig.instructions = [instruction]
        session.videoComposition = AVVideoComposition(configuration: compositionConfig)

        do {
            try Task.checkCancellation()
            try await session.export(to: outputURL, as: .mov)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw Task.isCancelled ? CancellationError() : error
        }
        return target
    }
}
