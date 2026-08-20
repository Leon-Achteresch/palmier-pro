import AVFoundation
import Foundation
import Testing

@testable import PalmierPro

@Suite("Loudness measurement")
struct LoudnessMeterTests {
    private func stereoSine(dbfs: Double, seconds: Double, frequency: Double = 997) -> [[Float]] {
        let amplitude = pow(10, dbfs / 20)
        let frames = Int(seconds * LoudnessMeter.sampleRate)
        let channel = (0..<frames).map {
            Float(amplitude * sin(2 * .pi * frequency * Double($0) / LoudnessMeter.sampleRate))
        }
        return [channel, channel]
    }

    @Test(arguments: [-20.0, -23.0, -31.0])
    func integratedLoudnessMatchesAStereoSine(dbfs: Double) throws {
        var meter = LoudnessMeter(channelCount: 2)
        meter.ingest(stereoSine(dbfs: dbfs, seconds: 5))
        let integrated = try #require(meter.measurement().integratedLufs)
        #expect(abs(integrated - dbfs) < 0.5)
    }

    @Test func truePeakTracksTheSineAmplitude() throws {
        var meter = LoudnessMeter(channelCount: 2)
        meter.ingest(stereoSine(dbfs: -20, seconds: 2))
        let peak = try #require(meter.measurement().truePeakDbtp)
        #expect(abs(peak + 20) < 0.3)
    }

    @Test func silenceIsGatedOut() {
        var meter = LoudnessMeter(channelCount: 2)
        meter.ingest([[Float](repeating: 0, count: 48_000), [Float](repeating: 0, count: 48_000)])
        let measurement = meter.measurement()
        #expect(measurement.integratedLufs == nil)
        #expect(measurement.truePeakDbtp == nil)
        #expect(abs(measurement.analyzedSeconds - 1) < 0.001)
    }

    @Test func quietPassagesBelowTheRelativeGateDoNotDragTheResultDown() throws {
        var meter = LoudnessMeter(channelCount: 2)
        meter.ingest(stereoSine(dbfs: -20, seconds: 4))
        meter.ingest(stereoSine(dbfs: -50, seconds: 8))
        let integrated = try #require(meter.measurement().integratedLufs)
        #expect(abs(integrated + 20) < 0.5)
    }

    @Test func blocksShorterThanTheGateWindowProduceNoMeasurement() {
        var meter = LoudnessMeter(channelCount: 2)
        meter.ingest(stereoSine(dbfs: -20, seconds: 0.2))
        #expect(meter.measurement().integratedLufs == nil)
    }
}

@Suite("Timeline loudness")
@MainActor
struct TimelineLoudnessTests {
    private func writeSine(dbfs: Double, seconds: Double, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let amplitude = pow(10, dbfs / 20)
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData)[channel]
            for frame in 0..<Int(frames) {
                samples[frame] = Float(amplitude * sin(2 * .pi * 997 * Double(frame) / 48_000))
            }
        }
        try file.write(from: buffer)
    }

    private func harness(mix: ClipAudioMix?, directory: URL) throws -> (EditorViewModel, Clip) {
        let url = directory.appendingPathComponent("tone.caf")
        try writeSine(dbfs: -20, seconds: 4, to: url)
        let editor = EditorViewModel()
        let asset = MediaAsset(id: "tone", url: url, type: .audio, name: "tone", duration: 4)
        editor.mediaAssets.append(asset)
        editor.mediaManifest.entries.append(MediaManifestEntry(
            id: asset.id, name: asset.name, type: .audio,
            source: .external(absolutePath: url.path), duration: 4
        ))
        var clip = Fixtures.clip(id: "audio", mediaRef: asset.id, mediaType: .audio, start: 0, duration: 120)
        clip.audioMix = mix
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        return (editor, clip)
    }

    private func measure(mix: ClipAudioMix?) async throws -> LoudnessMeasurement {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-loudness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (editor, _) = try harness(mix: mix, directory: directory)
        return try await TimelineLoudness.measure(
            timeline: editor.timeline,
            resolver: editor.mediaResolver,
            resolveTimeline: editor.timelineResolver(),
            missingMediaRefs: editor.missingMediaRefs
        )
    }

    @Test func measuresTheBuiltCompositionAtSourceLevel() async throws {
        let measurement = try await measure(mix: nil)
        let integrated = try #require(measurement.integratedLufs)
        #expect(abs(integrated + 20) < 0.5)
        let peak = try #require(measurement.truePeakDbtp)
        #expect(peak > -20.5 && peak < -18.5)
    }

    @Test func clipProcessingReachesTheMeasuredMix() async throws {
        let boosted = try await measure(
            mix: ClipAudioMix(eq: AudioEQSettings(midGainDb: 6, midFrequency: 997))
        )
        let integrated = try #require(boosted.integratedLufs)
        #expect(abs(integrated + 14) < 0.6)
    }

    @Test func emptyTimelineRefusesMeasurement() async throws {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
        await #expect(throws: TimelineLoudness.EmptyAudioError.self) {
            try await TimelineLoudness.measure(
                timeline: editor.timeline,
                resolver: editor.mediaResolver,
                resolveTimeline: editor.timelineResolver(),
                missingMediaRefs: editor.missingMediaRefs
            )
        }
    }
}
