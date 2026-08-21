import Foundation
import Observation

@MainActor
@Observable
final class StabilizationJobs {
    enum State: String, Sendable {
        case analyzing
        case completed
        case failed
    }

    struct Job: Identifiable, Sendable, Equatable {
        let id: String
        let clipId: String
        let mediaRef: String
        var smoothing: Double
        var signature: String
        var state: State
        var progress: Double = 0
        var cropPercent: Double?
        var analyzedSeconds: ClosedRange<Double>?
        var failureReason: String?
    }

    private(set) var jobs: [String: Job] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    func job(forClip clipId: String) -> Job? { jobs[clipId] }

    func hasTask(forClip clipId: String) -> Bool { tasks[clipId] != nil }

    @discardableResult
    func begin(clipId: String, mediaRef: String, smoothing: Double, signature: String) -> Job {
        let job = Job(
            id: UUID().uuidString,
            clipId: clipId,
            mediaRef: mediaRef,
            smoothing: smoothing,
            signature: signature,
            state: .analyzing
        )
        jobs[clipId] = job
        return job
    }

    func track(_ task: Task<Void, Never>, forClip clipId: String) {
        tasks[clipId] = task
    }

    func report(progress: Double, forClip clipId: String) {
        guard var job = jobs[clipId], job.state == .analyzing else { return }
        job.progress = min(1, max(0, progress))
        jobs[clipId] = job
    }

    func complete(clipId: String, cropPercent: Double, analyzedSeconds: ClosedRange<Double>) {
        tasks.removeValue(forKey: clipId)
        guard var job = jobs[clipId] else { return }
        job.state = .completed
        job.progress = 1
        job.cropPercent = cropPercent
        job.analyzedSeconds = analyzedSeconds
        job.failureReason = nil
        jobs[clipId] = job
    }

    func fail(clipId: String, reason: String) {
        tasks.removeValue(forKey: clipId)
        guard var job = jobs[clipId] else { return }
        job.state = .failed
        job.failureReason = reason
        jobs[clipId] = job
    }

    func forget(clipId: String) {
        tasks.removeValue(forKey: clipId)?.cancel()
        jobs.removeValue(forKey: clipId)
    }

    func forgetAll(except clipIds: Set<String>) {
        for id in jobs.keys where !clipIds.contains(id) { forget(clipId: id) }
        for id in tasks.keys where !clipIds.contains(id) { forget(clipId: id) }
    }

    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        jobs.removeAll()
    }
}
