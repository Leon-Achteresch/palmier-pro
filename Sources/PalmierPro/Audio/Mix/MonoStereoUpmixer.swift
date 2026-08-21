import AVFoundation
import os

/// Pan needs two channels to place a signal. `MTAudioProcessingTap` cannot widen its
/// processing format, so a panned mono source is materialised as a dual-mono twin first.
enum MonoStereoUpmixer {

    static let cache = DiskCache(named: "StereoAudio")

    enum UpmixError: LocalizedError {
        case noAudioTrack
        case readerSetupFailed
        case writerSetupFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "The source has no audio track."
            case .readerSetupFailed: "Could not read the source audio."
            case .writerSetupFailed: "Could not stage the stereo audio."
            case .writeFailed: "Writing the stereo audio failed."
            }
        }
    }

    /// True when `mix` places the signal off centre and therefore needs two channels.
    static func isNeeded(for mix: ClipAudioMix?) -> Bool {
        guard let mix = mix?.normalized else { return false }
        return mix.pan != 0
    }

    /// Dual-mono twin of `sourceURL`, or `sourceURL` itself when the source already
    /// carries two or more channels. Each output channel receives the source at unity
    /// gain, so a centred pan reproduces the level AVFoundation gives an unpanned mono track.
    static func stereoAudio(for sourceURL: URL, mediaRef: String) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw UpmixError.noAudioTrack
        }
        guard try await channelCount(of: track) == 1 else { return sourceURL }

        let outputURL = cache.directory
            .appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_stereo.caf")
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }
        return try await transcode(asset: asset, track: track, to: outputURL)
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        guard let format = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return 0 }
        return Int(asbd.mChannelsPerFrame)
    }

    private static func transcode(asset: AVURLAsset, track: AVAssetTrack, to outputURL: URL) async throws -> URL {
        let sampleRate = try await sourceSampleRate(of: track)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = withUnsafeBytes(of: &layout) { Data($0) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layoutData,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw UpmixError.readerSetupFailed }
        reader.add(readerOutput)

        let fm = FileManager.default
        let parent = outputURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stagingURL = parent.appendingPathComponent(".writing-\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: stagingURL) }

        let writer = try AVAssetWriter(outputURL: stagingURL, fileType: .caf)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw UpmixError.writerSetupFailed }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? UpmixError.readerSetupFailed }
        guard writer.startWriting() else { throw writer.error ?? UpmixError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "io.palmier.mono-stereo-upmix")
        nonisolated(unsafe) let unsafeReader = reader
        nonisolated(unsafe) let unsafeOutput = readerOutput
        nonisolated(unsafe) let unsafeInput = input
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    @Sendable func finish(_ result: Result<Void, Error>) {
                        let already = resumed.withLock { done -> Bool in
                            defer { done = true }
                            return done
                        }
                        guard !already else { return }
                        cont.resume(with: result)
                    }
                    unsafeInput.requestMediaDataWhenReady(on: queue) {
                        while unsafeInput.isReadyForMoreMediaData {
                            if Task.isCancelled {
                                unsafeReader.cancelReading()
                                unsafeInput.markAsFinished()
                                finish(.failure(CancellationError()))
                                return
                            }
                            guard let sample = unsafeOutput.copyNextSampleBuffer() else {
                                unsafeInput.markAsFinished()
                                if unsafeReader.status == .failed {
                                    finish(.failure(unsafeReader.error ?? UpmixError.writeFailed))
                                } else {
                                    finish(.success(()))
                                }
                                return
                            }
                            guard unsafeInput.append(sample) else {
                                unsafeInput.markAsFinished()
                                finish(.failure(UpmixError.writeFailed))
                                return
                            }
                        }
                    }
                }
            } onCancel: {
                unsafeReader.cancelReading()
            }
        } catch {
            await writer.finishWriting()
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? UpmixError.writeFailed }
        guard !fm.fileExists(atPath: outputURL.path) else { return outputURL }
        do {
            try fm.moveItem(at: stagingURL, to: outputURL)
        } catch {
            guard fm.fileExists(atPath: outputURL.path) else { throw error }
        }
        return outputURL
    }

    private static func sourceSampleRate(of track: AVAssetTrack) async throws -> Double {
        guard let format = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate > 0
        else { return 48_000 }
        return asbd.mSampleRate
    }
}
