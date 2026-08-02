import Foundation
import Testing
@testable import PalmierPro

@Suite("Interpolation easing curves")
struct KeyframeEasingTests {
    @Test func cubicBezierWithLinearControlPointsIsIdentity() {
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(Interpolation.cubicBezier.ease(t, params: [0, 0, 1, 1]) - t) < 1e-4)
        }
    }

    @Test func cubicBezierMatchesCSSEaseReference() {
        let y = Interpolation.cubicBezier.ease(0.5, params: [0.25, 0.1, 0.25, 1.0])
        #expect(abs(y - 0.8024) < 0.01)
    }

    @Test func springOvershootsWhenBouncyAndGlidesWhenDamped() {
        let bouncy = (0...100).map { Interpolation.spring.ease(Double($0) / 100, params: [0.6]) }
        #expect(bouncy.max()! > 1.05)
        #expect(abs(bouncy.last! - 1) < 1e-6)
        let glide = (0...100).map { Interpolation.spring.ease(Double($0) / 100, params: [0]) }
        #expect(glide.max()! <= 1.0 + 1e-6)
    }

    @Test func stepsQuantizesIntoPlateaus() {
        #expect(Interpolation.steps.ease(0.49, params: [2]) == 0)
        #expect(Interpolation.steps.ease(0.51, params: [2]) == 0.5)
        #expect(Interpolation.steps.ease(1, params: [2]) == 1)
    }

    @Test func mirroredSwapsDirectionalPairsAndKeepsSymmetricCurves() {
        #expect(Interpolation.easeIn.mirrored == .easeOut)
        #expect(Interpolation.bounceOut.mirrored == .bounceIn)
        #expect(Interpolation.circOut.mirrored == .circIn)
        #expect(Interpolation.smooth.mirrored == .smooth)
        #expect(Interpolation.spring.mirrored == .spring)
    }

    @Test func sampleUsesEasingParams() {
        let track = KeyframeTrack<Double>(keyframes: [
            Keyframe(frame: 0, value: 0, interpolationOut: .steps, easingParams: [2]),
            Keyframe(frame: 100, value: 1),
        ])
        #expect(track.sample(at: 40, fallback: 0) == 0)
        #expect(track.sample(at: 60, fallback: 0) == 0.5)
    }

    @Test(arguments: [
        Interpolation.sineIn, .sineOut, .sineInOut, .expoIn, .expoOut, .expoInOut,
    ])
    func sineAndExpoHitEndpointsAndStayMonotonic(_ interp: Interpolation) {
        #expect(abs(interp.ease(0)) < 1e-9)
        #expect(abs(interp.ease(1) - 1) < 1e-9)
        let samples = (0...100).map { interp.ease(Double($0) / 100) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
    }

    @Test func expoReferenceValues() {
        #expect(abs(Interpolation.expoOut.ease(0.5) - 0.96875) < 1e-9)
        #expect(abs(Interpolation.expoIn.ease(0.5) - 0.03125) < 1e-9)
        #expect(abs(Interpolation.sineInOut.ease(0.5) - 0.5) < 1e-9)
    }

    @Test func backOvershootParamScalesTheOvershoot() {
        let defaultPeak = (0...100).map { Interpolation.backOut.ease(Double($0) / 100) }.max()!
        let strongPeak = (0...100).map { Interpolation.backOut.ease(Double($0) / 100, params: [4]) }.max()!
        #expect(defaultPeak > 1.05)
        #expect(strongPeak > defaultPeak + 0.05)
        #expect(abs(Interpolation.backOut.ease(1, params: [4]) - 1) < 1e-9)
    }

    @Test func elasticParamsPreserveDefaultAndChangeCharacter() {
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(Interpolation.elasticOut.ease(t) - Interpolation.elasticOut.ease(t, params: [1, 0.3])) < 1e-9)
        }
        func crossings(_ params: [Double]?) -> Int {
            let s = (1...200).map { Interpolation.elasticOut.ease(Double($0) / 200, params: params) - 1 }
            return zip(s, s.dropFirst()).count { $0.sign != $1.sign }
        }
        #expect(crossings([1, 0.15]) > crossings(nil))
        #expect(abs(Interpolation.elasticOut.ease(1, params: [3, 0.5]) - 1) < 1e-9)
    }

    @Test func splitEaseBlendsDepartAndArrivalCurves() {
        let kf = Keyframe(
            frame: 0, value: 0.0,
            interpolationOut: .easeIn, easingParams: nil,
            interpolationIn: .backOut, easingParamsIn: [4]
        )
        #expect(abs(kf.segmentEase(0)) < 1e-9)
        #expect(abs(kf.segmentEase(1) - 1) < 1e-9)
        #expect(abs(kf.segmentEase(0.1) - Interpolation.easeIn.ease(0.1)) < 0.05)
        let nearEnd = (80...99).map { kf.segmentEase(Double($0) / 100) }
        #expect(nearEnd.max()! > 1.0)
        var single = kf
        single.interpolationIn = nil
        #expect(single.segmentEase(0.5) == Interpolation.easeIn.ease(0.5))
    }

    @Test func trackSamplingHonorsSplitEase() {
        let track = KeyframeTrack<Double>(keyframes: [
            Keyframe(frame: 0, value: 0, interpolationOut: .linear, easingParams: nil, interpolationIn: .backOut, easingParamsIn: [4]),
            Keyframe(frame: 100, value: 1),
        ])
        let peak = (0...100).map { track.sample(at: $0, fallback: 0) }.max()!
        #expect(peak > 1.0)
        #expect(track.sample(at: 100, fallback: 0) == 1)
    }

    @Test func upsertKeyframePreservesEasingWhenRestampingValue() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 10, value: 0.5, interpolationOut: .expoOut, easingParams: nil, interpolationIn: .backOut, easingParamsIn: [3]),
        ])
        clip.upsertKeyframe(in: \.opacityTrack, frame: 10, value: 0.8)
        let kf = clip.opacityTrack!.keyframes[0]
        #expect(kf.value == 0.8)
        #expect(kf.interpolationOut == .expoOut)
        #expect(kf.interpolationIn == .backOut)
        #expect(kf.easingParamsIn == [3])
    }

    @Test func fadeEnvelopeHonorsEasing() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.fadeInFrames = 20
        clip.fadeInInterpolation = .expoOut
        #expect(abs(clip.fadeMultiplier(at: 10) - 0.96875) < 1e-9)
        clip.fadeInInterpolation = .linear
        #expect(abs(clip.fadeMultiplier(at: 10) - 0.5) < 1e-9)

        clip.fadeInFrames = 0
        clip.fadeOutFrames = 20
        clip.fadeOutInterpolation = .expoOut
        #expect(abs(clip.fadeMultiplier(at: 90) - (1 - 0.96875)) < 1e-9)
        clip.fadeOutInterpolation = .smooth
        #expect(abs(clip.fadeMultiplier(at: 90) - 0.5) < 1e-9)
    }
}
