import Foundation

extension ToolExecutor {
    fileprivate struct StabilizeClipsInput: DecodableToolArgs {
        let clipIds: [String]
        let smoothing: Double?
        let remove: Bool?
        static let allowedKeys: Set<String> = ["clipIds", "smoothing", "remove"]
    }

    func stabilizeClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: StabilizeClipsInput = try decodeToolArgs(args, path: "stabilize_clips")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        var seen = Set<String>()
        let clipIds = input.clipIds.filter { seen.insert($0).inserted }
        for id in clipIds where editor.clipFor(id: id) == nil {
            throw ToolError("Clip not found: \(id)")
        }

        if input.remove == true {
            guard input.smoothing == nil else {
                throw ToolError("stabilize_clips: smoothing does not apply to remove:true")
            }
            return removeStabilization(editor, clipIds: clipIds)
        }

        let smoothing = input.smoothing ?? ClipStabilization.defaultSmoothing
        let fps = editor.timeline.fps
        for id in clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            do {
                try clip.validateStabilization(smoothing: smoothing, fps: fps)
            } catch {
                throw ToolError("\(error.message) [\(error.code)]")
            }
        }

        let requested = Set(clipIds)
        let retries = editor.stabilizationRetryTargets(clipIds: requested, smoothing: smoothing)
        let restarts = editor.stabilizationWriteTargets(clipIds: requested, enabled: true, smoothing: smoothing)
            .union(retries)
        let priorFailures = Dictionary(uniqueKeysWithValues: retries.compactMap { id in
            editor.stabilizationJobs.job(forClip: id)?.failureReason.map { (id, $0) }
        })
        let snapshot = timelineSnapshot(editor)
        var touched: Set<String> = []
        if !restarts.isEmpty {
            let actionName = "Stabilize Clips (Agent)"
            touched = editor.undo.perform(actionName) {
                editor.setStabilization(
                    clipIds: restarts,
                    enabled: true,
                    smoothing: smoothing,
                    actionName: actionName
                )
            }
        }

        var notes: [String] = []
        let reports = clipIds.map {
            stabilizationReport(editor, clipId: $0, priorFailure: priorFailures[$0], notes: &notes)
        }
        if restarts.isEmpty {
            notes.append("No analysis was started — these clips already carry this stabilization.")
        }
        return mutationResult(
            editor,
            since: snapshot,
            touched: Array(touched),
            extra: ["stabilize": reports],
            notes: notes
        )
    }

    private func removeStabilization(_ editor: EditorViewModel, clipIds: [String]) -> ToolResult {
        let touched = clipIds.filter { editor.clipFor(id: $0)?.stabilization != nil }
        guard !touched.isEmpty else {
            return .ok(Self.jsonString([
                "status": "noop",
                "reason": "None of these clips are stabilized.",
            ]) ?? "{}")
        }
        let snapshot = timelineSnapshot(editor)
        let actionName = "Remove Stabilization (Agent)"
        editor.undo.perform(actionName) {
            editor.setStabilization(clipIds: Set(touched), enabled: false, actionName: actionName)
        }
        return mutationResult(
            editor,
            since: snapshot,
            touched: touched,
            extra: ["stabilize": touched.map { ["clipId": $0, "status": "removed"] }]
        )
    }

    private func stabilizationReport(
        _ editor: EditorViewModel,
        clipId: String,
        priorFailure: String?,
        notes: inout [String]
    ) -> [String: Any] {
        var report: [String: Any] = ["clipId": clipId]
        guard let clip = editor.clipFor(id: clipId), let stabilization = clip.stabilization else {
            report["status"] = "removed"
            return report
        }
        if let priorFailure {
            report["retriedAfterFailure"] = priorFailure
            notes.append("Clip \(clipId): the previous analysis failed (\(priorFailure)) — retrying.")
        }
        report["smoothing"] = Self.roundedStabilizationValue(stabilization.smoothing, places: 2)
        let job = editor.stabilizationJobs.job(forClip: clipId)
        if let job { report["jobId"] = job.id }

        if stabilization.isAnalyzed, !clip.stabilizationIsStale(fps: editor.timeline.fps) {
            report["status"] = "ready"
            report["cropPercent"] = Self.roundedStabilizationValue(stabilization.cropPercent, places: 1)
            report["analyzedSourceSeconds"] = [
                Self.roundedStabilizationValue(stabilization.startSourceSeconds, places: 3),
                Self.roundedStabilizationValue(stabilization.endSourceSeconds, places: 3),
            ]
            if stabilization.cropPercent >= 15 {
                notes.append(
                    "Clip \(clipId) needed a \(String(format: "%.0f", stabilization.cropPercent))% crop — lower smoothing to keep more of the frame."
                )
            }
            return report
        }

        if job?.state == .failed {
            report["status"] = "failed"
            report["reason"] = job?.failureReason ?? "Analysis failed."
        } else {
            report["status"] = "analyzing"
            report["progress"] = Self.roundedStabilizationValue(job?.progress ?? 0, places: 2)
        }
        return report
    }

    private static func roundedStabilizationValue(_ value: Double, places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", value.isFinite ? value : 0))
    }
}
