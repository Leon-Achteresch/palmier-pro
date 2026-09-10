import AVFoundation
import Foundation

struct MotionAudioSource: Codable, Equatable, Sendable {
    var name: String
    var fileExtension: String
    var data: Data
    var duration: Double
}

enum MotionSceneAudio {
    @concurrent static func pin(scene: MotionScene, urls: [String: URL]) async throws -> MotionScene {
        var scene = scene
        for (id, url) in urls.sorted(by: { $0.key < $1.key }) where scene.sounds[id] == nil {
            try Task.checkCancellation()
            let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard metadata.isRegularFile == true, (metadata.fileSize ?? Int.max) <= 20 * 1024 * 1024 else {
                throw MotionSceneError.invalidField("sound source must be a regular file smaller than 20 MB")
            }
            let data = try Data(contentsOf: url)
            let asset = AVURLAsset(url: url)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw MotionSceneError.invalidField("sound source has no audio track") }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw MotionSceneError.invalidField("sound source has invalid duration") }
            scene.sounds[id] = MotionAudioSource(name: url.deletingPathExtension().lastPathComponent,
                fileExtension: url.pathExtension, data: data, duration: duration)
        }
        try Task.checkCancellation()
        return scene
    }

    @concurrent static func render(_ scene: MotionScene, directory: URL) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let silence = directory.appendingPathComponent("silence.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800) else { throw MotionSceneError.writeFailed }
        buffer.frameLength = 4800
        for channel in 0..<2 { buffer.floatChannelData?[channel].initialize(repeating: 0, count: 4800) }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: silence, settings: settings)
            try file.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let silenceAsset = AVURLAsset(url: silence)
        var sourceAssets: [AVURLAsset] = [silenceAsset]
        defer { withExtendedLifetime(sourceAssets) {} }
        guard let silenceTrack = try await silenceAsset.loadTracks(withMediaType: .audio).first,
              let bed = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MotionSceneError.writeFailed }
        let end = scene.time(forFrame: scene.durationInFrames)
        let quietLength = CMTimeMinimum(end, CMTime(value: 1, timescale: 10))
        try bed.insertTimeRange(CMTimeRange(start: .zero, duration: quietLength), of: silenceTrack, at: .zero)
        if end > quietLength { try bed.insertTimeRange(CMTimeRange(start: .zero, duration: quietLength), of: silenceTrack, at: end - quietLength) }
        var sources: [String: AVAssetTrack] = [:]
        for (index, item) in scene.sounds.sorted(by: { $0.key < $1.key }).enumerated() where scene.audioCues.contains(where: { $0.mediaRef == item.key }) {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("source-\(index)").appendingPathExtension(item.value.fileExtension)
            try item.value.data.write(to: url)
            let asset = AVURLAsset(url: url)
            sourceAssets.append(asset)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MotionSceneError.invalidField("pinned sound could not be decoded") }
            sources[item.key] = track
        }
        var parameters: [AVAudioMixInputParameters] = []
        for cue in scene.audioCues {
            try Task.checkCancellation()
            guard let source = sources[cue.mediaRef],
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MotionSceneError.writeFailed }
            let range = CMTimeRange(start: scene.time(forFrame: cue.trimStartFrame), duration: scene.time(forFrame: cue.durationFrames))
            do { try track.insertTimeRange(range, of: source, at: scene.time(forFrame: cue.frame)) }
            catch { throw MotionSceneError.sceneFailed("sound cue '\(cue.id)' could not be placed: \(error.localizedDescription)") }
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(Float(pow(10, cue.volumeDB / 20)), at: .zero)
            parameters.append(input)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        let output = directory.appendingPathComponent("sound.m4a")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw MotionSceneError.writeFailed }
        export.audioMix = mix
        do { try await export.export(to: output, as: .m4a) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MotionSceneError.sceneFailed("motion sound mix failed: \(error.localizedDescription)") }
        try Task.checkCancellation()
        return output
    }

    @concurrent static func installSound(in video: URL, scene: MotionScene) async throws {
        let directory = video.deletingLastPathComponent().appendingPathComponent(".sound-\(UUID().uuidString)")
        defer {
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { Log.preview.warning("motion sound temporary cleanup failed: \(Log.detail(error))") }
        }
        let audio = try await render(scene, directory: directory)
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: video)
        let soundAsset = AVURLAsset(url: audio)
        defer { withExtendedLifetime([asset, soundAsset]) {} }
        let duration = try await asset.load(.duration)
        guard let videoSource = try await asset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioSource = try await soundAsset.loadTracks(withMediaType: .audio).first,
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MotionSceneError.writeFailed }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoSource, at: .zero)
        let audioRange = try await audioSource.load(.timeRange)
        try audioTrack.insertTimeRange(audioRange, of: audioSource, at: .zero)
        if duration > audioRange.duration { audioTrack.insertEmptyTimeRange(CMTimeRange(start: audioRange.duration, duration: duration - audioRange.duration)) }
        let output = directory.appendingPathComponent("complete.mov")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw MotionSceneError.writeFailed }
        do { try await export.export(to: output, as: .mov) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MotionSceneError.sceneFailed("motion audio/video assembly failed: \(error.localizedDescription)") }
        try Task.checkCancellation()
        _ = try FileManager.default.replaceItemAt(video, withItemAt: output)
    }
}

actor MotionAudioPreview {
    private var player: AVAudioPlayer?
    private var directory: URL?
    private var revision: String?
    private var generation = 0

    func play(scene: MotionScene, revision: String, frame: Int) async throws {
        generation += 1
        let request = generation
        player?.stop()
        if self.revision != revision {
            cleanup()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("motion-preview-\(UUID().uuidString)")
            do {
                let url = try await MotionSceneAudio.render(scene, directory: directory)
                try Task.checkCancellation()
                guard request == generation else { try FileManager.default.removeItem(at: directory); return }
                player = try AVAudioPlayer(contentsOf: url)
                self.directory = directory
                self.revision = revision
            } catch {
                do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
                catch { Log.preview.warning("motion preview sound cleanup failed: \(Log.detail(error))") }
                throw error
            }
        }
        guard request == generation else { return }
        player?.currentTime = Double(frame) / scene.fps
        guard player?.play() == true else { throw MotionSceneError.sceneFailed("motion sound playback could not start") }
    }

    func stop() { generation += 1; player?.stop() }
    func close() { generation += 1; cleanup() }
    private func cleanup() {
        player?.stop(); player = nil; revision = nil
        if let directory {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Log.preview.warning("motion preview sound cleanup failed: \(Log.detail(error))") }
        }
        directory = nil
    }
}
