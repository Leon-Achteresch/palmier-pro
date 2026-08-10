import Foundation
import Testing
@testable import PalmierPro

@MainActor
struct MotionBakeProgressTests {

    @Test func queueFractionSpansPendingRunningAndFinishedJobs() {
        let progress = MotionBakeProgress()
        progress.setPending([(id: "a", totalFrames: 100), (id: "b", totalFrames: 100)])
        #expect(progress.isActive)
        #expect(progress.jobCount == 2)
        #expect(progress.fractionCompleted == 0)

        progress.begin(id: "a", totalFrames: 100)
        for _ in 0..<100 { progress.advance(id: "a") }
        #expect(progress.fractionCompleted == 0.5)

        progress.end(id: "a")
        #expect(progress.finishedCount == 1)
        #expect(progress.fractionCompleted == 0.5)

        progress.end(id: "b")
        #expect(!progress.isActive)
        #expect(progress.finishedCount == 0)
    }

    @Test func estimateUsesMeasuredFrameRateAcrossTheRemainingQueue() {
        let progress = MotionBakeProgress()
        progress.setPending([(id: "a", totalFrames: 50), (id: "b", totalFrames: 100)])
        progress.begin(id: "a", totalFrames: 50)

        let start = Date(timeIntervalSinceReferenceDate: 1000)
        for i in 0..<20 { progress.advance(id: "a", now: start.addingTimeInterval(Double(i))) }
        let eta = progress.estimatedSecondsRemaining(now: start.addingTimeInterval(20))
        #expect(eta != nil)
        if let eta { #expect(abs(eta - 130) < 5) }
    }

    @Test func estimateIsNilBeforeEnoughFramesWereMeasured() {
        let progress = MotionBakeProgress()
        progress.begin(id: "a", totalFrames: 100)
        for _ in 0..<5 { progress.advance(id: "a") }
        #expect(progress.estimatedSecondsRemaining() == nil)
    }

    @Test func setPendingKeepsRunningJobsAndDropsStaleQueuedOnes() {
        let progress = MotionBakeProgress()
        progress.setPending([(id: "stale", totalFrames: 100)])
        progress.begin(id: "running", totalFrames: 100)
        progress.advance(id: "running")

        progress.setPending([(id: "fresh", totalFrames: 10)])
        #expect(progress.jobCount == 2)
        progress.end(id: "running")
        progress.end(id: "fresh")
        #expect(!progress.isActive)
    }

    @Test func advanceOnUnknownJobAndRepeatedEndAreNoops() {
        let progress = MotionBakeProgress()
        progress.advance(id: "ghost")
        progress.end(id: "ghost")
        #expect(!progress.isActive)
        #expect(progress.fractionCompleted == 0)
    }
}
