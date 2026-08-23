import Foundation

fileprivate struct AssembleMontageInput: DecodableToolArgs {
    let mediaRefs: [String]
    let musicRef: String
    let trackIndex: Int?
    let startFrame: Int?
    let grid: String?
    let energy: String?
    let maxHoldBeats: Int?
    let bookend: Bool?
    static let allowedKeys: Set<String> = [
        "mediaRefs", "musicRef", "trackIndex", "startFrame", "grid", "energy", "maxHoldBeats", "bookend",
    ]
}

extension ToolExecutor {

    func assembleMontage(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: AssembleMontageInput = try decodeToolArgs(args, path: "assemble_montage")
        guard input.mediaRefs.count >= 2 else {
            throw ToolError("assemble_montage needs at least two mediaRefs — that is what makes it a montage.")
        }
        let startFrame = input.startFrame ?? 0
        guard startFrame >= 0 else { throw ToolError("startFrame must be >= 0 (got \(startFrame))") }

        let useDownbeats: Bool
        switch input.grid ?? "beat" {
        case "beat": useDownbeats = false
        case "downbeat": useDownbeats = true
        default: throw ToolError("grid must be 'beat' or 'downbeat' (got '\(input.grid ?? "")')")
        }
        guard let energy = MontagePlanner.Energy(rawValue: input.energy ?? "flat") else {
            throw ToolError("energy must be one of \(MontagePlanner.Energy.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(input.energy ?? "")')")
        }
        let maxHoldBeats = input.maxHoldBeats ?? 4
        guard (1...16).contains(maxHoldBeats) else {
            throw ToolError("maxHoldBeats must be 1–16 (got \(maxHoldBeats))")
        }

        let music = try asset(input.musicRef, editor: editor, label: "Music asset")
        guard music.type == .audio || (music.type == .video && music.hasAudio) else {
            throw ToolError("musicRef needs audio: \(input.musicRef) is \(music.type.rawValue) with no audio track.")
        }
        guard FileManager.default.fileExists(atPath: music.url.path) else {
            throw ToolError("Music file not on disk: \(music.url.lastPathComponent)")
        }

        var refs = input.mediaRefs
        if input.bookend == true { refs.append(refs[0]) }
        var assets: [MediaAsset] = []
        for (idx, ref) in refs.enumerated() {
            let a = try asset(ref, editor: editor, label: "mediaRefs[\(idx)]")
            guard a.type != .audio else {
                throw ToolError("mediaRefs[\(idx)]: \(ref) is audio — montage shots must be video or image. Pass the music as musicRef.")
            }
            assets.append(a)
        }

        var targetTrackId: String? = nil
        if let ti = input.trackIndex {
            guard editor.timeline.tracks.indices.contains(ti) else {
                throw ToolError("trackIndex \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
            }
            guard editor.timeline.tracks[ti].type == .video else {
                throw ToolError("trackIndex \(ti) is a \(editor.timeline.tracks[ti].type.rawValue) track; the montage needs a video track.")
            }
            targetTrackId = editor.timeline.tracks[ti].id
        }

        let analysis = try await editor.mediaVisualCache.beats.detect(for: music).value
        let beatSeconds = useDownbeats ? analysis.downbeats : analysis.beats
        guard !beatSeconds.isEmpty else {
            let other = useDownbeats ? analysis.beats : analysis.downbeats
            throw ToolError(
                other.isEmpty
                    ? "No beats found in \(input.musicRef) — the audio may lack rhythmic content. Pick a music bed with a clear pulse."
                    : "No \(useDownbeats ? "downbeats" : "beats") found in \(input.musicRef), but the track does have \(useDownbeats ? "beats" : "downbeats") — switch grid."
            )
        }

        let fps = editor.timeline.fps
        let gridFrames = MontagePlanner.gridFrames(
            beatSeconds: beatSeconds, musicStartFrame: startFrame, fps: fps
        )
        let plan: MontagePlanner.Plan
        do {
            plan = try MontagePlanner.plan(MontagePlanner.Request(
                shotCount: assets.count,
                startFrame: startFrame,
                gridFrames: gridFrames,
                energy: energy,
                maxHoldSteps: maxHoldBeats,
                availableFrames: assets.map { $0.type == .image ? nil : Self.sourceFrames($0, fps: fps) }
            ))
        } catch MontagePlanner.PlanError.gridTooShort, MontagePlanner.PlanError.gridEndsBeforeStart {
            throw ToolError("The music has fewer than two \(useDownbeats ? "downbeats" : "beats") at or after frame \(startFrame) — nothing to cut to.")
        }
        guard !plan.shots.isEmpty else {
            throw ToolError("No shot fits the grid: every source is shorter than one \(useDownbeats ? "bar" : "beat").")
        }

        let musicFrames = max(1, Self.sourceFrames(music, fps: fps))
        let snapshot = timelineSnapshot(editor)
        let actionName = "Assemble Montage (Agent)"
        var placedShotIds: [String] = []
        var musicClipId: String?

        try editor.undo.perform(actionName) {
            var addedIds: [String] = []
            var createdTrackIds: [String] = []

            let videoTrackId: String
            if let targetTrackId {
                videoTrackId = targetTrackId
            } else {
                let index = editor.insertTrack(at: 0, type: .video)
                guard editor.timeline.tracks.indices.contains(index) else {
                    throw ToolError("Failed to create a video track for the montage")
                }
                videoTrackId = editor.timeline.tracks[index].id
                createdTrackIds.append(videoTrackId)
            }
            let audioIndex = editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
            guard editor.timeline.tracks.indices.contains(audioIndex) else {
                throw ToolError("Failed to create an audio track for the music bed")
            }
            let audioTrackId = editor.timeline.tracks[audioIndex].id
            createdTrackIds.append(audioTrackId)

            @MainActor func trackIndex(_ id: String) throws -> Int {
                guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == id }) else {
                    throw ToolError("Destination track no longer exists")
                }
                return index
            }

            for shot in plan.shots {
                let index = try trackIndex(videoTrackId)
                editor.clearRegion(trackIndex: index, start: shot.startFrame,
                                   end: shot.endFrame, prune: false)
                // The bed carries the montage; a shot's own sound would fight it.
                let ids = editor.placeClip(
                    asset: assets[shot.index], trackIndex: index,
                    startFrame: shot.startFrame, durationFrames: shot.durationFrames,
                    addLinkedAudio: false, trimStartFrame: 0
                )
                guard let id = ids.first else {
                    throw ToolError("Failed to place shot \(shot.index) at frame \(shot.startFrame)")
                }
                placedShotIds.append(id)
                addedIds.append(contentsOf: ids)
            }

            let bedFrames = min(musicFrames, max(1, plan.endFrame - startFrame))
            let musicIds = editor.placeClip(
                asset: music, trackIndex: try trackIndex(audioTrackId),
                startFrame: startFrame, durationFrames: bedFrames,
                addLinkedAudio: false, trimStartFrame: 0
            )
            guard let bedId = musicIds.first else {
                throw ToolError("Failed to place the music bed")
            }
            musicClipId = bedId
            addedIds.append(contentsOf: musicIds)

            let finalIds = addedIds
            let tracksToRemove = createdTrackIds
            editor.registerTimelineUndo(actionName) { vm in
                vm.removeClips(ids: Set(finalIds))
                for id in tracksToRemove { vm.removeTrack(id: id) }
            }
        }
        editor.notifyTimelineChanged()

        var notes: [String] = []
        if !plan.skipped.isEmpty {
            notes.append("Skipped \(plan.skipped.count) shot\(plan.skipped.count == 1 ? "" : "s") that could not fill one \(useDownbeats ? "bar" : "beat") or ran past the music: \(plan.skipped.map { refs[$0] }.joined(separator: ", ")).")
        }
        if !plan.shortened.isEmpty {
            notes.append("Held \(plan.shortened.count) shot\(plan.shortened.count == 1 ? "" : "s") for fewer \(useDownbeats ? "bars" : "beats") than the energy curve asked, because the source ran out: \(plan.shortened.map { refs[$0] }.joined(separator: ", ")).")
        }
        if musicFrames < plan.endFrame - startFrame {
            notes.append("The music is shorter than the cut — the bed ends at frame \(startFrame + musicFrames) while the picture runs to \(plan.endFrame).")
        }

        var extra: [String: Any] = [
            "shots": plan.shots.enumerated().map { position, shot -> [String: Any] in
                [
                    "clipId": placedShotIds.indices.contains(position) ? placedShotIds[position] : "",
                    "mediaRef": refs[shot.index],
                    "startFrame": shot.startFrame,
                    "endFrame": shot.endFrame,
                ]
            },
            "cutFrames": plan.shots.map(\.startFrame),
            "grid": useDownbeats ? "downbeat" : "beat",
            "energy": energy.rawValue,
            "endFrame": plan.endFrame,
        ]
        if let musicClipId { extra["musicClipId"] = musicClipId }
        if analysis.bpm > 0 {
            extra["bpm"] = NSDecimalNumber(string: String(format: "%.1f", analysis.bpm))
        }
        return mutationResult(editor, since: snapshot, touched: placedShotIds, extra: extra, notes: notes)
    }

    private static func sourceFrames(_ asset: MediaAsset, fps: Int) -> Int {
        max(0, Int((asset.duration * Double(fps)).rounded(.down)))
    }
}
