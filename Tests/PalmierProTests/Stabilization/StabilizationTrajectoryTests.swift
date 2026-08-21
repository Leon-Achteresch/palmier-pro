import Foundation
import Testing

@testable import PalmierPro

@Suite("Stabilization — trajectory math")
struct StabilizationTrajectoryTests {

    private static let aspect = 16.0 / 9.0

    private static func jitter(count: Int, amplitude: Double = 0.004) -> [StabilizationSample] {
        (0..<count).map { i in
            StabilizationSample(
                dx: amplitude * sin(Double(i) * 1.7),
                dy: amplitude * cos(Double(i) * 2.3),
                rotation: 0
            )
        }
    }

    private static func shake(_ path: [StabilizationSample]) -> Double {
        guard path.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<path.count {
            total += (pow(path[i].dx - path[i - 1].dx, 2) + pow(path[i].dy - path[i - 1].dy, 2)).squareRoot()
        }
        return total / Double(path.count - 1)
    }

    private static func stabilizedPath(motions: [StabilizationSample], smoothing: Double) -> [StabilizationSample] {
        let plan = StabilizationTrajectory.plan(motions: motions, smoothing: smoothing, aspect: aspect)
        let raw = StabilizationTrajectory.path(from: motions)
        return zip(raw, plan.samples).map {
            StabilizationSample(dx: $0.dx + $1.dx, dy: $0.dy + $1.dy, rotation: $0.rotation + $1.rotation)
        }
    }

    @Test func smoothingCollapsesJitterIntoASteadierPath() {
        let motions = Self.jitter(count: 150)
        let raw = StabilizationTrajectory.path(from: motions)
        let stabilized = Self.stabilizedPath(motions: motions, smoothing: 0.8)

        #expect(Self.shake(stabilized) < Self.shake(raw) * 0.2)
    }

    @Test(arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
    func strongerSmoothingNeverShakesMoreThanWeaker(_ smoothing: Double) {
        let motions = Self.jitter(count: 150)
        let raw = StabilizationTrajectory.path(from: motions)

        #expect(Self.shake(Self.stabilizedPath(motions: motions, smoothing: smoothing)) <= Self.shake(raw))
    }

    @Test func aSteadyPanIsPreservedRatherThanFought() {
        let motions = [StabilizationSample](repeating: StabilizationSample(dx: 0.002, dy: 0, rotation: 0), count: 120)
        let plan = StabilizationTrajectory.plan(motions: motions, smoothing: 1, aspect: Self.aspect)

        let largestCorrection = plan.samples.map { abs($0.dx) }.max() ?? 0
        #expect(largestCorrection < 1e-9)
        #expect(plan.cropScale == 1)
    }

    @Test func aStillShotNeedsNoCorrectionAndNoCrop() {
        let plan = StabilizationTrajectory.plan(
            motions: [StabilizationSample](repeating: .identity, count: 60),
            smoothing: 0.5,
            aspect: Self.aspect
        )

        let corrected = plan.samples.filter { !$0.isIdentity }
        #expect(corrected.isEmpty)
        #expect(plan.cropScale == 1)
    }

    @Test func emptyMotionYieldsAnEmptyPlan() {
        let plan = StabilizationTrajectory.plan(motions: [], smoothing: 0.5, aspect: Self.aspect)

        #expect(plan.samples.isEmpty)
        #expect(plan.cropScale == 1)
    }

    @Test(arguments: [0.0, 0.05, 0.1, 0.25])
    func translationCoverScaleIsOnePlusTwiceTheOffset(_ offset: Double) {
        let sample = StabilizationSample(dx: offset, dy: -offset / 2, rotation: 0)

        #expect(
            abs(StabilizationTrajectory.coverScale(for: sample, aspect: Self.aspect) - (1 + 2 * offset)) < 1e-12
        )
    }

    @Test(arguments: [1.05, 1.2, 1.35])
    func theRollLimitForACropIsTheInverseOfItsCoverScale(_ scale: Double) {
        let limit = StabilizationTrajectory.maxRotation(forCoverScale: scale, aspect: Self.aspect)

        #expect(limit > 0)
        #expect(abs(StabilizationTrajectory.rotationCoverScale(limit, aspect: Self.aspect) - scale) < 1e-9)
    }

    @Test func cropIsCappedAndCorrectionsAreClampedToWhatTheCapCanCover() {
        var motions = [StabilizationSample](repeating: .identity, count: 120)
        motions[60] = StabilizationSample(dx: 0.6, dy: 0.4, rotation: 0.08)
        let plan = StabilizationTrajectory.plan(motions: motions, smoothing: 1, aspect: Self.aspect)

        #expect(plan.cropScale == ClipStabilization.maxCropScale)
        for sample in plan.samples {
            #expect(
                StabilizationTrajectory.coverScale(for: sample, aspect: Self.aspect)
                    <= ClipStabilization.maxCropScale + 1e-9
            )
        }
    }

    @Test func theSmoothingWindowNeverExceedsHalfTheAnalyzedFrames() {
        #expect(StabilizationTrajectory.smoothingRadius(for: 1, sampleCount: 1) == 0)
        #expect(StabilizationTrajectory.smoothingRadius(for: 1, sampleCount: 10) <= 5)
        #expect(
            StabilizationTrajectory.smoothingRadius(for: 0, sampleCount: 500)
                < StabilizationTrajectory.smoothingRadius(for: 1, sampleCount: 500)
        )
    }

    @Test func nonFiniteSmoothingFallsBackToTheDefaultStrength() {
        #expect(ClipStabilization.clampedSmoothing(.nan) == ClipStabilization.defaultSmoothing)
        #expect(ClipStabilization.clampedSmoothing(-3) == 0)
        #expect(ClipStabilization.clampedSmoothing(9) == 1)
    }
}
