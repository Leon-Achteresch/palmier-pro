import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

/// End-to-end through the compositor: a pinned layer must land inside its quad and
/// leave the rest of the canvas untouched, static and keyframed.
@Suite("Corner pin — render output")
@MainActor
struct CornerPinRenderTests {

    /// One quad = static params; several = a keyframe track per corner, like the overlay writes.
    private static func pin(_ clip: inout Clip, _ quads: [(frame: Int, quad: CornerPin.Quad)]) {
        var effect = Effect(type: CornerPin.effectType)
        for corner in CornerPin.Corner.allCases {
            func param(_ axis: (CGPoint) -> CGFloat) -> EffectParam {
                guard quads.count > 1 else { return EffectParam(value: Double(axis(quads[0].quad[corner]))) }
                return EffectParam(track: KeyframeTrack(keyframes: quads.map {
                    Keyframe(frame: $0.frame, value: Double(axis($0.quad[corner])), interpolationOut: .linear)
                }))
            }
            effect.params[corner.xKey] = param(\.x)
            effect.params[corner.yKey] = param(\.y)
        }
        clip.effects = (clip.effects ?? []) + [effect]
    }

    /// Left half of the canvas, so the pattern's own quadrants stay distinguishable.
    private static let leftHalf = CornerPin.Quad(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
    private static let rightHalf = CornerPin.Quad(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))

    @Test func staticPinPlacesTheLayerInsideItsQuad() async throws {
        var clip = CompositorFixtures.patternClip()
        Self.pin(&clip, [(0, Self.leftHalf)])

        let f = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15
        )

        #expect(CompositorFixtures.isRed(f.at(40, 45)), "pattern TL squeezed into the left half: \(f.at(40, 45))")
        #expect(CompositorFixtures.isGreen(f.at(120, 45)), "pattern TR still inside the quad: \(f.at(120, 45))")
        #expect(CompositorFixtures.isBlue(f.at(40, 135)), "pattern BL inside the quad: \(f.at(40, 135))")
        #expect(CompositorFixtures.isBlack(f.at(240, 90)), "outside the quad stays empty: \(f.at(240, 90))")
    }

    @Test func pinOverridesTheClipTransform() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.transform = Transform(centerX: 0.8, centerY: 0.8, width: 0.2, height: 0.2)
        Self.pin(&clip, [(0, Self.leftHalf)])

        let f = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15
        )

        #expect(!CompositorFixtures.isBlack(f.at(40, 45)), "pin wins over the transform: \(f.at(40, 45))")
        #expect(CompositorFixtures.isBlack(f.at(260, 150)), "transform's rect is empty: \(f.at(260, 150))")
    }

    @Test func keyframedCornersMoveTheLayerAcrossTheCanvas() async throws {
        var clip = CompositorFixtures.patternClip(duration: 60)
        Self.pin(&clip, [(0, Self.leftHalf), (30, Self.rightHalf)])
        let timeline = CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip]))

        let start = try await CompositorRenderTests.render(timeline, frame: 0)
        let end = try await CompositorRenderTests.render(timeline, frame: 30)

        #expect(!CompositorFixtures.isBlack(start.at(40, 90)), "frame 0 pinned left: \(start.at(40, 90))")
        #expect(CompositorFixtures.isBlack(start.at(280, 90)), "frame 0 right side empty: \(start.at(280, 90))")
        #expect(CompositorFixtures.isBlack(end.at(40, 90)), "frame 30 left side empty: \(end.at(40, 90))")
        #expect(!CompositorFixtures.isBlack(end.at(280, 90)), "frame 30 pinned right: \(end.at(280, 90))")
    }

    @Test func collapsedQuadRendersNothingInsteadOfGarbage() async throws {
        var clip = CompositorFixtures.patternClip()
        Self.pin(&clip, [(0, CornerPin.Quad(rect: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.6)))])

        let f = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15
        )

        #expect(CompositorFixtures.isBlack(f.at(160, 90)), "collapsed pin composites nothing: \(f.at(160, 90))")
    }

    @Test func pinnedLayerCompositesOverThePlate() async throws {
        var overlay = CompositorFixtures.patternClip(id: "overlay")
        Self.pin(&overlay, [(0, Self.leftHalf)])
        var plate = CompositorFixtures.patternClip(id: "plate")
        plate.transform = Transform(flipHorizontal: true)

        let f = try await CompositorRenderTests.render(CompositorRenderTests.timelineWith(
            Fixtures.videoTrack(clips: [overlay]),
            Fixtures.videoTrack(clips: [plate])
        ), frame: 15)

        #expect(CompositorFixtures.isRed(f.at(40, 45)), "overlay covers the plate inside the quad: \(f.at(40, 45))")
        #expect(CompositorFixtures.isRed(f.at(280, 45)), "plate (flipped) shows outside the quad: \(f.at(280, 45))")
    }
}
