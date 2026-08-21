import Foundation

extension ToolExecutor {
    private static let manageReferencesKeys: Set<String> = ["action", "mediaRef", "path", "name", "referenceId"]
    private static let reviewTimelineKeys: Set<String> = ["referenceId"]

    func manageReferences(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.manageReferencesKeys, path: "manage_references")
        let action = try args.requireString("action")
        let library = ReferenceLibrary.shared
        switch action {
        case "list":
            await library.ensureLoaded()
            let out: [String: Any] = [
                "count": library.profiles.count,
                "references": library.profiles.map { Self.referencePayload($0) },
            ]
            return try Self.okJSON(out)
        case "analyze":
            let url: URL
            let fallbackName: String
            if let mediaRef = args.string("mediaRef") {
                let asset = try asset(mediaRef, editor: editor)
                guard asset.type == .video else {
                    throw ToolError("manage_references: analyze needs a video; \(mediaRef) is \(asset.type.rawValue).")
                }
                url = asset.url
                fallbackName = asset.name
            } else if let path = args.string("path") {
                guard path.hasPrefix("/") else {
                    throw ToolError("manage_references: path must be absolute.")
                }
                url = URL(fileURLWithPath: path)
                fallbackName = url.deletingPathExtension().lastPathComponent
            } else {
                throw ToolError("manage_references: analyze needs mediaRef or path.")
            }
            let name = args.string("name") ?? fallbackName
            let result = try await ReferenceAnalyzer.analyze(url: url, name: name)
            try await library.add(result.profile)
            var out = Self.referencePayload(result.profile)
            out["warnings"] = result.warnings
            return try Self.okJSON(out)
        case "remove":
            let id = try args.requireString("referenceId")
            guard try await library.remove(id: id) else {
                throw ToolError("Reference not found: \(id). Call manage_references with action='list'.")
            }
            return try Self.okJSON(["removed": id])
        default:
            throw ToolError("manage_references: unknown action '\(action)'. Use analyze, list, or remove.")
        }
    }

    func reviewTimeline(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.reviewTimelineKeys, path: "review_timeline")
        var reference: ReferenceProfile?
        if let referenceId = args.string("referenceId") {
            guard let found = await ReferenceLibrary.shared.profile(id: referenceId) else {
                throw ToolError("Reference not found: \(referenceId). Call manage_references with action='list'.")
            }
            reference = found
        }

        let timeline = editor.timeline
        let fps = timeline.fps
        guard timeline.totalFrames > 0, fps > 0 else {
            return .ok(#"{"note":"Timeline is empty — nothing to review."}"#)
        }
        let fpsD = Double(fps)

        var notes: [String] = []
        var stats: TimelineShotStats?
        var gapList: [(start: Int, end: Int)] = []
        var cuts: [Int] = []
        if let primaryIndex = TimelineReview.primaryVideoTrackIndex(timeline) {
            let clips = timeline.tracks[primaryIndex].clips
            stats = TimelineReview.shotStats(clips: clips, fps: fps, totalFrames: timeline.totalFrames)
            gapList = TimelineReview.gaps(in: clips.filter { !$0.mediaType.isSourcelessLayer })
            cuts = TimelineReview.cutFrames(clips)
        } else {
            notes.append("No video clips found — pacing metrics unavailable.")
        }

        var beatFrames: [Int] = []
        for track in timeline.tracks where track.type == .audio && !track.muted {
            for clip in track.clips {
                guard let analysis = editor.mediaVisualCache.beatAnalysis(for: clip.mediaRef) else { continue }
                for beat in analysis.beats {
                    if let frame = clip.timelineFrame(sourceSeconds: beat, fps: fps) {
                        beatFrames.append(frame)
                    }
                }
            }
        }
        if beatFrames.isEmpty, timeline.hasAudioClips {
            notes.append("No cached beat analysis; run detect_beats on the music first to get cut-to-beat metrics.")
        }
        let tolerance = max(2, Int((fpsD * 0.08).rounded()))
        let alignment = TimelineReview.beatAlignment(cutFrames: cuts, beatFrames: beatFrames, toleranceFrames: tolerance)

        let findings = TimelineReview.findings(
            stats: stats,
            gaps: gapList,
            fps: fps,
            alignment: alignment,
            beatCount: beatFrames.count,
            toleranceFrames: tolerance,
            reference: reference
        )

        var metrics: [String: Any] = [
            "durationSeconds": Self.r2ref(Double(timeline.totalFrames) / fpsD),
        ]
        if let stats {
            metrics["pacing"] = Self.pacingPayload(stats.pacing)
            metrics["longestShot"] = [
                "clipId": stats.longestClipId,
                "seconds": Self.r2ref(stats.longestSeconds),
            ] as [String: Any]
        }
        if !gapList.isEmpty {
            metrics["gaps"] = gapList.map { ["start": $0.start, "end": $0.end] }
        }
        if let alignment {
            metrics["beatAlignment"] = [
                "matchedFraction": Self.r2ref(alignment.matchedFraction),
                "meanAbsOffsetFrames": Self.r2ref(alignment.meanAbsOffsetFrames),
                "toleranceFrames": tolerance,
                "beatCount": beatFrames.count,
            ] as [String: Any]
        }

        var out: [String: Any] = [
            "metrics": metrics,
            "findings": findings,
            "capture": Self.capturePlan(timeline: timeline, cutFrames: cuts),
        ]
        if let reference {
            var referenceOut = Self.referencePayload(reference)
            if let stats, let referencePacing = reference.pacing, referencePacing.averageShotSeconds > 0 {
                referenceOut["pacingRatio"] = Self.r2ref(stats.pacing.averageShotSeconds / referencePacing.averageShotSeconds)
            }
            if reference.look != nil {
                referenceOut["lookNote"] = "Compare against the timeline's look with inspect_color on representative clips."
            }
            out["reference"] = referenceOut
        }
        if !notes.isEmpty { out["notes"] = notes }
        return try Self.okJSON(out)
    }

    private static func capturePlan(timeline: Timeline, cutFrames: [Int]) -> [String: Any] {
        var frames: Set<Int> = [0, max(0, timeline.totalFrames - 1)]
        if cutFrames.count <= 6 {
            frames.formUnion(cutFrames)
        } else {
            let stride = Double(cutFrames.count - 1) / 5
            for step in 0..<6 {
                frames.insert(cutFrames[Int((Double(step) * stride).rounded())])
            }
        }
        let textStarts = timeline.tracks
            .filter { $0.type == .video }
            .flatMap(\.clips)
            .filter { $0.mediaType == .text && $0.captionGroupId == nil }
            .map(\.startFrame)
        frames.formUnion(textStarts.prefix(4))
        return [
            "frames": frames.sorted(),
            "rubric": [
                "Is every visible text fully readable against its background?",
                "Is the subject framed intact — nothing important cut off at the edges?",
                "Do exposure and color match across consecutive shots, or is there a visible jump?",
                "Does the first frame work as a scroll-stopping hook on its own?",
                "Is anything unintentionally covered by overlays, captions, or letterboxing?",
            ],
            "note": "This tool never looks at pixels. Render each frame with capture_frame and answer every rubric question with yes/no plus evidence before calling the review complete.",
        ]
    }

    private static func referencePayload(_ profile: ReferenceProfile) -> [String: Any] {
        var out: [String: Any] = [
            "referenceId": profile.id,
            "name": profile.name,
            "source": profile.sourceFileName,
            "durationSeconds": r2ref(profile.durationSeconds),
        ]
        if let pacing = profile.pacing { out["pacing"] = pacingPayload(pacing) }
        if let bpm = profile.bpm { out["bpm"] = r2ref(bpm) }
        if let audio = profile.audio {
            out["audio"] = [
                "energyMean": r2ref(audio.energyMean),
                "quietFraction": r2ref(audio.quietFraction),
            ] as [String: Any]
        }
        if let look = profile.look {
            out["look"] = [
                "lumaMean": r2ref(look.lumaMean),
                "saturationMean": r2ref(look.saturationMean),
                "warmCoolBias": r2ref(look.warmCoolBias),
                "hueHistogram": look.hueHistogram.map { r2ref($0) },
            ] as [String: Any]
        }
        return out
    }

    private static func pacingPayload(_ pacing: PacingStats) -> [String: Any] {
        [
            "shotCount": pacing.shotCount,
            "averageShotSeconds": r2ref(pacing.averageShotSeconds),
            "medianShotSeconds": r2ref(pacing.medianShotSeconds),
            "sectionAverageShotSeconds": pacing.sectionAverageShotSeconds.map { r2ref($0) },
        ]
    }

    private static func okJSON(_ out: [String: Any]) throws -> ToolResult {
        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }

    private static func r2ref(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.2f", value))
    }
}
