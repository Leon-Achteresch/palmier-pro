import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite("Corner pin — model")
struct CornerPinModelTests {

    private func pinned(_ params: [String: EffectParam], start: Int = 0) -> Clip {
        var clip = Fixtures.clip(id: "c1", mediaRef: "m", start: start, duration: 60)
        clip.effects = [Effect(type: CornerPin.effectType, params: params)]
        return clip
    }

    @Test func unpinnedClipHasNoQuad() {
        #expect(Fixtures.clip(id: "c1", start: 0, duration: 30).cornerPinQuad(at: 0) == nil)
    }

    @Test func disabledPinHasNoQuad() {
        var clip = pinned([:])
        clip.effects?[0].enabled = false
        #expect(clip.cornerPinQuad(at: 0) == nil)
    }

    @Test func missingParamsFallBackToTheFullCanvas() throws {
        let quad = try #require(pinned([:]).cornerPinQuad(at: 0))
        #expect(quad == CornerPin.Quad.canvas)
    }

    @Test func keyframedCornersResolveAtClipRelativeFrames() throws {
        let track = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.2, interpolationOut: .linear),
            Keyframe(frame: 20, value: 0.6, interpolationOut: .linear),
        ])
        let clip = pinned([CornerPin.Corner.topLeft.xKey: EffectParam(track: track)], start: 100)

        #expect(clip.cornerPinQuad(at: 100)?.topLeft.x == 0.2)
        #expect(clip.cornerPinQuad(at: 120)?.topLeft.x == 0.6)
        let mid = try #require(clip.cornerPinQuad(at: 110)?.topLeft.x)
        #expect(abs(mid - 0.4) < 1e-6, "linear midpoint, got \(mid)")
    }

    @Test func staticParamsWinWhenNoTrackIsActive() throws {
        let clip = pinned([CornerPin.Corner.bottomRight.yKey: EffectParam(value: 0.75)])
        #expect(clip.cornerPinQuad(at: 0)?.bottomRight.y == 0.75)
    }

    @Test(arguments: [
        (CornerPin.Quad.canvas, true),
        (CornerPin.Quad(rect: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.5)), false),
        (CornerPin.Quad(topLeft: .zero, topRight: CGPoint(x: 1, y: 0),
                        bottomRight: CGPoint(x: 1, y: .nan), bottomLeft: CGPoint(x: 0, y: 1)), false),
    ])
    func collapsedOrNonFiniteQuadsAreNotRenderable(quad: CornerPin.Quad, renderable: Bool) {
        #expect(quad.isRenderable(in: CGSize(width: 320, height: 180)) == renderable)
    }

    @Test func containsTestsTheWarpedQuadNotItsBoundingBox() {
        let quad = CornerPin.Quad(
            topLeft: CGPoint(x: 0.5, y: 0), topRight: CGPoint(x: 1, y: 0.5),
            bottomRight: CGPoint(x: 0.5, y: 1), bottomLeft: CGPoint(x: 0, y: 0.5)
        )
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(quad.contains(CGPoint(x: 50, y: 50), in: rect))
        #expect(!quad.contains(CGPoint(x: 5, y: 5), in: rect), "corner outside the diamond")
    }

    @Test func animatedFlagFollowsTheParamTracks() {
        #expect(!pinned([CornerPin.Corner.topLeft.xKey: EffectParam(value: 0.1)]).isCornerPinAnimated)
        let track = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.1)])
        #expect(pinned([CornerPin.Corner.topLeft.xKey: EffectParam(track: track)]).isCornerPinAnimated)
    }

    @Test func effectRoundTripsThroughCodable() throws {
        let track = KeyframeTrack(keyframes: [Keyframe(frame: 4, value: 0.9, interpolationOut: .linear)])
        let clip = pinned([CornerPin.Corner.topRight.xKey: EffectParam(value: 1, track: track)])
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.cornerPinQuad(at: 4)?.topRight.x == 0.9)
    }
}
