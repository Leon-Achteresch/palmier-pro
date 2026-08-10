import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite("Mesh warp — model")
struct MeshWarpModelTests {

    private func warped(_ params: [String: EffectParam], start: Int = 0) -> Clip {
        var clip = Fixtures.clip(id: "c1", mediaRef: "m", start: start, duration: 60)
        clip.effects = [Effect(type: MeshWarp.effectType, params: params)]
        return clip
    }

    @Test func unwarpedClipHasNoGrid() {
        #expect(Fixtures.clip(id: "c1", start: 0, duration: 30).meshWarpGrid(at: 0) == nil)
    }

    @Test func disabledWarpHasNoGrid() {
        var clip = warped([:])
        clip.effects?[0].enabled = false
        #expect(clip.meshWarpGrid(at: 0) == nil)
    }

    @Test func missingParamsFallBackToTheFullCanvas() throws {
        let grid = try #require(warped([:]).meshWarpGrid(at: 0))
        #expect(grid == MeshWarp.Grid.canvas)
    }

    @Test func defaultGridSurfaceIsTheIdentity() {
        let grid = MeshWarp.Grid.canvas
        for (u, v) in [(0.0, 0.0), (0.25, 0.75), (0.5, 0.5), (1.0, 0.3)] {
            let p = grid.surfacePoint(u: u, v: v)
            #expect(abs(p.x - u) < 1e-9 && abs(p.y - v) < 1e-9, "identity at (\(u), \(v)), got \(p)")
        }
    }

    @Test func surfacePassesThroughEveryControlPoint() {
        var grid = MeshWarp.Grid.canvas
        grid[.center] = CGPoint(x: 0.3, y: 0.7)
        grid[.topCenter] = CGPoint(x: 0.6, y: -0.1)
        for point in MeshWarp.Point.allCases {
            let node = point.defaultPoint
            let p = grid.surfacePoint(u: node.x, v: node.y)
            #expect(abs(p.x - grid[point].x) < 1e-9 && abs(p.y - grid[point].y) < 1e-9)
        }
    }

    @Test func keyframedPointsResolveAtClipRelativeFrames() throws {
        let track = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.2, interpolationOut: .linear),
            Keyframe(frame: 20, value: 0.6, interpolationOut: .linear),
        ])
        let clip = warped([MeshWarp.Point.center.xKey: EffectParam(track: track)], start: 100)

        #expect(clip.meshWarpGrid(at: 100)?[.center].x == 0.2)
        #expect(clip.meshWarpGrid(at: 120)?[.center].x == 0.6)
        let mid = try #require(clip.meshWarpGrid(at: 110)?[.center].x)
        #expect(abs(mid - 0.4) < 1e-6, "linear midpoint, got \(mid)")
    }

    @Test(arguments: [
        (MeshWarp.Grid.canvas, true),
        (MeshWarp.Grid(rect: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.5)), false),
        (MeshWarp.Grid(points: MeshWarp.Grid.canvas.points.enumerated().map {
            $0.offset == 4 ? CGPoint(x: CGFloat.nan, y: 0.5) : $0.element
        }), false),
    ])
    func collapsedOrNonFiniteGridsAreNotRenderable(grid: MeshWarp.Grid, renderable: Bool) {
        #expect(grid.isRenderable(in: CGSize(width: 320, height: 180)) == renderable)
    }

    @Test func containsFollowsTheBentBoundary() {
        var grid = MeshWarp.Grid(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        grid[.topCenter] = CGPoint(x: 0.5, y: 0.05)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(grid.contains(CGPoint(x: 50, y: 15), in: rect), "under the bulged top edge")
        #expect(!grid.contains(CGPoint(x: 30, y: 15), in: rect), "outside the bulge")
        #expect(!grid.contains(CGPoint(x: 10, y: 50), in: rect), "left of the grid")
    }

    @Test func animatedFlagFollowsTheParamTracks() {
        #expect(!warped([MeshWarp.Point.center.xKey: EffectParam(value: 0.1)]).isMeshWarpAnimated)
        let track = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.1)])
        #expect(warped([MeshWarp.Point.center.xKey: EffectParam(track: track)]).isMeshWarpAnimated)
    }

    @Test func effectRoundTripsThroughCodable() throws {
        let track = KeyframeTrack(keyframes: [Keyframe(frame: 4, value: 0.9, interpolationOut: .linear)])
        let clip = warped([MeshWarp.Point.midRight.xKey: EffectParam(value: 1, track: track)])
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.meshWarpGrid(at: 4)?[.midRight].x == 0.9)
    }
}

/// End-to-end through the compositor: the default grid must reproduce the plain
/// placement, a moved center must bend the sampling, and collapsed grids render nothing.
@Suite("Mesh warp — render output")
@MainActor
struct MeshWarpRenderTests {

    private static func warp(_ clip: inout Clip, _ grid: MeshWarp.Grid) {
        var effect = Effect(type: MeshWarp.effectType)
        for point in MeshWarp.Point.allCases {
            effect.params[point.xKey] = EffectParam(value: Double(grid[point].x))
            effect.params[point.yKey] = EffectParam(value: Double(grid[point].y))
        }
        clip.effects = (clip.effects ?? []) + [effect]
    }

    @Test func defaultShapedGridReproducesThePlainPlacement() async throws {
        var clip = CompositorFixtures.patternClip()
        Self.warp(&clip, MeshWarp.Grid(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))

        let f = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15
        )

        #expect(CompositorFixtures.isRed(f.at(40, 45)), "pattern TL squeezed into the left half: \(f.at(40, 45))")
        #expect(CompositorFixtures.isGreen(f.at(120, 45)), "pattern TR inside the grid: \(f.at(120, 45))")
        #expect(CompositorFixtures.isBlue(f.at(40, 135)), "pattern BL inside the grid: \(f.at(40, 135))")
        #expect(CompositorFixtures.isBlack(f.at(240, 90)), "outside the grid stays empty: \(f.at(240, 90))")
    }

    @Test func movedCenterBendsTheSampling() async throws {
        var clip = CompositorFixtures.patternClip()
        var grid = MeshWarp.Grid(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        grid[.center] = CGPoint(x: 0.1, y: 0.5)
        Self.warp(&clip, grid)

        let f = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15
        )

        // Pulling the center left drags the u=0.5 seam past canvas x=0.2, so (64, 45)
        // now samples the pattern's right half instead of its left.
        #expect(CompositorFixtures.isGreen(f.at(64, 45)), "bent seam shows TR here: \(f.at(64, 45))")
        #expect(CompositorFixtures.isBlack(f.at(200, 45)), "fixed boundary keeps the right side empty: \(f.at(200, 45))")
    }

    @Test func warpOverridesTheClipTransform() async throws {
        var clip = CompositorFixtures.patternClip()
        clip.transform = Transform(centerX: 0.8, centerY: 0.8, width: 0.2, height: 0.2)
        Self.warp(&clip, MeshWarp.Grid(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))

        let f = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15
        )

        #expect(!CompositorFixtures.isBlack(f.at(40, 45)), "warp wins over the transform: \(f.at(40, 45))")
        #expect(CompositorFixtures.isBlack(f.at(260, 150)), "transform's rect is empty: \(f.at(260, 150))")
    }

    @Test func collapsedGridRendersNothingInsteadOfGarbage() async throws {
        var clip = CompositorFixtures.patternClip()
        Self.warp(&clip, MeshWarp.Grid(rect: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.6)))

        let f = try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: 15
        )

        #expect(CompositorFixtures.isBlack(f.at(160, 90)), "collapsed grid composites nothing: \(f.at(160, 90))")
    }
}
