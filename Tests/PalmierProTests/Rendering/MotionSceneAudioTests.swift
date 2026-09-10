import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Motion scene sound cues")
struct MotionSceneAudioTests {
    @Test func pinnedSoundRendersAtItsCueFrameAndVolume() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let source = try await Self.tone(in: package.url)
            var scene = MotionScene(width: 160, height: 120, fps: 60, durationInFrames: 60)
            scene = try await MotionSceneAudio.pin(scene: scene, urls: ["tone": source])
            scene.audioCues = [MotionAudioCue(mediaRef: "tone", frame: 15, durationFrames: 30, volumeDB: -6)]
            _ = try scene.validated()
            try await Self.remove(source)
            let url = try await MotionSceneAudio.render(scene, directory: package.url.appendingPathComponent("render"))
            let samples = try await Self.samples(url)
            #expect(Self.rms(samples, from: 0.05, to: 0.15) < 0.002)
            #expect((0.025...0.05).contains(Self.rms(samples, from: 0.3, to: 0.6)))
            #expect(Self.rms(samples, from: 0.85, to: 0.95) < 0.002)
            try await package.remove()
        } catch { try await package.remove(); throw error }
    }

    @Test @MainActor func soundImportAndCueAreOnePersistentUndoAction() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let source = try await Self.tone(in: package.url)
            let editor = EditorViewModel()
            editor.projectURL = package.url
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let audio = MediaAsset(id: "tone", url: source, type: .audio, name: "Tone", duration: 1)
            editor.importMediaAsset(audio)
            let created = try await editor.motionScenes.create(MotionScene(width: 160, height: 120, fps: 30, durationInFrames: 30), name: "Scene", editor: editor)
            undo.removeAllActions()
            _ = try await editor.motionScenes.apply([.audioCue(MotionAudioCue(mediaRef: audio.id, frame: 0, durationFrames: 15))],
                mediaRef: created.mediaRef, expectedRevision: created.revision, actionName: "Add Sound", editor: editor)
            let asset = try #require(editor.mediaAssetsById[created.mediaRef])
            #expect(try await MotionVideoGenerator.loadScene(at: asset.url).sounds["tone"] != nil)
            undo.undo()
            #expect(try await MotionVideoGenerator.loadScene(at: asset.url).audioCues.isEmpty)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(try await MotionVideoGenerator.loadScene(at: asset.url).audioCues.count == 1)
            #expect(asset.hasAudio)
            undo.removeAllActions()
            try await package.remove()
        } catch { try await package.remove(); throw error }
    }

    @Test func refusesMissingAndOutOfRangeSoundSources() {
        var scene = MotionScene(width: 160, height: 120, fps: 30, durationInFrames: 60)
        scene.audioCues = [MotionAudioCue(mediaRef: "tone", frame: 0, durationFrames: 30)]
        #expect(throws: MotionSceneError.self) { try scene.validated() }
        scene.sounds["tone"] = MotionAudioSource(name: "Tone", fileExtension: "m4a", data: Data([1]), duration: 0.5)
        #expect(throws: MotionSceneError.self) { try scene.validated() }
    }

    @concurrent private static func tone(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("tone.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<48000 { samples[frame] = Float(0.1 * sin(Double(frame) * 2 * .pi * 440 / 48000)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @concurrent private static func remove(_ url: URL) async throws { try FileManager.default.removeItem(at: url) }

    @concurrent private static func samples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        #expect(reader.startReading())
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.stride)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            #expect(status == kCMBlockBufferNoErr)
            result.append(contentsOf: stride(from: 0, to: values.count, by: 2).map { values[$0] })
        }
        #expect(reader.status == .completed)
        return result
    }

    private static func rms(_ samples: [Float], from: Double, to: Double) -> Double {
        let lower = min(samples.count, Int(from * 48000)), upper = min(samples.count, Int(to * 48000))
        guard upper > lower else { return 0 }
        return sqrt(samples[lower..<upper].reduce(0) { $0 + Double($1 * $1) } / Double(upper - lower))
    }
}
