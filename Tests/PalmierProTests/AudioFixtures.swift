import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

enum AudioFixtures {
    /// 997 Hz sine at `dbfs` (or digital silence when nil) as a stereo CAF file.
    static func writeTone(dbfs: Double?, seconds: Double, channels: AVAudioChannelCount = 2, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let amplitude = dbfs.map { pow(10, $0 / 20) } ?? 0
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            let samples = data[channel]
            for frame in 0..<Int(frames) {
                samples[frame] = Float(amplitude * sin(2 * .pi * 997 * Double(frame) / 48_000))
            }
        }
        try file.write(from: buffer)
    }

    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palmier-audio-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
