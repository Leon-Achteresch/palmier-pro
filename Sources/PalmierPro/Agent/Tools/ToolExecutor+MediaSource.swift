import Foundation

fileprivate struct RelinkMediaInput: DecodableToolArgs {
    let mediaRef: String?
    let filePath: String?
    let searchFolder: String?
    static let allowedKeys: Set<String> = ["mediaRef", "filePath", "searchFolder"]
}

extension ToolExecutor {

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
