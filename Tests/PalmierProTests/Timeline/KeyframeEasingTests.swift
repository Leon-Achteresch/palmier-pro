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
}
