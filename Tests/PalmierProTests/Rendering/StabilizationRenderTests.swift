import Foundation
import Testing

@testable import PalmierPro

@Suite("Stabilization — render output")
@MainActor
struct StabilizationRenderTests {

    private static func bake(dx: Double, dy: Double, cropScale: Double = 1) -> ClipStabilization {
        ClipStabilization(
            smoothing: 0.5,
            startSourceSeconds: 0,
            endSourceSeconds: 2,
            sampleRate: 30,
            cropScale: cropScale,
            samples: [StabilizationSample](
                repeating: StabilizationSample(dx: dx, dy: dy, rotation: 0), count: 60
            )
        )
    }

    private static func render(_ stabilization: ClipStabilization?, frame: Int = 15) async throws
        -> CompositorRenderTests.Frame
    {
        var clip = CompositorFixtures.patternClip()
        clip.stabilization = stabilization
        return try await CompositorRenderTests.render(
            CompositorRenderTests.timelineWith(Fixtures.videoTrack(clips: [clip])), frame: frame
        )
    }

    @Test func aHorizontalCorrectionShiftsTheFrameByExactlyThatShareOfItsWidth() async throws {
        let f = try await Self.render(Self.bake(dx: 0.25, dy: 0))

        #expect(CompositorFixtures.isRed(f.at(200, 45)), "top-left quadrant slid right: \(f.at(200, 45))")
        #expect(CompositorFixtures.isGreen(f.at(300, 45)), "top-right quadrant follows: \(f.at(300, 45))")
        #expect(CompositorFixtures.isBlue(f.at(200, 135)), "bottom-left quadrant slid right: \(f.at(200, 135))")
        #expect(CompositorFixtures.isBlack(f.at(20, 45)), "vacated edge is empty: \(f.at(20, 45))")
    }

    @Test func aVerticalCorrectionMovesTheFrameUpInSourceSpace() async throws {
        let f = try await Self.render(Self.bake(dx: 0, dy: 0.25))

        #expect(CompositorFixtures.isRed(f.at(40, 30)), "top-left quadrant slid up: \(f.at(40, 30))")
        #expect(CompositorFixtures.isBlue(f.at(40, 100)), "bottom-left quadrant follows: \(f.at(40, 100))")
        #expect(CompositorFixtures.isBlack(f.at(40, 170)), "vacated edge is empty: \(f.at(40, 170))")
    }

    @Test func theCropZoomHidesTheEdgeTheCorrectionSwingsPast() async throws {
        let f = try await Self.render(Self.bake(dx: 0.1, dy: 0, cropScale: 1.2))

        for y in [20, 90, 160] {
            #expect(!CompositorFixtures.isBlack(f.at(4, y)), "left edge covered at y=\(y): \(f.at(4, y))")
            #expect(!CompositorFixtures.isBlack(f.at(315, y)), "right edge covered at y=\(y): \(f.at(315, y))")
        }
    }

    @Test func anUnanalyzedRequestRendersTheOriginalFraming() async throws {
        let requested = try await Self.render(.requested(smoothing: 0.8))
        let plain = try await Self.render(nil)

        #expect(CompositorFixtures.isRed(requested.at(40, 45)))
        #expect(requested.at(40, 45) == plain.at(40, 45))
        #expect(requested.at(280, 135) == plain.at(280, 135))
    }

    @Test func laterTimelineFramesReadLaterSamplesOfTheBake() async throws {
        var stabilization = Self.bake(dx: 0, dy: 0)
        for index in 30..<60 { stabilization.samples[index].dx = 0.25 }

        let early = try await Self.render(stabilization, frame: 5)
        let late = try await Self.render(stabilization, frame: 45)

        #expect(CompositorFixtures.isRed(early.at(40, 45)), "frame 5 is uncorrected: \(early.at(40, 45))")
        #expect(CompositorFixtures.isBlack(late.at(20, 45)), "frame 45 is shifted: \(late.at(20, 45))")
    }
}
