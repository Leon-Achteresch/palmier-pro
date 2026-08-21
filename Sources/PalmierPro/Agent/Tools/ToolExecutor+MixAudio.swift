import Foundation

extension ToolExecutor {
    private static let mixAudioAllowedKeys: Set<String> = [
        "platform", "dryRun", "ducking", "duckDepthDb",
    ]

    private struct MixClipSignature: Equatable {
        let mediaRef: String
        let startFrame: Int
        let durationFrames: Int
        let trimStartFrame: Int
        let trimEndFrame: Int
        let speed: Double
        let volume: Double
        let duckingRole: DuckingRole

        init(_ clip: Clip) {
            mediaRef = clip.mediaRef
            startFrame = clip.startFrame
            durationFrames = clip.durationFrames
            trimStartFrame = clip.trimStartFrame
            trimEndFrame = clip.trimEndFrame
            speed = clip.speed
            volume = clip.volume
            duckingRole = clip.duckingRole
        }
    }

    private struct MixEntry {
        let clipId: String
        let trackIndex: Int
        let role: AudioClipRole?
        let roleSource: String
        let speechCoverage: Double?
        var measuredLufs: Double?
        var truePeakDbtp: Double?
        var targetLufs: Double?
        var currentVolumeDb: Double
        var newVolumeDb: Double?
        var skipReason: String?
        var clamped = false
    }

    func mixAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.mixAudioAllowedKeys, path: "mix_audio")
        let platformRaw = args.string("platform") ?? MixPlatformPreset.youtube.rawValue
        guard let platform = MixPlatformPreset(rawValue: platformRaw) else {
            throw ToolError(
                "invalid platform '\(platformRaw)'. Valid: "
                    + MixPlatformPreset.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        let dryRun = try Self.mixFlag(args["dryRun"], name: "mix_audio.dryRun") ?? false
        let enableDucking = try Self.mixFlag(args["ducking"], name: "mix_audio.ducking") ?? true
        var duckDepthDb = DuckingLimits.depthDbDefault
        if args["duckDepthDb"] != nil {
            guard let value = args.double("duckDepthDb"), value.isFinite,
                  DuckingLimits.depthDb.contains(value) else {
                throw ToolError(
                    "mix_audio.duckDepthDb must be between \(DuckingLimits.depthDb.lowerBound) and "
                        + "\(DuckingLimits.depthDb.upperBound) dB"
                )
            }
            guard enableDucking else {
                throw ToolError("mix_audio.duckDepthDb applies only when ducking is on — drop ducking:false or the depth")
            }
            duckDepthDb = value
        }

        let timelineId = editor.timeline.id
        let fps = editor.timeline.fps
        guard fps > 0 else { throw ToolError("The active timeline has no valid frame rate.") }
        let targets = DuckingAnalyzer.mixableClips(in: editor.timeline)
        guard !targets.isEmpty else {
            throw ToolError(
                "No audio clips to mix on the active timeline. A video clip's sound is a linked audio clip — "
                    + "check get_timeline for audio tracks, and unmute any muted ones."
            )
        }
        let signatures = Dictionary(uniqueKeysWithValues: targets.map { ($0.clip.id, MixClipSignature($0.clip)) })

        var warnings: [String] = []
        let spans = await speechSpans(editor, clips: targets.map(\.clip), warnings: &warnings)
        let analysis = DuckingAnalyzer.analyze(timeline: editor.timeline, spansByMediaRef: spans)

        var entries: [MixEntry] = []
        for (trackIndex, clip) in targets {
            let role = analysis.rolesByClipId[clip.id]
            var entry = MixEntry(
                clipId: clip.id,
                trackIndex: trackIndex,
                role: role,
                roleSource: clip.duckingRole == .auto ? "auto" : "explicit",
                speechCoverage: analysis.coverageByClipId[clip.id],
                currentVolumeDb: VolumeScale.dbFromLinear(clip.volume)
            )
            if role == nil {
                entry.skipReason = "unclassified — no on-device speech analysis for this media; set duckingRole to place it"
                entries.append(entry)
                continue
            }
            if role == .exempt {
                entry.skipReason = "duckingRole 'exempt' — left untouched"
                entries.append(entry)
                continue
            }
            if clip.volumeTrack?.isActive == true {
                entry.skipReason = "volume is keyframed — re-levelling would discard the automation"
                entries.append(entry)
                continue
            }
            entries.append(entry)
        }

        guard entries.contains(where: { $0.skipReason == nil }) else {
            throw ToolError(
                "Nothing to mix: no audio clip could be classified. On-device speech analysis is unavailable or "
                    + "still running — set duckingRole ('dialog', 'bed', 'exempt') with set_clip_properties and retry."
            )
        }

        let beforeLufs = try await programLoudness(editor)
        for index in entries.indices where entries[index].skipReason == nil {
            try Self.checkMixCancellation()
            guard let clip = editor.clipFor(id: entries[index].clipId) else {
                entries[index].skipReason = "clip disappeared during analysis"
                continue
            }
            do {
                let measurement = try await TimelineLoudness.measure(
                    clip: clip,
                    timeline: editor.timeline,
                    resolver: editor.mediaResolver,
                    resolveTimeline: editor.timelineResolver(),
                    missingMediaRefs: editor.missingMediaRefs
                )
                entries[index].measuredLufs = measurement.integratedLufs
                entries[index].truePeakDbtp = measurement.truePeakDbtp
            } catch is CancellationError {
                throw ToolError("mix_audio was cancelled before it finished. Nothing was changed.")
            } catch {
                entries[index].skipReason = "loudness measurement failed: \(error.localizedDescription)"
            }
        }

        for index in entries.indices where entries[index].skipReason == nil {
            guard let role = entries[index].role, let target = platform.targetLufs(for: role) else { continue }
            entries[index].targetLufs = target
            guard let measured = entries[index].measuredLufs else {
                entries[index].skipReason = "silent — every loudness block was gated out"
                continue
            }
            let proposed = entries[index].currentVolumeDb + (target - measured)
            let clamped = min(VolumeScale.ceilingDb, max(VolumeScale.floorDb, proposed))
            entries[index].clamped = abs(clamped - proposed) > 0.05
            entries[index].newVolumeDb = clamped
        }

        for entry in entries {
            guard let new = entry.newVolumeDb else { continue }
            if entry.clamped {
                warnings.append(
                    "\(entry.clipId): needed gain sits outside \(VolumeScale.floorDb)…\(VolumeScale.ceilingDb) dB and was clamped to \(Self.mixRounded(new, places: 1))."
                )
            }
            if let peak = entry.truePeakDbtp, peak + (new - entry.currentVolumeDb) > platform.truePeakCeilingDbtp {
                warnings.append(
                    "\(entry.clipId): true peak would reach \(Self.mixRounded(peak + new - entry.currentVolumeDb, places: 1)) dBTP, past the \(platform.rawValue) ceiling of \(platform.truePeakCeilingDbtp) dBTP — compress or lower peaks instead."
                )
            }
        }
        for entry in entries where entry.skipReason != nil {
            warnings.append("\(entry.clipId): \(entry.skipReason!)")
        }

        var duckingSettings = editor.timeline.ducking.normalized
        if enableDucking {
            duckingSettings.enabled = true
            duckingSettings.depthDb = duckDepthDb
        }
        let hasDialog = entries.contains { $0.role == .dialog }
        let hasBed = entries.contains { $0.role == .bed }
        if enableDucking && !(hasDialog && hasBed) {
            warnings.append(
                "Ducking is on but the timeline has no dialog+bed pair yet, so nothing ducks. Set duckingRole to correct the classification."
            )
        }

        var payload: [String: Any] = [
            "platform": platform.rawValue,
            "programTargetLufs": platform.programLufs,
            "mix": entries.map { Self.mixEntryPayload($0) },
            "ducking": [
                "enabled": duckingSettings.enabled,
                "depthDb": duckingSettings.depthDb,
                "attackMs": duckingSettings.attackMs,
                "releaseMs": duckingSettings.releaseMs,
                "holdMs": duckingSettings.holdMs,
            ],
        ]
        payload["integratedLufs"] = ["before": beforeLufs.map { $0 as Any } ?? NSNull()]
        if !warnings.isEmpty { payload["warnings"] = warnings }

        if dryRun {
            payload["dryRun"] = true
            payload["applied"] = false
            payload["note"] = "Plan only — nothing changed. Call again without dryRun to apply."
            guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 2)) else {
                throw ToolError("Failed to encode result.")
            }
            return .ok(json)
        }

        guard editor.timeline.id == timelineId else {
            throw ToolError("The active timeline changed while mix_audio was analyzing. Nothing was changed — re-run it.")
        }
        for (clipId, signature) in signatures {
            guard let current = editor.clipFor(id: clipId) else {
                throw ToolError("Clip \(clipId) was removed while mix_audio was analyzing. Nothing was changed — re-run it.")
            }
            guard MixClipSignature(current) == signature else {
                throw ToolError("Clip \(clipId) was edited while mix_audio was analyzing. Nothing was changed — re-run it.")
            }
        }

        let planned = entries.filter { entry in
            guard let new = entry.newVolumeDb else { return false }
            return abs(new - entry.currentVolumeDb) >= 0.1
        }
        let duckingChanges = duckingSettings != editor.timeline.ducking
        guard !planned.isEmpty || duckingChanges else {
            payload["applied"] = false
            payload["changed"] = false
            payload["note"] = "Already at the target balance — no clip gain or ducking change was needed."
            guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 2)) else {
                throw ToolError("Failed to encode result.")
            }
            return .ok(json)
        }

        let snapshot = timelineSnapshot(editor)
        editor.undo.perform("Mix Audio (Agent)") {
            for entry in planned {
                guard let new = entry.newVolumeDb else { continue }
                editor.commitClipProperty(clipId: entry.clipId, actionName: "Mix Audio (Agent)") { clip in
                    clip.volume = VolumeScale.linearFromDb(new)
                }
            }
            if duckingChanges {
                editor.updateDuckingSettings(duckingSettings, actionName: "Mix Audio (Agent)")
            }
        }

        var notes: [String] = []
        var afterLufs: Double?
        do {
            afterLufs = try await programLoudness(editor)
        } catch {
            notes.append("The mix was applied, but measuring the new program loudness failed: \(error.localizedDescription)")
        }
        payload["integratedLufs"] = [
            "before": beforeLufs.map { $0 as Any } ?? NSNull(),
            "after": afterLufs.map { $0 as Any } ?? NSNull(),
        ]
        payload["applied"] = true
        payload["clipsChanged"] = planned.count
        if let afterLufs {
            let remaining = platform.programLufs - afterLufs
            payload["programDeltaDb"] = remaining
            if abs(remaining) > 1 {
                notes.append(
                    "The program still sits \(Self.mixRounded(remaining, places: 1)) dB from the \(platform.rawValue) target — that last step is a master move, not a per-clip one."
                )
            }
        }
        return mutationResult(
            editor,
            since: snapshot,
            touched: planned.map(\.clipId),
            extra: payload,
            notes: notes
        )
    }

    // MARK: - Analysis

    private func speechSpans(
        _ editor: EditorViewModel, clips: [Clip], warnings: inout [String]
    ) async -> [String: [VoiceActivity.Span]] {
        let urls = editor.mediaResolver.expectedURLMap()
        let missing = editor.missingMediaRefs
        var out: [String: [VoiceActivity.Span]] = [:]
        var unavailable: [String] = []
        for mediaRef in Set(clips.map(\.mediaRef)).sorted() {
            guard !missing.contains(mediaRef), let url = urls[mediaRef] else {
                unavailable.append(mediaRef)
                continue
            }
            do {
                out[mediaRef] = try await VoiceActivity.analysis(for: url, mediaRef: mediaRef).segments
            } catch is CancellationError {
                unavailable.append(mediaRef)
            } catch {
                unavailable.append(mediaRef)
            }
        }
        if !unavailable.isEmpty {
            warnings.append(
                "Speech analysis unavailable for \(unavailable.count) media file(s); clips using them keep duckingRole 'auto' and were skipped."
            )
        }
        return out
    }

    private func programLoudness(_ editor: EditorViewModel) async throws -> Double? {
        do {
            return try await TimelineLoudness.measure(
                timeline: editor.timeline,
                resolver: editor.mediaResolver,
                resolveTimeline: editor.timelineResolver(),
                missingMediaRefs: editor.missingMediaRefs
            ).integratedLufs
        } catch is CancellationError {
            throw ToolError("mix_audio was cancelled before it finished.")
        } catch is TimelineLoudness.EmptyAudioError {
            return nil
        }
    }

    private static func checkMixCancellation() throws {
        guard !Task.isCancelled else {
            throw ToolError("mix_audio was cancelled before it finished. Nothing was changed.")
        }
    }

    private static func mixEntryPayload(_ entry: MixEntry) -> [String: Any] {
        var out: [String: Any] = [
            "clipId": entry.clipId,
            "track": entry.trackIndex,
            "role": entry.role?.rawValue ?? "unclassified",
            "roleSource": entry.roleSource,
            "currentVolumeDb": entry.currentVolumeDb,
        ]
        if let coverage = entry.speechCoverage { out["speechCoverage"] = coverage }
        if let measured = entry.measuredLufs { out["measuredLufs"] = measured }
        if let peak = entry.truePeakDbtp { out["truePeakDbtp"] = peak }
        if let target = entry.targetLufs { out["targetLufs"] = target }
        if let new = entry.newVolumeDb {
            out["newVolumeDb"] = new
            out["gainDb"] = new - entry.currentVolumeDb
        }
        if let reason = entry.skipReason {
            out["skipped"] = true
            out["skipReason"] = reason
        }
        return out
    }

    private static func mixRounded(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func mixFlag(_ raw: Any?, name: String) throws -> Bool? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard isJSONBoolean(raw), let value = (raw as? NSNumber)?.boolValue ?? (raw as? Bool) else {
            throw ToolError("\(name) must be true or false")
        }
        return value
    }
}
