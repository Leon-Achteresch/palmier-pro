import AVFoundation
import CoreImage
import Foundation

struct ReferenceAnalysisResult: Sendable {
    let profile: ReferenceProfile
    let warnings: [String]
}

enum ReferenceAnalyzer {
    static let maxScopeSamples = 60

    @concurrent
    static func analyze(url: URL, name: String) async throws -> ReferenceAnalysisResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Reference media not on disk: \(url.lastPathComponent)")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ToolError("Reference media has no measurable duration.")
        }
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ToolError("Reference media has no video track: \(url.lastPathComponent)")
        }
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty

        var warnings: [String] = [
            "Shot boundaries are sampled on a ~2s grid; cuts faster than that merge into one shot."
        ]
        var shotStarts: [Double] = []
        var scopeSamples: [Scopes] = []
        for try await frame in FrameSampler.frames(url: url, duration: duration) {
            try Task.checkCancellation()
            if frame.isNewShot { shotStarts.append(frame.time) }
            if scopeSamples.count < Self.maxScopeSamples,
               let scopes = ColorScopes.measure(CIImage(cgImage: frame.image), gridEdge: 64) {
                scopeSamples.append(scopes)
            }
        }
        try Task.checkCancellation()

        let id = String(UUID().uuidString.prefix(8)).lowercased()

        var bpm: Double?
        var audioStats: AudioStats?
        if hasAudio {
            do {
                let analysis = try await BeatDetector.analysis(for: url, mediaRef: "reference-\(id)")
                if analysis.bpm > 0 { bpm = analysis.bpm }
            } catch {
                warnings.append("Beat analysis failed: \(error.localizedDescription)")
            }
            do {
                let envelope = try await WaveformExtractor.peakEnvelope(from: url)
                if !envelope.isEmpty {
                    let energies = envelope.map { 1 - Double($0) }
                    audioStats = AudioStats(
                        energyMean: energies.reduce(0, +) / Double(energies.count),
                        quietFraction: Double(envelope.count(where: { $0 >= 0.95 })) / Double(envelope.count)
                    )
                }
            } catch {
                warnings.append("Loudness analysis failed: \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()

        let profile = ReferenceProfile(
            id: id,
            name: name,
            sourceFileName: url.lastPathComponent,
            createdDate: Date(),
            durationSeconds: duration,
            pacing: Self.pacing(shotStarts: shotStarts, duration: duration),
            bpm: bpm,
            audio: audioStats,
            look: Self.look(from: scopeSamples)
        )
        return ReferenceAnalysisResult(profile: profile, warnings: warnings)
    }

    static func pacing(shotStarts: [Double], duration: Double) -> PacingStats? {
        var boundaries = Set(shotStarts.filter { $0 > 0 && $0 < duration }).sorted()
        boundaries = [0] + boundaries
        var shots: [(midpoint: Double, seconds: Double)] = []
        for (index, start) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            guard end > start else { continue }
            shots.append((midpoint: (start + end) / 2, seconds: end - start))
        }
        return ShotPacing.stats(shots: shots, duration: duration)
    }

    static func look(from samples: [Scopes]) -> LookStats? {
        guard !samples.isEmpty else { return nil }
        let count = Double(samples.count)
        var histogram = [Double](repeating: 0, count: samples[0].hueHistogram.count)
        for sample in samples {
            for (index, value) in sample.hueHistogram.enumerated() where index < histogram.count {
                histogram[index] += Double(value)
            }
        }
        let histogramTotal = histogram.reduce(0, +)
        if histogramTotal > 0 {
            histogram = histogram.map { $0 / histogramTotal }
        }
        return LookStats(
            lumaMean: samples.reduce(0) { $0 + Double($1.lumaMean) } / count,
            saturationMean: samples.reduce(0) { $0 + Double($1.saturationMean) } / count,
            warmCoolBias: samples.reduce(0) { $0 + Double($1.warmCoolBias) } / count,
            hueHistogram: histogram
        )
    }
}
