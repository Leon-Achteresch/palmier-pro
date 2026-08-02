import Testing
import Foundation
@testable import PalmierPro

struct VoiceMasteringTests {
    private func sine(amplitude: Float, seconds: Double, sampleRate: Int = 48_000) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(sampleRate)) }
    }

    @Test func boostsQuietVoiceTowardTarget() {
        var samples = sine(amplitude: 0.02, seconds: 2)
        VoiceMastering.normalize(&samples, sampleRate: 48_000)
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        #expect(abs(rms - VoiceMastering.targetRms) < 0.02 || rms > 0.09)
    }

    @Test func gainNeverPushesPeakAboveCeiling() {
        let samples = sine(amplitude: 0.5, seconds: 1)
        let gain = VoiceMastering.normalizationGain(for: samples, sampleRate: 48_000)
        #expect(0.5 * gain <= VoiceMastering.peakCeiling + 0.001)
    }

    @Test func boostIsCapped() {
        let samples = sine(amplitude: 0.002, seconds: 1)
        let gain = VoiceMastering.normalizationGain(for: samples, sampleRate: 48_000)
        #expect(gain <= VoiceMastering.maxBoost)
    }

    @Test func silenceIsUntouched() {
        let samples = [Float](repeating: 0, count: 48_000)
        #expect(VoiceMastering.normalizationGain(for: samples, sampleRate: 48_000) == 1)
    }

    @Test func emptyInputReturnsUnityGain() {
        #expect(VoiceMastering.normalizationGain(for: [], sampleRate: 48_000) == 1)
    }

    @Test func studioVoiceEffectToggleReadsBack() {
        var clip = Clip(mediaRef: "m1", startFrame: 0, durationFrames: 10)
        #expect(!clip.hasStudioVoiceEnabled)
        clip.effects = [Effect(type: Clip.studioVoiceEffectType, enabled: true)]
        #expect(clip.hasStudioVoiceEnabled)
        clip.effects?[0].enabled = false
        #expect(!clip.hasStudioVoiceEnabled)
    }
}
