import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Audio mix — pan on mono sources")
@MainActor
struct MonoPanTests {

    private func monoURL(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("mono.caf")
        try AudioFixtures.writeTone(dbfs: -12, seconds: 3, channels: 1, to: url)
        return url
    }

    private func timeline(pan: Double) -> Timeline {
        var clip = Fixtures.clip(id: "a", mediaRef: "mono", mediaType: .audio, start: 0, duration: 60)
        clip.audioMix = ClipAudioMix(pan: pan)
        return Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
    }

    private struct MixInput: @unchecked Sendable {
        let asset: AVComposition
        let audioMix: AVAudioMix
    }

    private func channelPeaks(pan: Double, url: URL) async throws -> (left: Double, right: Double) {
        let result = try await CompositionBuilder.build(
            timeline: timeline(pan: pan), resolveURL: { _ in url },
            renderSize: CGSize(width: 320, height: 180)
        )
        let asset = try #require(result.composition.copy() as? AVComposition)
        let mix = try #require(result.audioMix.copy() as? AVAudioMix)
        return try await Self.peaks(MixInput(asset: asset, audioMix: mix))
    }

    @concurrent
    private static func peaks(_ input: MixInput) async throws -> (left: Double, right: Double) {
        let asset = input.asset
        let audioMix = input.audioMix
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = audioMix
        reader.add(output)
        #expect(reader.startReading())

        var left = 0.0
        var right = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }
            let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for index in stride(from: 0, to: length / MemoryLayout<Float>.size, by: 2) {
                left = max(left, abs(Double(floats[index])))
                right = max(right, abs(Double(floats[index + 1])))
            }
        }
        return (left, right)
    }

    @Test func hardLeftPanSilencesTheRightChannelOfAMonoSource() async throws {
        let directory = try AudioFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try monoURL(in: directory)

        let panned = try await channelPeaks(pan: -1, url: url)
        #expect(panned.left > 0.2, "left keeps the signal: \(panned.left)")
        #expect(panned.right < 0.01, "right is emptied: \(panned.right)")
    }

    @Test func aCentredMonoSourceKeepsBothChannelsEqual() async throws {
        let directory = try AudioFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try monoURL(in: directory)

        let centred = try await channelPeaks(pan: 0, url: url)
        #expect(abs(centred.left - centred.right) < 0.01, "centred stays symmetric: \(centred)")
        #expect(centred.left > 0.2)
    }

    @Test func theUpmixKeepsBothChannelsAtTheSourceLevel() async throws {
        let directory = try AudioFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try monoURL(in: directory)

        let upmixed = try await MonoStereoUpmixer.stereoAudio(for: url, mediaRef: "mono-\(UUID().uuidString)")
        #expect(upmixed != url)
        let asset = AVURLAsset(url: upmixed)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mChannelsPerFrame == 2)

        let file = try AVAudioFile(forReading: upmixed)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        var peaks = [0.0, 0.0]
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                peaks[channel] = max(peaks[channel], abs(Double(data[channel][frame])))
            }
        }
        let expected = pow(10, -12.0 / 20)
        #expect(abs(peaks[0] - expected) < 0.01, "left at unity: \(peaks[0])")
        #expect(abs(peaks[1] - expected) < 0.01, "right at unity: \(peaks[1])")
    }

    @Test func anAlreadyStereoSourceIsNotRewritten() async throws {
        let directory = try AudioFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stereo.caf")
        try AudioFixtures.writeTone(dbfs: -12, seconds: 1, to: url)

        #expect(try await MonoStereoUpmixer.stereoAudio(for: url, mediaRef: "stereo") == url)
    }

    @Test func aCentredMixNeedsNoUpmix() {
        #expect(!MonoStereoUpmixer.isNeeded(for: nil))
        #expect(!MonoStereoUpmixer.isNeeded(for: ClipAudioMix(pan: 0)))
        #expect(MonoStereoUpmixer.isNeeded(for: ClipAudioMix(pan: 0.5)))
    }
}
