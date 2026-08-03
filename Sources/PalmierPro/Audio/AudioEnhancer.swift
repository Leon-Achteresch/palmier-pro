import AVFoundation
import Accelerate
import SpeechRestoration
#if BUNDLED_SPEECH
import SpeechEnhancement
#endif

enum AudioEnhancer {
    static let cache = DiskCache(named: "EnhancedAudio")
    private static let denoiseGate = AsyncSemaphore(value: 2)
    private static let processingSampleRate = 48_000

    enum EnhanceError: LocalizedError {
        case noAudioTrack
        case writeFailed
        case noEnhancerAvailable

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "Source has no audio track"
            case .writeFailed: "Could not write enhanced audio"
            case .noEnhancerAvailable: "Add your ElevenLabs API key in Settings › Models to denoise audio."
            }
        }
    }

    static func denoisedAudio(for sourceURL: URL, mediaRef: String) async throws -> URL {
        if let cached = cachedDenoisedURL(for: sourceURL, mediaRef: mediaRef) { return cached }
        try await denoiseGate.wait()
        defer { Task { await denoiseGate.signal() } }
        #if BUNDLED_SPEECH
        let outputURL = denoisedURL(for: sourceURL, mediaRef: mediaRef)
        let start = ContinuousClock.now
        var dry = try await readChannels(from: sourceURL)
        guard dry.contains(where: { !$0.isEmpty }) else { throw EnhanceError.noAudioTrack }
        var wet: [[Float]] = []
        for ch in dry.indices {
            wet.append(try await modelBox.enhance(audio: dry[ch], sampleRate: SpeechEnhancer.sampleRate))
            dry[ch] = []
        }
        removeStaleCaches(for: mediaRef, tag: DiskCache.sizeMtimeTag(for: sourceURL))
        try write(channels: wet, to: outputURL)
        let elapsed = Double(start.duration(to: .now).components.seconds)
        Log.preview.notice("denoise ok mediaRef=\(mediaRef) seconds=\(String(format: "%.0f", elapsed))")
        return outputURL
        #else
        return try await remoteDenoisedAudio(for: sourceURL, mediaRef: mediaRef)
        #endif
    }

    private static func remoteDenoisedAudio(for sourceURL: URL, mediaRef: String) async throws -> URL {
        guard let apiKey = ElevenLabsKeychain.load() else { throw EnhanceError.noEnhancerAvailable }
        let outputURL = remoteDenoisedURL(for: sourceURL, mediaRef: mediaRef)
        let start = ContinuousClock.now
        var prepared = sourceURL
        var extracted: URL?
        defer {
            if let extracted { try? FileManager.default.removeItem(at: extracted) }
        }
        if ClipType(fileExtension: sourceURL.pathExtension.lowercased()) == .video {
            let audioOnly = try await AudioTrackExtractor.extract(sourceURL: sourceURL)
            extracted = audioOnly
            prepared = audioOnly
        }
        let isolated = try await ElevenLabsAPI.run(.isolateVoice(source: prepared), apiKey: apiKey)
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        removeStaleCaches(for: mediaRef, tag: DiskCache.sizeMtimeTag(for: sourceURL))
        try FileIO.moveReplacingDestination(from: isolated, to: outputURL)
        let elapsed = Double(start.duration(to: .now).components.seconds)
        Log.preview.notice("denoise ok via elevenlabs mediaRef=\(mediaRef) seconds=\(String(format: "%.0f", elapsed))")
        return outputURL
    }

    static func studioAudio(for sourceURL: URL, mediaRef: String) async throws -> URL {
        if let cached = cachedStudioURL(for: sourceURL, mediaRef: mediaRef) { return cached }
        try await denoiseGate.wait()
        defer { Task { await denoiseGate.signal() } }
        let outputURL = studioURL(for: sourceURL, mediaRef: mediaRef)
        let start = ContinuousClock.now
        let dry = try await readChannels(from: sourceURL, sampleRate: SpeechRestorer.inputSampleRate)
        guard dry.contains(where: { !$0.isEmpty }) else { throw EnhanceError.noAudioTrack }
        let mono = mixdown(dry)
        var wet = try await restorerBox.restore(audio: mono)
        VoiceMastering.normalize(&wet, sampleRate: SpeechRestorer.outputSampleRate)
        removeStaleCaches(for: mediaRef, tag: DiskCache.sizeMtimeTag(for: sourceURL))
        try write(channels: [wet], to: outputURL)
        let elapsed = Double(start.duration(to: .now).components.seconds)
        Log.preview.notice("studio voice ok mediaRef=\(mediaRef) seconds=\(String(format: "%.0f", elapsed))")
        return outputURL
    }

    static func cachedStudioURL(for sourceURL: URL, mediaRef: String) -> URL? {
        let url = studioURL(for: sourceURL, mediaRef: mediaRef)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func studioURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_studio2.caf")
    }

    static func cachedDenoisedURL(for sourceURL: URL, mediaRef: String) -> URL? {
        let candidates = [
            denoisedURL(for: sourceURL, mediaRef: mediaRef),
            remoteDenoisedURL(for: sourceURL, mediaRef: mediaRef),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func denoisedURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_wet.caf")
    }

    private static func remoteDenoisedURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_wet.mp3")
    }

    private static func removeStaleCaches(for mediaRef: String, tag: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && !entry.lastPathComponent.contains(tag) {
            try? fm.removeItem(at: entry)
        }
    }

    private static let restorerBox = RestorerBox()

    private actor RestorerBox {
        private var restorer: SpeechRestorer?

        func restore(audio: [Float]) async throws -> [Float] {
            if restorer == nil { restorer = try await SpeechRestorer.fromPretrained() }
            let restorer = restorer!
            return try AudioEnhancer.overlapAddRestore(audio) { try restorer.restoreWindow(samples: $0) }
        }
    }

    // SpeechRestorer.restore concatenates fixed windows without overlap and each
    // window emits ~21 ms less than its input span, causing clicks and drift.
    static func overlapAddRestore(
        _ samples: [Float],
        config: SidonConfig = .default,
        restoreWindow: ([Float]) throws -> [Float]
    ) throws -> [Float] {
        let win = config.windowSamples
        let ratio = config.outputSampleRate / config.inputSampleRate
        let overlap = config.inputSampleRate
        let hop = win - overlap
        let totalOut = samples.count * ratio
        var acc = [Float](repeating: 0, count: totalOut)
        var weight = [Float](repeating: 0, count: totalOut)
        var start = 0
        while start < samples.count {
            try Task.checkCancellation()
            let end = Swift.min(start + win, samples.count)
            let restored = try restoreWindow(Array(samples[start..<end]))
            let outStart = start * ratio
            let valid = Swift.min(restored.count, (end - start) * ratio, totalOut - outStart)
            guard valid > 0 else { break }
            let fade = Swift.min(overlap * ratio, valid / 2)
            for i in 0..<valid {
                var w: Float = 1
                if start > 0, i < fade { w = Float(i + 1) / Float(fade + 1) }
                if end < samples.count, i >= valid - fade {
                    w = Swift.min(w, Float(valid - i) / Float(fade + 1))
                }
                acc[outStart + i] += restored[i] * w
                weight[outStart + i] += w
            }
            if end == samples.count { break }
            start += hop
        }
        for i in acc.indices where weight[i] > 0 { acc[i] /= weight[i] }
        return acc
    }

    private static func mixdown(_ channels: [[Float]]) -> [Float] {
        let filled = channels.filter { !$0.isEmpty }
        guard filled.count > 1, let first = filled.first else { return filled.first ?? [] }
        var mono = first
        for ch in filled.dropFirst() {
            vDSP_vadd(mono, 1, ch, 1, &mono, 1, vDSP_Length(min(mono.count, ch.count)))
        }
        var scale = 1 / Float(filled.count)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(mono.count))
        return mono
    }

    #if BUNDLED_SPEECH
    private static let modelBox = ModelBox()

    private actor ModelBox {
        private var enhancer: SpeechEnhancer?

        func enhance(audio: [Float], sampleRate: Int) async throws -> [Float] {
            try await MLXRuntime.beginInference()
            defer { MLXRuntime.endInference() }
            if enhancer == nil { enhancer = try await SpeechEnhancer.fromPretrained() }
            return try enhancer!.enhanceChunked(audio: audio, sampleRate: sampleRate)
        }
    }
    #endif

    // MARK: - Reading

    private static func readChannels(from url: URL, sampleRate: Int = processingSampleRate) async throws -> [[Float]] {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
        let desc = try await track?.load(.formatDescriptions).first
        let sourceChannels = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let count = min(2, max(1, Int(sourceChannels)))
        var channels = [[Float]](repeating: [], count: count)
        try await AudioTrackReader.read(
            from: url,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: count,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ]
        ) { buffer in
            guard let data = buffer.floatChannelData else { return }
            for ch in 0..<count {
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: Int(buffer.frameLength)))
            }
        }
        return channels
    }

    // MARK: - Writing

    private static func write(channels: [[Float]], to outputURL: URL) throws {
        guard let frameCount = channels.first?.count, frameCount > 0,
              channels.allSatisfy({ $0.count == frameCount }),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(processingSampleRate), channels: AVAudioChannelCount(channels.count)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw EnhanceError.writeFailed }
        outBuffer.frameLength = AVAudioFrameCount(frameCount)
        for ch in channels.indices {
            channels[ch].withUnsafeBufferPointer { src in
                outBuffer.floatChannelData?[ch].update(from: src.baseAddress!, count: frameCount)
            }
        }

        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(".writing-\(UUID().uuidString).caf")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        try file.write(from: outBuffer)
        try FileIO.moveReplacingDestination(from: tempURL, to: outputURL)
    }
}
