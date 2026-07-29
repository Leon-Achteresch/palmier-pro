import Foundation

fileprivate struct SwapClipMediaInput: DecodableToolArgs {
    let clipIds: [String]
    let mediaRef: String
    let resetTrim: Bool?
    static let allowedKeys: Set<String> = ["clipIds", "mediaRef", "resetTrim"]
}

fileprivate struct RelinkMediaInput: DecodableToolArgs {
    let mediaRef: String?
    let filePath: String?
    let searchFolder: String?
    static let allowedKeys: Set<String> = ["mediaRef", "filePath", "searchFolder"]
}

extension ToolExecutor {

    // MARK: swap_clip_media

    func swapClipMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SwapClipMediaInput = try decodeToolArgs(args, path: "swap_clip_media")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        let asset = try asset(input.mediaRef, editor: editor, label: "Replacement media")

        var targets: [String] = []
        var notes: [String] = []
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == asset.type else {
                throw ToolError("Clip \(id) is \(clip.mediaType.rawValue); '\(asset.name)' is \(asset.type.rawValue). Swap like for like.")
            }
            guard clip.mediaRef != input.mediaRef else {
                notes.append("Skipped \(id) — it already uses this media.")
                continue
            }
            targets.append(id)
        }
        guard !targets.isEmpty else {
            return .ok(Self.jsonString(["status": "noop", "reason": "Every clip already uses \(input.mediaRef)."]) ?? "{}")
        }

        let resetTrim = input.resetTrim ?? false
        let sourceFrames = secondsToFrame(seconds: asset.duration, fps: editor.timeline.fps)
        if !resetTrim, sourceFrames > 0 {
            for id in targets {
                guard let clip = editor.clipFor(id: id), clip.sourceDurationFrames > sourceFrames else { continue }
                notes.append("Clip \(id) references \(clip.sourceDurationFrames) source frames but '\(asset.name)' has \(sourceFrames) — the tail will read as frozen or empty. Pass resetTrim:true or retrim it.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        editor.undo.perform("Swap Clip Media (Agent)") {
            for id in targets {
                editor.replaceClipMediaRef(clipId: id, newAssetId: input.mediaRef, resetTrim: resetTrim)
            }
        }
        return mutationResult(editor, since: snapshot, touched: targets, notes: notes)
    }

    // MARK: relink_media

    func relinkMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: RelinkMediaInput = try decodeToolArgs(args, path: "relink_media")
        let hasSingle = input.mediaRef != nil || input.filePath != nil
        guard hasSingle != (input.searchFolder == nil) else {
            throw ToolError("Provide either 'mediaRef'+'filePath' (one asset) or 'searchFolder' (match every offline asset by filename).")
        }

        if let folderPath = input.searchFolder {
            let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
            let offline = editor.mediaAssets.filter { editor.isMediaOffline($0.id) }
            guard !offline.isEmpty else {
                return .ok(Self.jsonString(["status": "noop", "reason": "No offline media in this project."]) ?? "{}")
            }
            let result = editor.relinkOfflineAssets(fromFolder: folder)
            let stillOffline = editor.mediaAssets.filter { editor.isMediaOffline($0.id) }.map(\.id).sorted()
            return .ok(Self.jsonString([
                "status": result.relinked > 0 ? "ok" : "noop",
                "relinked": result.relinked,
                "offlineBefore": result.total,
                "stillOffline": stillOffline,
            ]) ?? "{}")
        }

        guard let mediaRef = input.mediaRef, let filePath = input.filePath else {
            throw ToolError("Relinking one asset needs both 'mediaRef' and 'filePath'.")
        }
        let asset = try asset(mediaRef, editor: editor)
        let url = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        if let newType = ClipType(fileExtension: url.pathExtension.lowercased()), newType != asset.type {
            throw ToolError("'\(url.lastPathComponent)' is \(newType.rawValue) media; asset \(mediaRef) is \(asset.type.rawValue).")
        }
        editor.relinkAsset(id: mediaRef, to: url)
        guard editor.mediaAssets.first(where: { $0.id == mediaRef })?.url == url else {
            throw ToolError("Relink refused for \(mediaRef) — check the path and the media type.")
        }
        return .ok(Self.jsonString([
            "status": "ok",
            "mediaRef": mediaRef,
            "path": url.path,
            "note": "Relinking is not undoable; it repoints the asset for the whole project.",
        ]) ?? "{}")
    }
}
