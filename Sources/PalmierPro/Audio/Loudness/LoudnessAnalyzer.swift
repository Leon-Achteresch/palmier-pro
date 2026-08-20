import AVFoundation

enum LoudnessTarget: String, CaseIterable, Sendable {
    case youtube
    case podcast
    case broadcast

    var integratedLufs: Double {
        switch self {
        case .youtube: -14
        case .podcast: -16
        case .broadcast: -23
        }
    }

    var truePeakCeilingDbtp: Double {
        switch self {
        case .youtube, .podcast: -1
        case .broadcast: -2
        }
    }
}

enum LoudnessAnalyzer {
    struct NoAudioError: LocalizedError {
        var errorDescription: String? { "No audio tracks to measure."}
    }

    static let analysisChannelCount = 2

    struct Input: @unchecked Sendable {
        let asset: AVAsset
        let audioMix: AVAudioMix?
        let timeRange: CMTimeRange?

        init(asset: AVAsset, audioMix: AVAudioMix?, timeRange: CMTimeRange? = nil) {
            self.asset = asset
            self.audioMix = audioMix
            self.timeRange = timeRange
        }
    }

    @concurrent
    static func measure(_ input: Input) async throws -> LoudnessMeasurement {
        let asset = input.asset
        let timeRange = input.timeRange
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw NoAudioError() }
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        if let timeRange, timeRange.isValid, timeRange.duration > .zero {
            reader.timeRange = timeRange
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: LoudnessMeter.sampleRate,
            AVNumberOfChannelsKey: analysisChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ])
        output.audioMix = input.audioMix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NoAudioError() }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NoAudioError()
        }

        var meter = LoudnessMeter(channelCount: analysisChannelCount)
        while true {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let planes = planarSamples(from: sampleBuffer) {
                meter.ingest(planes)
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NoAudioError()
        }
        return meter.measurement()
    }

    private static func planarSamples(from sampleBuffer: CMSampleBuffer) -> [[Float]]? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        let buffers = AudioBufferList.allocate(maximumBuffers: analysisChannelCount)
        defer { free(buffers.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: buffers.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: analysisChannelCount),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }
        var planes: [[Float]] = []
        planes.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(frameCount, available)
            let pointer = data.assumingMemoryBound(to: Float.self)
            planes.append(Array(UnsafeBufferPointer(start: pointer, count: count)))
        }
        return planes.isEmpty ? nil : planes
    }
}
