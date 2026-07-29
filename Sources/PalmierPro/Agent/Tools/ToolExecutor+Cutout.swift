import Foundation

fileprivate struct CutoutSubjectInput: DecodableToolArgs {
    let clipIds: [String]
    let quality: String?
    let feather: Double?
    let expand: Double?
    let keep: String?
    let background: Background?
    let remove: Bool?
    static let allowedKeys: Set<String> = ["clipIds", "quality", "feather", "expand", "keep", "background", "remove"]

    struct Background: DecodableToolArgs {
        let mediaRef: String?
        let colorHex: String?
        static let allowedKeys: Set<String> = ["mediaRef", "colorHex"]
    }
}

extension ToolExecutor {

    // MARK: cutout_subject

    private static let cutoutQualities: [String: Double] = ["fast": 0, "balanced": 1, "subject": 2]

    func cutoutSubject(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        if let raw = args["background"] {
            guard let dict = raw as? [String: Any] else {
                throw ToolError("cutout_subject.background: expected an object {mediaRef} or {colorHex}")
            }
            try validateUnknownKeys(dict, allowed: CutoutSubjectInput.Background.allowedKeys, path: "cutout_subject.background")
        }
        let input: CutoutSubjectInput = try decodeToolArgs(args, path: "cutout_subject")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }

        if input.remove == true {
            let snapshot = timelineSnapshot(editor)
            let touched = input.clipIds.filter { editor.clipFor(id: $0)?.effects?.contains { $0.type == "key.subject" } == true }
            guard !touched.isEmpty else {
                return .ok(Self.jsonString(["status": "noop", "reason": "None of these clips have a subject key."]) ?? "{}")
            }
            editor.undo.perform("Remove Subject Key (Agent)") {
                editor.mutateClips(ids: Set(touched), actionName: "Remove Subject Key (Agent)") { clip in
                    var stack = clip.effects ?? []
                    stack.removeAll { $0.type == "key.subject" }
                    clip.effects = stack.isEmpty ? nil : stack
                }
            }
            return mutationResult(editor, since: snapshot, touched: touched)
        }

        let qualityName = input.quality ?? "balanced"
        guard let quality = Self.cutoutQualities[qualityName] else {
            throw ToolError("quality must be 'fast', 'balanced', or 'subject' (got '\(qualityName)')")
        }
        for (name, value) in [("feather", input.feather), ("expand", input.expand)] {
            guard let value else { continue }
            let range: ClosedRange<Double> = name == "feather" ? 0...1 : -1...1
            guard range.contains(value) else {
                throw ToolError("\(name) must be between \(range.lowerBound) and \(range.upperBound) (got \(value))")
            }
        }
        let keep = input.keep ?? "subject"
        guard keep == "subject" || keep == "background" else {
            throw ToolError("keep must be 'subject' or 'background' (got '\(keep)')")
        }

        var frameRange: (start: Int, end: Int)?
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video || clip.mediaType == .image else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; subject keying needs video or image.")
            }
            frameRange = (min(frameRange?.start ?? clip.startFrame, clip.startFrame),
                          max(frameRange?.end ?? clip.endFrame, clip.endFrame))
        }

        var backgroundAsset: MediaAsset?
        if let background = input.background {
            guard (background.mediaRef == nil) != (background.colorHex == nil) else {
                throw ToolError("background takes exactly one of 'mediaRef' or 'colorHex'.")
            }
            if let mediaRef = background.mediaRef {
                let asset = try asset(mediaRef, editor: editor, label: "Background media")
                guard asset.type == .video || asset.type == .image else {
                    throw ToolError("Background '\(asset.name)' is \(asset.type.rawValue); use video or image media.")
                }
                backgroundAsset = asset
            } else if let hex = background.colorHex {
                guard TextStyle.RGBA(hex: hex) != nil else {
                    throw ToolError("background.colorHex: invalid color '\(hex)'. Expected '#RGB', '#RRGGBB', or '#RRGGBBAA'.")
                }
                guard editor.projectURL != nil else {
                    throw ToolError("A color background needs a saved project — save the project or pass background.mediaRef instead.")
                }
                backgroundAsset = try await editor.createMatte(hex: hex, name: "Background \(hex)")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = "Cut Out Subject (Agent)"
        var backgroundClipIds: [String] = []
        var notes: [String] = []

        editor.undo.perform(actionName) {
            editor.mutateClips(ids: Set(input.clipIds), actionName: actionName) { clip in
                var stack = clip.effects ?? []
                var effect = stack.first { $0.type == "key.subject" }
                    ?? EffectRegistry.descriptor(id: "key.subject")?.makeEffect()
                    ?? Effect(type: "key.subject")
                effect.enabled = true
                effect.params["quality"] = EffectParam(value: quality)
                effect.params["invert"] = EffectParam(value: keep == "background" ? 1 : 0)
                if let feather = input.feather { effect.params["feather"] = EffectParam(value: feather) }
                if let expand = input.expand { effect.params["expand"] = EffectParam(value: expand) }
                stack.removeAll { $0.type == "key.subject" }
                stack.insert(effect, at: EffectRegistry.insertIndex(stack, for: "key.subject"))
                clip.effects = stack
            }

            guard let backgroundAsset, let frameRange else { return }
            let lowest = editor.timeline.tracks.lastIndex { $0.type == .video } ?? 0
            let trackIndex = editor.insertTrack(at: lowest + 1, type: .video)
            backgroundClipIds = editor.placeClip(
                asset: backgroundAsset,
                trackIndex: trackIndex,
                startFrame: frameRange.start,
                durationFrames: frameRange.end - frameRange.start,
                addLinkedAudio: false
            )
        }

        if backgroundAsset != nil, backgroundClipIds.isEmpty {
            notes.append("The subject key was applied, but the background clip could not be placed — add it with add_clips on a track below.")
        }
        if quality == 2 {
            notes.append("quality 'subject' runs the heavy segmentation model per frame; playback will be slow. Use 'fast' or 'balanced' while editing.")
        }
        notes.append("Frames where nothing is detected stay untouched rather than going transparent.")

        var extra: [String: Any] = [:]
        if !backgroundClipIds.isEmpty { extra["backgroundClipIds"] = backgroundClipIds }
        return mutationResult(
            editor,
            since: snapshot,
            touched: input.clipIds + backgroundClipIds,
            extra: extra,
            notes: notes
        )
    }
}
