import Foundation
import Testing
@testable import PalmierPro

@Suite("Montage planner")
struct MontagePlannerTests {

    /// 0, 15, 30, … — a 120 BPM half-second beat at 30 fps.
    private static func grid(_ count: Int, step: Int = 15, from: Int = 0) -> [Int] {
        (0..<count).map { from + $0 * step }
    }

    private static func request(
        shots: Int,
        energy: MontagePlanner.Energy = .flat,
        maxHoldSteps: Int = 4,
        startFrame: Int = 0,
        gridCount: Int = 40,
        available: [Int?]? = nil
    ) -> MontagePlanner.Request {
        MontagePlanner.Request(
            shotCount: shots,
            startFrame: startFrame,
            gridFrames: grid(gridCount, from: startFrame),
            energy: energy,
            maxHoldSteps: maxHoldSteps,
            availableFrames: available ?? Array(repeating: nil, count: shots)
        )
    }

    @Test func flatEnergyCutsOnEveryBeatWithNoGaps() throws {
        let plan = try MontagePlanner.plan(Self.request(shots: 4))
        #expect(plan.shots.map(\.startFrame) == [0, 15, 30, 45])
        #expect(plan.shots.allSatisfy { $0.durationFrames == 15 })
        #expect(plan.skipped.isEmpty && plan.shortened.isEmpty)
    }

    @Test func shotsAreContiguous() throws {
        let plan = try MontagePlanner.plan(Self.request(shots: 6, energy: .build))
        for (a, b) in zip(plan.shots, plan.shots.dropFirst()) {
            #expect(a.endFrame == b.startFrame, "gap between shot \(a.index) and \(b.index)")
        }
    }

    @Test func buildStartsWideAndEndsOnASingleBeat() throws {
        let plan = try MontagePlanner.plan(Self.request(shots: 5, energy: .build))
        let durations = plan.shots.map(\.durationFrames)
        #expect(durations.first == 60, "first shot should hold the full four beats: \(durations)")
        #expect(durations.last == 15, "last shot should land on one beat: \(durations)")
        #expect(durations == durations.sorted(by: >), "the cut rate must only tighten: \(durations)")
    }

    @Test func buildAndReleaseHoldsTheFinalShotAgain() throws {
        let plan = try MontagePlanner.plan(Self.request(shots: 5, energy: .buildAndRelease))
        let durations = plan.shots.map(\.durationFrames)
        #expect(durations.last == 60, "the payoff shot should return to the widest hold: \(durations)")
        let beforePayoff = durations.dropLast()
        #expect(beforePayoff.last == beforePayoff.min(), "the run must tighten right up to the payoff: \(durations)")
    }

    @Test func aShotShorterThanItsSlotIsReducedAndPullsTheRestEarlier() throws {
        var available: [Int?] = Array(repeating: nil, count: 3)
        available[0] = 20
        let plan = try MontagePlanner.plan(
            Self.request(shots: 3, energy: .build, available: available)
        )
        #expect(plan.shortened == [0])
        #expect(plan.shots[0].durationFrames == 15, "must drop to the largest hold that fits 20 frames")
        #expect(plan.shots[1].startFrame == 15, "later shots pull earlier with it")
    }

    @Test func aSourceTooShortForOneBeatIsSkippedAndReported() throws {
        var available: [Int?] = Array(repeating: nil, count: 3)
        available[1] = 4
        let plan = try MontagePlanner.plan(Self.request(shots: 3, available: available))
        #expect(plan.skipped == [1])
        #expect(plan.shots.map(\.index) == [0, 2])
        #expect(plan.shots[1].startFrame == 15, "the surviving shot takes the skipped slot, leaving no gap")
    }

    @Test func shotsBeyondTheGridAreSkippedRatherThanOverrunningTheMusic() throws {
        let plan = try MontagePlanner.plan(Self.request(shots: 5, gridCount: 3))
        #expect(plan.shots.count == 2)
        #expect(plan.skipped == [2, 3, 4])
    }

    @Test func theGridIsClampedToTheMontageStart() throws {
        let request = MontagePlanner.Request(
            shotCount: 2,
            startFrame: 30,
            gridFrames: [0, 15, 30, 45, 60],
            energy: .flat,
            maxHoldSteps: 4,
            availableFrames: [nil, nil]
        )
        let plan = try MontagePlanner.plan(request)
        #expect(plan.shots.map(\.startFrame) == [30, 45], "beats before the start must not be used")
    }

    @Test func aDistantFirstBeatGainsAPickupSoThePictureStartsWithTheBed() throws {
        let request = MontagePlanner.Request(
            shotCount: 3,
            startFrame: 0,
            gridFrames: [12, 27, 42, 57, 72],
            energy: .flat,
            maxHoldSteps: 4,
            availableFrames: [nil, nil, nil]
        )
        let plan = try MontagePlanner.plan(request)
        #expect(plan.shots.first?.startFrame == 0, "the montage must open on startFrame, not the first beat")
        #expect(plan.shots.map(\.startFrame) == [0, 12, 27], "every later cut still lands on a beat")
    }

    @Test func aFirstBeatCloseToTheStartSnapsOntoItInsteadOfMakingASliver() throws {
        let request = MontagePlanner.Request(
            shotCount: 2,
            startFrame: 0,
            gridFrames: [2, 17, 32, 47],
            energy: .flat,
            maxHoldSteps: 4,
            availableFrames: [nil, nil]
        )
        let plan = try MontagePlanner.plan(request)
        #expect(plan.shots.map(\.startFrame) == [0, 17])
        #expect(plan.shots.first?.durationFrames == 17, "no two-frame opening shot")
    }

    @Test func aGridWithASingleBeatIsRefused() {
        #expect(throws: MontagePlanner.PlanError.gridTooShort) {
            try MontagePlanner.plan(Self.request(shots: 2, gridCount: 1))
        }
    }

    @Test func zeroShotsIsRefused() {
        #expect(throws: MontagePlanner.PlanError.noShots) {
            try MontagePlanner.plan(Self.request(shots: 0))
        }
    }

    @Test func beatSecondsMapToFramesWithoutDuplicates() {
        let frames = MontagePlanner.gridFrames(
            beatSeconds: [0, 0.5, 0.51, 1.0, -1, .infinity], musicStartFrame: 90, fps: 30
        )
        #expect(frames == [90, 105, 120], "0.5 and 0.51 land on the same frame and must collapse")
    }
}
