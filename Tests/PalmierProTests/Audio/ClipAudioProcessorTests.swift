import Foundation
import Testing

@testable import PalmierPro

@Suite("Clip audio processing")
struct ClipAudioProcessorTests {
    private static let sampleRate: Double = 48_000

    private func sine(frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / Self.sampleRate)) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    private func process(_ planes: [[Float]], mix: ClipAudioMix) -> [[Float]] {
        var buffers = planes
        var state = ClipAudioProcessorState()
        state.process(&buffers, configuration: ClipAudioProcessorConfiguration(mix: mix, sampleRate: Self.sampleRate))
        return buffers
    }

    @Test(arguments: [-1.0, -0.5, 0.0, 0.5, 1.0])
    func panLawKeepsConstantPower(pan: Double) {
        let gains = ClipAudioProcessorConfiguration.panGains(pan)
        #expect(abs(gains.left * gains.left + gains.right * gains.right - 2) < 1e-9)
    }

    @Test func panCentersAtUnityAndHardPansToSilence() {
        let center = ClipAudioProcessorConfiguration.panGains(0)
        #expect(abs(center.left - 1) < 1e-9)
        #expect(abs(center.right - 1) < 1e-9)

        let hardLeft = ClipAudioProcessorConfiguration.panGains(-1)
        #expect(abs(hardLeft.left - 2.0.squareRoot()) < 1e-9)
        #expect(abs(hardLeft.right) < 1e-9)
    }

    @Test func panAppliesToStereoAndLeavesMonoUntouched() {
        let stereo = process([[0.5, 0.5], [0.5, 0.5]], mix: ClipAudioMix(pan: 1))
        #expect(abs(stereo[0][0]) < 1e-6)
        #expect(abs(Double(stereo[1][0]) - 0.5 * 2.0.squareRoot()) < 1e-6)

        let mono = process([[0.5, 0.5]], mix: ClipAudioMix(pan: 1))
        #expect(mono[0] == [0.5, 0.5])
    }

    @Test func bypassMixLeavesSamplesUntouched() {
        let input = sine(frequency: 1_000, amplitude: 0.4, frames: 2_048)
        let output = process([input, input], mix: ClipAudioMix())
        #expect(output[0] == input)
        #expect(output[1] == input)
    }

    @Test func eqBandsReachTheirGainAtBandCenters() {
        let lowShelf = Biquad.lowShelf(
            frequency: AudioEQSettings.lowShelfFrequency, slope: AudioEQSettings.shelfSlope,
            gainDb: 6, sampleRate: Self.sampleRate
        )
        let mid = Biquad.peaking(frequency: 1_000, q: AudioEQSettings.midQ, gainDb: 6, sampleRate: Self.sampleRate)
        let highShelf = Biquad.highShelf(
            frequency: AudioEQSettings.highShelfFrequency, slope: AudioEQSettings.shelfSlope,
            gainDb: -6, sampleRate: Self.sampleRate
        )

        let lowDb = 20 * log10(lowShelf.magnitude(at: 20, sampleRate: Self.sampleRate))
        let midDb = 20 * log10(mid.magnitude(at: 1_000, sampleRate: Self.sampleRate))
        let highDb = 20 * log10(highShelf.magnitude(at: 20_000, sampleRate: Self.sampleRate))

        #expect(abs(lowDb - 6) < 0.5)
        #expect(abs(midDb - 6) < 0.01)
        #expect(abs(highDb + 6) < 0.5)
    }

    @Test func midBandBoostRaisesASineAtItsCenterFrequency() {
        let input = sine(frequency: 1_000, amplitude: 0.2, frames: 24_000)
        let mix = ClipAudioMix(eq: AudioEQSettings(midGainDb: 6, midFrequency: 1_000))
        let output = process([input, input], mix: mix)
        let settled = 4_800...
        let gainDb = 20 * log10(rms(output[0][settled]) / rms(input[settled]))
        #expect(abs(gainDb - 6) < 0.5)
    }

    @Test func compressorPullsLoudMaterialTowardTheStaticCurve() {
        let input = sine(frequency: 1_000, amplitude: 0.8, frames: 48_000)
        let mix = ClipAudioMix(compressor: AudioCompressorSettings(
            thresholdDb: -18, ratio: 8, attackMs: 1, releaseMs: 50, makeupGainDb: 0
        ))
        let output = process([input, input], mix: mix)
        let settled = 24_000...
        let inputPeak = input[settled].map { abs($0) }.max() ?? 0
        let outputPeak = output[0][settled].map { abs($0) }.max() ?? 0
        #expect(outputPeak < inputPeak)

        let inputDb = 20 * log10(Double(inputPeak))
        let outputDb = 20 * log10(Double(outputPeak))
        let expectedDb = -18 + (inputDb + 18) / 8
        #expect(abs(outputDb - expectedDb) < 1.5)
    }

    @Test func compressorLeavesMaterialBelowThresholdAlone() {
        let input = sine(frequency: 1_000, amplitude: 0.05, frames: 24_000)
        let mix = ClipAudioMix(compressor: AudioCompressorSettings(thresholdDb: -18, ratio: 8))
        let output = process([input, input], mix: mix)
        let maxDelta = zip(input, output[0]).map { abs($0 - $1) }.max() ?? 1
        #expect(maxDelta < 1e-6)
    }

    @Test func makeupGainAppliesWithoutCompression() {
        let input = sine(frequency: 1_000, amplitude: 0.05, frames: 24_000)
        let mix = ClipAudioMix(compressor: AudioCompressorSettings(
            thresholdDb: 0, ratio: 1, makeupGainDb: 6
        ))
        let output = process([input, input], mix: mix)
        let gainDb = 20 * log10(rms(output[0][4_800...]) / rms(input[4_800...]))
        #expect(abs(gainDb - 6) < 0.1)
    }

    @Test func normalizationDropsNeutralMixes() {
        #expect(ClipAudioMix().normalized == nil)
        #expect(ClipAudioMix(eq: AudioEQSettings(midFrequency: 3_000)).normalized == nil)
        #expect(ClipAudioMix(pan: 0.25).normalized != nil)
        #expect(ClipAudioMix(compressor: AudioCompressorSettings()).normalized != nil)
    }

    @Test func decodingClampsOutOfRangeAndNonFiniteValues() throws {
        let json = """
        {"pan": 4.5, "eq": {"lowGainDb": -99, "midFrequency": 1}, \
        "compressor": {"thresholdDb": 20, "ratio": -3, "attackMs": 9999, "releaseMs": 1, "makeupGainDb": 99}}
        """
        let mix = try JSONDecoder().decode(ClipAudioMix.self, from: Data(json.utf8))
        #expect(mix.pan == 1)
        #expect(mix.eq?.lowGainDb == ClipAudioMixLimits.eqGainDb.lowerBound)
        #expect(mix.eq?.midFrequency == ClipAudioMixLimits.midFrequency.lowerBound)
        #expect(mix.compressor?.thresholdDb == ClipAudioMixLimits.thresholdDb.upperBound)
        #expect(mix.compressor?.ratio == ClipAudioMixLimits.ratio.lowerBound)
        #expect(mix.compressor?.attackMs == ClipAudioMixLimits.attackMs.upperBound)
        #expect(mix.compressor?.releaseMs == ClipAudioMixLimits.releaseMs.lowerBound)
        #expect(mix.compressor?.makeupGainDb == ClipAudioMixLimits.makeupGainDb.upperBound)
    }

    @Test func clipRoundTripsItsMixThroughCoding() throws {
        var clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 30)
        clip.audioMix = ClipAudioMix(
            pan: -0.5,
            eq: AudioEQSettings(lowGainDb: -3, midGainDb: 4, midFrequency: 2_500),
            compressor: AudioCompressorSettings(thresholdDb: -20, ratio: 6)
        )
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.audioMix == clip.audioMix)
    }

    @Test func segmentsCoverOnlyClipsCarryingAMix() {
        var plain = Fixtures.clip(id: "plain", mediaType: .audio, start: 0, duration: 30)
        plain.audioMix = nil
        var mixed = Fixtures.clip(id: "mixed", mediaType: .audio, start: 30, duration: 60)
        mixed.audioMix = ClipAudioMix(pan: 0.5)
        var neutral = Fixtures.clip(id: "neutral", mediaType: .audio, start: 90, duration: 30)
        neutral.audioMix = ClipAudioMix()

        let segments = ClipAudioMixTap.segments(for: [plain, mixed, neutral], fps: 30)
        #expect(segments.count == 1)
        #expect(segments.first?.startSeconds == 1)
        #expect(segments.first?.endSeconds == 3)
    }
}
