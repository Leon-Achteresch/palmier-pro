import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("Compositor — adjustment layers")
@MainActor
struct AdjustmentLayerRenderTests {

    static let size = CompositorFixtures.renderSize

    static func invertingLayer(start: Int = 0, duration: Int = 60, opacity: Double = 1) -> Clip {
        var clip = AdjustmentLayer.clip(startFrame: start, durationFrames: duration)
        clip.effects = [Effect(type: "stylize.invert", params: [:])]
        clip.opacity = opacity
        return clip
    }

    static func halfWidthClip(id: String, centerX: Double) -> Clip {
        var clip = CompositorFixtures.patternClip(id: id)
        clip.transform = Transform(centerX: centerX, centerY: 0.5, width: 0.5, height: 1)
        return clip
    }

    @Test func gradesLayersBelowButNotAbove() async throws {
        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [Self.halfWidthClip(id: "top", centerX: 0.75)]),
            Fixtures.videoTrack(clips: [Self.invertingLayer()]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "bottom")]),
        ])
        let f = try await CompositorRenderTests.render(timeline, frame: 15)

        let below = f.at(80, 45)
        #expect(below.r < 100 && below.g > 140 && below.b > 140, "red below the layer should invert to cyan: \(below)")
        #expect(isRed(f.at(200, 45)), "the clip above the layer keeps its colors: \(f.at(200, 45))")
    }

    @Test func opacityMixesGradeStrength() async throws {
        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [Self.invertingLayer(opacity: 0.5)]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()]),
        ])
        let f = try await CompositorRenderTests.render(timeline, frame: 15)

        let mixed = f.tl
        #expect(mixed.r > 90 && mixed.r < 170, "half-strength invert of red: \(mixed)")
        #expect(mixed.g > 90 && mixed.g < 170, "half-strength invert of red: \(mixed)")
        #expect(mixed.b > 90 && mixed.b < 170, "half-strength invert of red: \(mixed)")
    }

    @Test func zeroOpacityLeavesTheStackUntouched() async throws {
        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [Self.invertingLayer(opacity: 0)]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()]),
        ])
        let f = try await CompositorRenderTests.render(timeline, frame: 15)
        #expect(isRed(f.tl), "TL \(f.tl)")
        #expect(isWhite(f.br), "BR \(f.br)")
    }

    @Test func emptyAdjustmentLayerIsANoOp() async throws {
        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [AdjustmentLayer.clip(startFrame: 0, durationFrames: 60)]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()]),
        ])
        let f = try await CompositorRenderTests.render(timeline, frame: 15)
        #expect(isRed(f.tl), "TL \(f.tl)")
        #expect(isGreen(f.tr), "TR \(f.tr)")
        #expect(isBlue(f.bl), "BL \(f.bl)")
        #expect(isWhite(f.br), "BR \(f.br)")
    }

    @Test func gradeAppliesOnlyWithinItsSpan() async throws {
        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [Self.invertingLayer(start: 0, duration: 30)]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(duration: 60)]),
        ])

        let inside = try await CompositorRenderTests.render(timeline, frame: 15)
        #expect(inside.tl.r < 100, "inside the span red inverts: \(inside.tl)")

        let outside = try await CompositorRenderTests.render(timeline, frame: 45)
        #expect(isRed(outside.tl), "after the span the frame is untouched: \(outside.tl)")
    }

    @Test func adjustmentInsideNestStaysInsideThatNest() async throws {
        let child = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [Self.invertingLayer()]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "child")]),
        ])
        var nest = Clip(
            mediaRef: child.id, mediaType: .sequence, sourceClipType: .sequence,
            startFrame: 0, durationFrames: child.totalFrames
        )
        nest.transform = Transform(centerX: 0.25, centerY: 0.5, width: 0.5, height: 1)
        let parent = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [nest]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip(id: "parent")]),
        ])

        let f = try await CompositorRenderTests.render(parent, frame: 15, timelines: [child, parent])
        let inNest = f.at(40, 45)
        #expect(inNest.r < 100 && inNest.g > 140 && inNest.b > 140, "the nest's own layer inverts: \(inNest)")
        #expect(isWhite(f.at(280, 135)), "the parent clip beside the nest is untouched: \(f.at(280, 135))")
    }

    @Test func adjustmentLayerAddsNoCompositionTrack() async throws {
        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [Self.invertingLayer()]),
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()]),
        ])
        let pattern = try await CompositorFixtures.patternVideoURL()
        let result = try await CompositionBuilder.build(
            timeline: timeline, resolveURL: { _ in pattern }, renderSize: Self.size
        )
        #expect(result.trackMappings.count(where: \.isVideo) == 2)
        #expect(result.offlineMediaRefs.isEmpty)
    }
}

private let isRed = CompositorFixtures.isRed
private let isGreen = CompositorFixtures.isGreen
private let isBlue = CompositorFixtures.isBlue
private let isWhite = CompositorFixtures.isWhite
