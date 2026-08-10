import Foundation
import Observation

/// Live progress of motion-scene bakes, driving the preview's loading indicator.
@MainActor
@Observable
final class MotionBakeProgress {
    static let shared = MotionBakeProgress()

    private struct Job {
        var totalFrames: Int
        var doneFrames = 0
        var isRunning = false
    }

    private var jobs: [String: Job] = [:]
    private var framesFinished = 0
    private var measureStart: Date?
    private var framesMeasured = 0
    private(set) var finishedCount = 0

    var isActive: Bool { !jobs.isEmpty }

    var jobCount: Int { jobs.count + finishedCount }

    var fractionCompleted: Double {
        let total = framesFinished + jobs.values.reduce(0) { $0 + $1.totalFrames }
        guard total > 0 else { return 0 }
        let done = framesFinished + jobs.values.reduce(0) { $0 + $1.doneFrames }
        return Double(done) / Double(total)
    }

    /// Nil until enough frames were measured for a stable rate.
    func estimatedSecondsRemaining(now: Date = Date()) -> Double? {
        guard let measureStart, framesMeasured >= 20 else { return nil }
        let elapsed = now.timeIntervalSince(measureStart)
        guard elapsed > 0.5 else { return nil }
        let rate = Double(framesMeasured) / elapsed
        guard rate > 0 else { return nil }
        let remaining = jobs.values.reduce(0) { $0 + max(0, $1.totalFrames - $1.doneFrames) }
        return Double(remaining) / rate
    }

    /// Replaces the queued jobs a composition build discovered; running bakes are kept untouched.
    func setPending(_ pending: [(id: String, totalFrames: Int)]) {
        var next = jobs.filter { $0.value.isRunning }
        for job in pending where next[job.id] == nil {
            next[job.id] = Job(totalFrames: max(1, job.totalFrames))
        }
        jobs = next
        if jobs.isEmpty { reset() }
    }

    func begin(id: String, totalFrames: Int) {
        var job = jobs[id] ?? Job(totalFrames: max(1, totalFrames))
        job.totalFrames = max(1, totalFrames)
        job.isRunning = true
        jobs[id] = job
    }

    func advance(id: String, now: Date = Date()) {
        guard var job = jobs[id] else { return }
        job.doneFrames = min(job.totalFrames, job.doneFrames + 1)
        jobs[id] = job
        if measureStart == nil { measureStart = now }
        framesMeasured += 1
    }

    func end(id: String) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        finishedCount += 1
        framesFinished += job.totalFrames
        if jobs.isEmpty { reset() }
    }

    private func reset() {
        framesFinished = 0
        measureStart = nil
        framesMeasured = 0
        finishedCount = 0
    }
}
