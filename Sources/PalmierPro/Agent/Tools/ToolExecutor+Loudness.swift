import Foundation

extension ToolExecutor {
    private static let measureLoudnessAllowedKeys: Set<String> = [
        "scope", "clipId", "startFrame", "endFrame", "target",
    ]

    func measureLoudness(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.measureLoudnessAllowedKeys, path: "measure_loudness")
        let scope = args.string("scope") ?? "timeline"
        guard ["timeline", "clip"].contains(scope) else {
            throw ToolError("scope must be 'timeline' or 'clip' (got '\(scope)')")
        }
        var target: LoudnessTarget?
        if let raw = args.string("target") {
            guard let parsed = LoudnessTarget(rawValue: raw) else {
                throw ToolError(
                    "invalid target '\(raw)'. Valid: \(LoudnessTarget.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            target = parsed
        }

        let measurement: LoudnessMeasurement
        var receipt: [String: Any] = ["scope": scope]
        do {
            if scope == "clip" {
                guard let clipId = args.string("clipId") else {
                    throw ToolError("scope 'clip' needs a clipId")
                }
                guard args["startFrame"] == nil, args["endFrame"] == nil else {
                    throw ToolError("startFrame/endFrame apply to scope 'timeline' — a clip is measured in full")
                }
                guard let clip = editor.clipFor(id: clipId) else {
                    throw ToolError("Clip not found: \(clipId)")
                }
                guard clip.mediaType == .audio else {
                    throw ToolError(
                        "measure_loudness scope 'clip' needs an audio clip; \(clipId) is \(clip.mediaType.rawValue). "
                            + "Pass the nested audio.id from get_timeline for a video clip's sound."
                    )
                }
                receipt["clipId"] = clipId
                measurement = try await TimelineLoudness.measure(
                    clip: clip,
                    timeline: editor.timeline,
                    resolver: editor.mediaResolver,
                    resolveTimeline: editor.timelineResolver(),
                    missingMediaRefs: editor.missingMediaRefs
                )
            } else {
                guard args["clipId"] == nil else {
                    throw ToolError("clipId applies to scope 'clip'")
                }
                let range = try Self.loudnessWindow(args, totalFrames: editor.timeline.totalFrames)
                if let range { receipt["frameRange"] = [range.lowerBound, range.upperBound] }
                measurement = try await TimelineLoudness.measure(
                    timeline: editor.timeline,
                    resolver: editor.mediaResolver,
                    resolveTimeline: editor.timelineResolver(),
                    missingMediaRefs: editor.missingMediaRefs,
                    frameRange: range
                )
            }
        } catch is CancellationError {
            throw ToolError("measure_loudness was cancelled before it finished.")
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError("Loudness measurement failed: \(error.localizedDescription)")
        }

        receipt["analyzedSeconds"] = Self.rounded(measurement.analyzedSeconds, places: 2)
        if let integrated = measurement.integratedLufs {
            receipt["integratedLufs"] = Self.rounded(integrated, places: 1)
        } else {
            receipt["integratedLufs"] = NSNull()
            receipt["note"] = "Every 400 ms block was gated out — the measured range is silent."
        }
        if let peak = measurement.truePeakDbtp {
            receipt["truePeakDbtp"] = Self.rounded(peak, places: 1)
        }
        if let target {
            receipt["target"] = Self.targetReport(target, measurement: measurement)
        }
        guard let json = Self.jsonString(receipt) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }

    private static func targetReport(_ target: LoudnessTarget, measurement: LoudnessMeasurement) -> [String: Any] {
        var report: [String: Any] = [
            "name": target.rawValue,
            "integratedLufs": target.integratedLufs,
            "truePeakCeilingDbtp": target.truePeakCeilingDbtp,
        ]
        guard let integrated = measurement.integratedLufs else {
            report["note"] = "No loudness to compare — the measured range is silent."
            return report
        }
        let delta = target.integratedLufs - integrated
        report["deltaDb"] = rounded(delta, places: 1)
        if let peak = measurement.truePeakDbtp {
            let peakAfter = peak + delta
            report["truePeakAfterTargetDbtp"] = rounded(peakAfter, places: 1)
            if peakAfter > target.truePeakCeilingDbtp {
                report["note"] = "Applying deltaDb would push true peak to "
                    + String(format: "%.1f", peakAfter)
                    + " dBTP, past the \(target.rawValue) ceiling of \(target.truePeakCeilingDbtp) dBTP."
            }
        }
        return report
    }

    private static func loudnessWindow(_ args: [String: Any], totalFrames: Int) throws -> Range<Int>? {
        let start = args.int("startFrame")
        let end = args.int("endFrame")
        guard start != nil || end != nil else { return nil }
        let lower = max(0, start ?? 0)
        let upper = min(end ?? totalFrames, totalFrames)
        guard upper > lower else {
            throw ToolError(
                "Invalid window [\(lower), \(upper)) — endFrame must be greater than startFrame and inside the timeline (\(totalFrames) frames)."
            )
        }
        return lower..<upper
    }

    private static func rounded(_ value: Double, places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", value))
    }
}
