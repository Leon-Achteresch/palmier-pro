import Foundation

// manage_motion_scene: author React + Motion scenes that render into the timeline as alpha video.
extension ToolExecutor {

    private static let motionSceneAllowedKeys: Set<String> = [
        "action", "mediaRef", "name", "folderId", "source", "width", "height", "fps", "durationInFrames",
        "runtime",
    ]

    func manageMotionScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        if let unknown = args.keys.first(where: { !Self.motionSceneAllowedKeys.contains($0) }) {
            throw ToolError("Unknown parameter '\(unknown)'. Allowed: \(Self.motionSceneAllowedKeys.sorted().joined(separator: ", "))")
        }
        let action = try args.requireString("action")
        if action == "components" { return .ok(try await Self.componentCatalog()) }

        guard editor.projectURL != nil else {
            throw ToolError("No project is open; cannot author a motion scene")
        }
        switch action {
        case "create": return try await createMotionScene(editor, args)
        case "update": return try await updateMotionScene(editor, args)
        default: throw ToolError("Unknown action '\(action)'. Use 'create', 'update' or 'components'.")
        }
    }

    /// The prebuilt component library the web runtime ships, as module path to exported components.
    private static func componentCatalog() async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let url = BundledResource.url("MotionRuntime/components.json"),
                  let catalog = try? String(contentsOf: url, encoding: .utf8)
            else {
                throw ToolError("The motion component catalog is missing from this build")
            }
            return catalog
        }.value
    }

    // MARK: - Create

    private func createMotionScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let source = try args.requireString("source")
        let name = args.string("name") ?? "Motion Scene"
        let fps = args.double("fps") ?? Double(editor.timeline.fps)
        let scene = try Self.makeScene(
            source: source,
            width: args.int("width") ?? editor.timeline.width,
            height: args.int("height") ?? editor.timeline.height,
            fps: fps,
            durationInFrames: args.int("durationInFrames") ?? Int((fps * 5).rounded()),
            runtime: try Self.runtime(from: args) ?? .web
        )

        let committedURL = try await stageRenderAndCommit(editor, scene: scene, filename: Self.filename(for: name))
        let asset = editor.undo.perform("Add Motion Scene (Agent)") {
            let asset = editor.addMediaAsset(from: committedURL, type: .motion, finalize: false)
            asset.name = name
            if let folderId = args.string("folderId") {
                editor.moveAssetsToFolder(assetIds: [asset.id], folderId: folderId)
            }
            return asset
        }
        guard await editor.finalizeImportedAsset(asset) else {
            throw ToolError("Motion scene rendered but could not be registered")
        }
        editor.onProjectCheckpointRequired?()
        return .ok(Self.receipt(mediaRef: asset.id, name: asset.name, scene: scene, created: true))
    }

    // MARK: - Update

    private func updateMotionScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        guard let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
            throw ToolError("Unknown mediaRef '\(mediaRef)'")
        }
        guard asset.type == .motion else {
            throw ToolError("mediaRef '\(mediaRef)' is a \(asset.type.rawValue) asset, not a motion scene")
        }
        let existing = try await Self.readScene(at: asset.url)
        let updated = try Self.makeScene(
            source: args.string("source") ?? existing.source,
            width: args.int("width") ?? existing.width,
            height: args.int("height") ?? existing.height,
            fps: args.double("fps") ?? existing.fps,
            durationInFrames: args.int("durationInFrames") ?? existing.durationInFrames,
            runtime: try Self.runtime(from: args) ?? existing.runtime
        )
        guard updated != existing else {
            return .ok(Self.receipt(mediaRef: asset.id, name: asset.name, scene: existing, created: false, unchanged: true))
        }

        // Same filename, so the package keeps one file per scene and the install stays atomic.
        _ = try await stageRenderAndCommit(editor, scene: updated, filename: asset.url.lastPathComponent)
        if let name = args.string("name") { asset.name = name }
        guard await editor.finalizeImportedAsset(asset) else {
            throw ToolError("Motion scene rendered but its metadata could not be re-read")
        }
        editor.timelineRenderRevision &+= 1
        editor.videoEngine?.rebuild()
        editor.onProjectCheckpointRequired?()
        return .ok(Self.receipt(mediaRef: asset.id, name: asset.name, scene: updated, created: false))
    }

    // MARK: - Shared

    /// Renders before committing, so a scene that throws never lands in the project as a blank clip.
    private func stageRenderAndCommit(
        _ editor: EditorViewModel,
        scene: MotionScene,
        filename: String
    ) async throws -> URL {
        let data = try scene.encoded()
        let stagedURL = try await Task.detached(priority: .userInitiated) {
            try FileIO.stageData(data, pathExtension: MotionScene.fileExtension)
        }.value
        var committed = false
        defer {
            if !committed {
                let url = stagedURL
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
            }
        }

        do {
            _ = try await MotionVideoGenerator.motionVideo(for: stagedURL, mediaRef: "preflight")
        } catch is CancellationError {
            throw ToolError("Motion scene render was cancelled")
        } catch {
            throw ToolError("Motion scene failed to render: \(error.localizedDescription)")
        }

        let url = try await editor.commitStagedProjectMedia(stagedURL, filename: filename)
        committed = true
        return url
    }

    private static func runtime(from args: [String: Any]) throws -> MotionSceneRuntime? {
        guard let raw = args.string("runtime") else { return nil }
        guard let runtime = MotionSceneRuntime(rawValue: raw) else {
            throw ToolError(
                "Unknown runtime '\(raw)'. Use \(MotionSceneRuntime.allCases.map(\.rawValue).joined(separator: " or "))."
            )
        }
        return runtime
    }

    private static func makeScene(
        source: String,
        width: Int,
        height: Int,
        fps: Double,
        durationInFrames: Int,
        runtime: MotionSceneRuntime
    ) throws -> MotionScene {
        do {
            return try MotionScene(
                width: width,
                height: height,
                fps: fps,
                durationInFrames: durationInFrames,
                source: source,
                runtime: runtime
            ).validated()
        } catch {
            throw ToolError(error.localizedDescription)
        }
    }

    private static func readScene(at url: URL) async throws -> MotionScene {
        do {
            return try await MotionVideoGenerator.loadScene(at: url)
        } catch {
            throw ToolError("Could not read the existing scene: \(error.localizedDescription)")
        }
    }

    private static func filename(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.filter { allowed.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let base = slug.isEmpty ? "scene" : String(slug.prefix(48))
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased()).\(MotionScene.fileExtension)"
    }

    private static func receipt(
        mediaRef: String,
        name: String,
        scene: MotionScene,
        created: Bool,
        unchanged: Bool = false
    ) -> String {
        var payload: [String: Any] = [
            "mediaRef": mediaRef,
            "name": name,
            "type": ClipType.motion.rawValue,
            "width": scene.width,
            "height": scene.height,
            "fps": scene.fps,
            "durationInFrames": scene.durationInFrames,
            "durationSeconds": scene.duration.jsonRounded(toPlaces: 3),
            "status": unchanged ? "unchanged" : "ready",
        ]
        if unchanged {
            payload["note"] = "No field differed from the stored scene; nothing was re-rendered."
        } else if created {
            payload["note"] = "Rendered and added to the media library. Place it with add_clips using this mediaRef."
        } else {
            payload["note"] = "Re-rendered in place; existing clips on the timeline now show the new version."
        }
        return jsonString(payload) ?? "{}"
    }
}
