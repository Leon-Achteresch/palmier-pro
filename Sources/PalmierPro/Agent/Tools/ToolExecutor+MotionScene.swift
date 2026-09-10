import CryptoKit
import Foundation

extension ToolExecutor {
    func motionArguments(_ arguments: [String: Any], editor: EditorViewModel) throws -> [String: Any] {
        var result = arguments
        if let ref = arguments["mediaRef"] { result["mediaRef"] = try expandingIdPrefixes(in: ["mediaRef": ref], editor: editor)["mediaRef"] }
        if let cues = arguments["soundCues"] as? [[String: Any]] {
            result["soundCues"] = try cues.map { cue in
                var copy = cue
                if let ref = cue["mediaRef"] { copy["mediaRef"] = try expandingIdPrefixes(in: ["mediaRef": ref], editor: editor)["mediaRef"] }
                return copy
            }
        }
        return result
    }
    func manageMotionScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input = try MotionToolInput(args)
        let action = try input.string("action")
        switch action {
        case "components": return try await motionComponents(editor, input)
        case "create":
            try input.only(["name", "width", "height", "fps", "durationInFrames", "runtime", "layers", "requestId"])
            let fps = try input.number("fps", default: Double(editor.timeline.fps))
            guard MotionScene.fpsRange.contains(fps) else { throw ToolError("fps must be within 1–120") }
            var scene = MotionScene(width: try input.integer("width", default: editor.timeline.width),
                height: try input.integer("height", default: editor.timeline.height), fps: fps,
                durationInFrames: try input.integer("durationInFrames", default: Int((fps * 5).rounded())),
                runtime: try input.runtime())
            scene.nodes = try input.layers(duration: scene.durationInFrames)
            let receipt = try await editor.motionScenes.create(scene, name: try input.string("name", default: "Motion Scene"),
                editor: editor, requestID: input.requestID, requestFingerprint: input.fingerprint)
            return .ok(try await Self.motionJSON(receipt))
        case "read", "import", "compose", "animate", "content", "arrange", "configure", "render": break
        default: throw ToolError("Unknown motion action '\(action)'")
        }
        let mediaRef = try input.string("mediaRef")
        let snapshot = try await editor.motionScenes.load(mediaRef: mediaRef, editor: editor)
        let scene = snapshot.scene
        if action == "read" {
            try input.only(["mediaRef", "targets"])
            let ids = try input.targets(required: false)
            return .ok(try await Self.motionRead(snapshot, mediaRef: mediaRef, ids: ids))
        }
        if action == "render" {
            try input.only(["mediaRef", "expectedRevision"])
            guard try input.string("expectedRevision") == snapshot.revision else { throw ToolError("Scene revision conflict; read the scene and retry") }
            let url = try await MotionVideoGenerator.motionVideo(for: snapshot.url, mediaRef: mediaRef)
            try Task.checkCancellation()
            guard editor.motionScenes.snapshot(for: mediaRef)?.revision == snapshot.revision,
                  editor.mediaAssetsById[mediaRef]?.url == snapshot.url else { throw ToolError("Scene changed during rendering; render the current revision") }
            struct RenderReceipt: Encodable, Sendable { var mediaRef: String; var revision: String; var status: String; var path: String }
            return .ok(try await Self.motionJSON(RenderReceipt(mediaRef: mediaRef, revision: snapshot.revision, status: "ready", path: url.path)))
        }
        let expected = try input.string("expectedRevision")
        if let replay = try editor.motionScenes.replayReceipt(input.requestID, fingerprint: input.fingerprint) {
            return .ok(try await Self.motionJSON(replay))
        }
        guard expected == snapshot.revision else { throw ToolError("Scene revision conflict; read the scene and retry") }
        let operations: [MotionSceneOperation]
        let actionName: String
        switch action {
        case "import":
            try input.only(["mediaRef", "expectedRevision", "requestId", "path", "exportName"])
            let path = try input.string("path")
            let url = URL(fileURLWithPath: path, relativeTo: editor.linkedContextPath.map { URL(fileURLWithPath: $0, isDirectory: true) })
            let result = try await MotionComponentCompiler.shared.compile(at: url, exportName: try input.string("exportName", default: "default"), runtime: scene.runtime)
            guard result.runtime == scene.runtime else { throw ToolError("Component runtime does not match scene runtime") }
            operations = [.component(result.component)]
            actionName = "Import Motion Component"
        case "compose":
            try input.only(["mediaRef", "expectedRevision", "requestId", "layers"])
            let nodes = try input.layers(duration: scene.durationInFrames)
            guard !nodes.isEmpty else { throw ToolError("Compose requires at least one layer") }
            operations = [.add(nodes)]
            actionName = "Compose Motion Scene"
        case "content":
            try input.only(["mediaRef", "expectedRevision", "requestId", "targets", "values", "fixture", "frame"])
            let ids = try input.targets()
            let frame = try input.optionalInteger("frame")
            if input.has("fixture") {
                guard !input.has("values") else { throw ToolError("Provide fixture or values, not both") }
                let name = try input.string("fixture")
                if let frame {
                    operations = try ids.map { id in
                        guard let node = scene.nodes.first(where: { $0.id == id }),
                              let fixture = scene.components.first(where: { $0.id == node.componentID })?.fixtures[name] else {
                            throw ToolError("Unknown layer or fixture '\(name)'")
                        }
                        return .values(ids: [id], values: Dictionary(uniqueKeysWithValues: fixture.map { ("props." + $0.key, $0.value) }), frame: frame)
                    }
                } else { operations = [.fixture(ids: ids, name: name)] }
            } else { operations = [.values(ids: ids, values: try input.values("values"), frame: frame)] }
            actionName = "Change Motion Content"
        case "animate":
            try input.only(["mediaRef", "expectedRevision", "requestId", "targets", "recipe", "startFrame", "durationFrames", "amount", "staggerFrames",
                            "repeatCount", "mirror", "gapFrames", "easing", "tracks", "removeBindings", "removeRecipeIds", "expandRecipeId"])
            let ids = try input.targets()
            if input.has("expandRecipeId") {
                guard ids.count == 1, !input.has("recipe"), !input.has("tracks") else { throw ToolError("Expand one recipe on one layer per call") }
                operations = try await MotionRecipeOperations.expand(scene: scene, nodeID: ids[0], recipeID: input.string("expandRecipeId"))
            } else {
                var changes: [MotionSceneOperation] = []
                if input.has("recipe") {
                    guard let kind = MotionRecipe.Kind(rawValue: try input.string("recipe")) else { throw ToolError("Unknown animation recipe") }
                    let recipe = MotionRecipe(kind: kind, startFrame: try input.integer("startFrame", default: 0),
                        durationFrames: try input.integer("durationFrames", default: 18), amount: try input.number("amount", default: 40),
                        repeatCount: try input.integer("repeatCount", default: 1), mirror: try input.boolean("mirror", default: false),
                        gapFrames: try input.integer("gapFrames", default: 0), easing: try input.easing())
                    changes.append(.recipe(ids: ids, recipe: recipe, stagger: try input.integer("staggerFrames", default: 0)))
                }
                for id in ids {
                    guard let node = scene.nodes.first(where: { $0.id == id }) else { throw ToolError("Unknown layer '\(id)'") }
                    for var track in try input.tracks() {
                        for index in track.keys.indices { track.keys[index].frame -= node.startFrame }
                        changes.append(.track(id: id, track: track))
                    }
                    for binding in try input.strings("removeBindings") { changes.append(.removeTrack(id: id, binding: binding)) }
                    for recipeID in try input.strings("removeRecipeIds") { changes.append(.removeRecipe(id: id, recipeID: recipeID)) }
                }
                guard !changes.isEmpty else { throw ToolError("Provide a recipe, tracks, or animations to remove") }
                operations = changes
            }
            actionName = "Animate Motion Layers"
        case "arrange":
            try input.only(["mediaRef", "expectedRevision", "requestId", "targets", "arrangement", "dx", "dy", "snap", "autoKey", "frame", "alignment", "name"])
            let ids = try input.targets()
            switch try input.string("arrangement") {
            case "translate": operations = try await MotionLayoutOperations.translate(scene: scene, revision: expected,
                frame: input.integer("frame", default: 0), ids: ids, dx: input.number("dx", default: 0), dy: input.number("dy", default: 0),
                snap: input.boolean("snap", default: false), autoKey: input.boolean("autoKey", default: false))
            case "align":
                guard let alignment = MotionAlignment(rawValue: try input.string("alignment")) else { throw ToolError("Unknown alignment") }
                operations = try await MotionLayoutOperations.align(scene: scene, revision: expected, frame: input.integer("frame", default: 0),
                    ids: ids, alignment: alignment, autoKey: input.boolean("autoKey", default: false))
            case "group": operations = [.group(ids: ids, name: try input.string("name", default: "Group"))]
            case "ungroup": operations = ids.map { .ungroup(id: $0) }
            case "duplicate": operations = [.duplicate(ids: ids)]
            case "delete": operations = [.remove(ids: ids)]
            case "lock": operations = [.lock(ids: ids, locked: true)]
            case "unlock": operations = [.lock(ids: ids, locked: false)]
            case "hide": operations = [.visibility(ids: ids, hidden: true)]
            case "show": operations = [.visibility(ids: ids, hidden: false)]
            case "reorder": operations = [.reorder(ids: ids)]
            default: throw ToolError("Unknown arrangement")
            }
            actionName = "Arrange Motion Layers"
        case "configure":
            try input.only(["mediaRef", "expectedRevision", "requestId", "width", "height", "fps", "durationInFrames", "background", "formats", "applyFormatId", "removeFormatIds", "soundCues", "removeCueIds"])
            var changes: [MotionSceneOperation] = []
            if ["width", "height", "fps", "durationInFrames", "background"].contains(where: input.has) {
                changes.append(.configure(width: try input.integer("width", default: scene.width), height: try input.integer("height", default: scene.height),
                    fps: try input.number("fps", default: scene.fps), duration: try input.integer("durationInFrames", default: scene.durationInFrames),
                    background: try input.string("background", default: scene.background)))
            }
            for format in try input.formats() { changes.append(.format(format)) }
            for id in try input.strings("removeFormatIds") { changes.append(.removeFormat(id: id)) }
            for cue in try input.cues() { changes.append(.audioCue(cue)) }
            for id in try input.strings("removeCueIds") { changes.append(.removeAudioCue(id: id)) }
            if input.has("applyFormatId") { changes.append(.applyFormat(id: try input.string("applyFormatId"))) }
            operations = changes
            actionName = "Configure Motion Scene"
        default: throw ToolError("Unknown motion action")
        }
        let receipt = try await editor.motionScenes.apply(operations, mediaRef: mediaRef, expectedRevision: expected,
            actionName: actionName, editor: editor, requestID: input.requestID, requestFingerprint: input.fingerprint)
        return .ok(try await Self.motionJSON(receipt))
    }

    private func motionComponents(_ editor: EditorViewModel, _ input: MotionToolInput) async throws -> ToolResult {
        try input.only(["mediaRef", "componentId", "search", "offset", "limit", "includeSource", "repositoryPath"])
        let offset = try input.integer("offset", default: 0), limit = try input.integer("limit", default: 20)
        guard (0...10000).contains(offset), (1...50).contains(limit) else { throw ToolError("offset must be 0–10000 and limit 1–50") }
        let search = try input.string("search", default: "")
        if input.has("repositoryPath") {
            guard !input.has("mediaRef"), !input.has("componentId"), !input.has("includeSource") else { throw ToolError("Repository discovery cannot be combined with scene component inspection") }
            let path = try input.string("repositoryPath")
            let url = URL(fileURLWithPath: path, relativeTo: editor.linkedContextPath.map { URL(fileURLWithPath: $0, isDirectory: true) })
            let index = try await MotionComponentAnalyzer.shared.index(repository: url, search: search)
            struct Page: Encodable, Sendable { var items: [MotionRepositoryComponent]; var nextOffset: Int?; var total: Int; var truncated: Bool }
            let page = Array(index.components.dropFirst(offset).prefix(limit))
            return .ok(try await Self.motionJSON(Page(items: page, nextOffset: offset + page.count < index.components.count ? offset + page.count : nil,
                total: index.components.count, truncated: index.truncated)))
        }
        guard input.has("mediaRef") else {
            return .ok(try await Self.motionBuiltinCatalog(search: search, offset: offset, limit: limit))
        }
        let snapshot = try await editor.motionScenes.load(mediaRef: input.string("mediaRef"), editor: editor)
        if input.has("componentId") {
            let componentID = try input.string("componentId")
            guard var component = snapshot.scene.components.first(where: { $0.id == componentID }) else { throw ToolError("Unknown component ID") }
            if try !input.boolean("includeSource", default: false) { component.source = ""; component.stylesheet = "" }
            return .ok(try await Self.motionJSON(component))
        }
        struct Item: Encodable, Sendable { var id: String; var name: String; var propCount: Int; var fixtureNames: [String]; var slots: [String] }
        struct Page: Encodable, Sendable { var items: [Item]; var nextOffset: Int?; var total: Int; var revision: String }
        let matches = snapshot.scene.components.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let page = matches.dropFirst(offset).prefix(limit).map { Item(id: $0.id, name: $0.name, propCount: $0.props.count, fixtureNames: $0.fixtures.keys.sorted(), slots: $0.slots) }
        return .ok(try await Self.motionJSON(Page(items: page, nextOffset: offset + page.count < matches.count ? offset + page.count : nil,
                                                total: matches.count, revision: snapshot.revision)))
    }

    @concurrent private static func motionRead(_ snapshot: MotionSceneSnapshot, mediaRef: String, ids: [String]) async throws -> String {
        var scene = snapshot.scene
        if !ids.isEmpty {
            guard ids.allSatisfy({ id in scene.nodes.contains { $0.id == id } }) else { throw ToolError("Unknown layer ID") }
            var selected = Set(ids)
            var added = true
            while added {
                added = false
                for node in scene.nodes where node.parentID.map(selected.contains) == true {
                    if selected.insert(node.id).inserted { added = true }
                }
            }
            scene.nodes = scene.nodes.filter { selected.contains($0.id) }
        }
        struct ComponentSummary: Encodable { var id: String; var name: String }
        struct ReadReceipt: Encodable {
            var mediaRef: String; var revision: String; var sceneId: String; var width: Int; var height: Int; var fps: Double
            var durationInFrames: Int; var runtime: MotionSceneRuntime; var background: String; var nodes: [MotionNode]
            var components: [ComponentSummary]; var audioCues: [MotionAudioCue]; var formats: [MotionFormat]
        }
        let receipt = ReadReceipt(mediaRef: mediaRef, revision: snapshot.revision, sceneId: scene.id, width: scene.width, height: scene.height,
            fps: scene.fps, durationInFrames: scene.durationInFrames, runtime: scene.runtime, background: scene.background, nodes: scene.nodes,
            components: scene.components.map { ComponentSummary(id: $0.id, name: $0.name) }, audioCues: scene.audioCues, formats: scene.formats)
        return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }

    @concurrent private static func motionJSON<T: Encodable & Sendable>(_ value: T) async throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @concurrent private static func motionBuiltinCatalog(search: String, offset: Int, limit: Int) async throws -> String {
        guard let url = BundledResource.url("MotionRuntime/components.json") else { throw ToolError("Built-in component catalog is missing") }
        let catalog = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        let keys = catalog.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || catalog[$0]!.contains { $0.localizedCaseInsensitiveContains(search) } }
        struct Page: Encodable { var modules: [String: [String]]; var nextOffset: Int?; var total: Int; var note: String }
        let selected = keys.dropFirst(offset).prefix(limit)
        let result = Page(modules: Dictionary(uniqueKeysWithValues: selected.map { ($0, catalog[$0]!) }),
                          nextOffset: offset + selected.count < keys.count ? offset + selected.count : nil, total: keys.count,
                          note: "Import a local adapter that exports a frame-driven component to register it in the scene. Use mediaRef to discover registered product components.")
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
}

private struct MotionToolInput {
    let args: [String: Any]
    let fingerprint: String
    var requestID: String? { args["requestId"] as? String }

    init(_ args: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(args) else { throw ToolError("Arguments must be valid finite JSON") }
        let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        guard data.count <= 1024 * 1024 else { throw ToolError("Motion requests must be under 1 MB; import large components from a file") }
        self.args = args
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let id = args["requestId"] { guard let id = id as? String, MotionScene.validID(id) else { throw ToolError("Invalid requestId") } }
    }

    func only(_ keys: Set<String>) throws {
        if let unknown = args.keys.first(where: { $0 != "action" && !keys.contains($0) }) { throw ToolError("Parameter '\(unknown)' is not valid for this action") }
    }
    func has(_ key: String) -> Bool { args[key] != nil }
    func string(_ key: String, default fallback: String? = nil) throws -> String {
        if let value = args[key] { guard let result = value as? String else { throw ToolError("\(key) must be a string") }; return result }
        if let fallback { return fallback }
        throw ToolError("Missing \(key)")
    }
    func integer(_ key: String, default fallback: Int? = nil) throws -> Int {
        if let value = args[key] {
            guard let result = exactJSONInt(value), (-36_000_000...36_000_000).contains(result) else { throw ToolError("\(key) must be an integer within ±36000000") }
            return result
        }
        if let fallback { return fallback }
        throw ToolError("Missing \(key)")
    }
    func optionalInteger(_ key: String) throws -> Int? { has(key) ? try integer(key) : nil }
    func number(_ key: String, default fallback: Double) throws -> Double {
        guard let value = args[key] else { return fallback }
        guard !isJSONBoolean(value), let result = (value as? NSNumber)?.doubleValue, result.isFinite else { throw ToolError("\(key) must be a finite number") }
        return result
    }
    func boolean(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = args[key] else { return fallback }
        guard isJSONBoolean(value), let result = value as? Bool else { throw ToolError("\(key) must be a boolean") }
        return result
    }
    func strings(_ key: String) throws -> [String] {
        guard let value = args[key] else { return [] }
        guard let result = value as? [String], result.count <= 1000 else { throw ToolError("\(key) must be an array of at most 1000 strings") }
        return result
    }
    func targets(required: Bool = true) throws -> [String] {
        let ids = try strings("targets")
        try MotionScene.uniqueIDs(ids)
        guard !required || !ids.isEmpty else { throw ToolError("Provide at least one target layer ID") }
        return ids
    }
    func runtime() throws -> MotionSceneRuntime {
        guard let runtime = MotionSceneRuntime(rawValue: try string("runtime", default: "web")) else { throw ToolError("Unknown runtime") }
        return runtime
    }
    func values(_ key: String) throws -> [String: MotionValue] {
        guard let raw = args[key] as? [String: Any] else { throw ToolError("\(key) must be a property object") }
        return try decode(raw)
    }
    func objects(_ key: String, limit: Int = 128) throws -> [[String: Any]] {
        guard let value = args[key] else { return [] }
        guard let result = value as? [[String: Any]], result.count <= limit else { throw ToolError("\(key) must contain at most \(limit) objects") }
        return result
    }
    func layers(duration: Int) throws -> [MotionNode] {
        try objects("layers").map { raw in
            let item = try MotionToolInput(raw)
            try item.only(["id", "name", "kind", "parentId", "componentId", "startFrame", "durationFrames", "properties", "props"])
            guard let kind = MotionNode.Kind(rawValue: try item.string("kind")) else { throw ToolError("Unknown layer kind") }
            let start = try item.integer("startFrame", default: 0)
            return MotionNode(id: try item.string("id", default: UUID().uuidString), name: try item.string("name", default: kind.rawValue), kind: kind,
                parentID: item.has("parentId") ? try item.string("parentId") : nil, componentID: item.has("componentId") ? try item.string("componentId") : nil,
                startFrame: start, durationFrames: try item.integer("durationFrames", default: duration - start),
                properties: item.has("properties") ? try item.values("properties") : [:], props: item.has("props") ? try item.values("props") : [:])
        }
    }
    func easing() throws -> MotionEasing {
        guard let raw = args["easing"] else { return .init() }
        guard let object = raw as? [String: Any] else { throw ToolError("easing must be an object") }
        let item = try MotionToolInput(object)
        try item.only(["kind", "x1", "x2", "y1", "y2", "stiffness", "damping", "mass"])
        guard let kind = MotionEasing.Kind(rawValue: try item.string("kind", default: "easeOut")) else { throw ToolError("Unknown easing") }
        return MotionEasing(kind: kind, x1: try item.number("x1", default: 0.25), y1: try item.number("y1", default: 0.1),
            x2: try item.number("x2", default: 0.25), y2: try item.number("y2", default: 1), stiffness: try item.number("stiffness", default: 170),
            damping: try item.number("damping", default: 26), mass: try item.number("mass", default: 1))
    }
    func tracks() throws -> [MotionTrack] {
        try objects("tracks").map { raw in
            let item = try MotionToolInput(raw)
            try item.only(["binding", "keys", "repeatCount", "mirror", "gapFrames"])
            let keys: [MotionKey] = try item.objects("keys", limit: 4096).map { raw in
                let key = try MotionToolInput(raw)
                try key.only(["id", "frame", "value", "easing"])
                guard let value = raw["value"] else { throw ToolError("Keyframe value is required") }
                return MotionKey(id: try key.string("id", default: UUID().uuidString), frame: try key.integer("frame"), value: try decode(value), easing: try key.easing())
            }
            return MotionTrack(binding: try item.string("binding"), keys: keys, repeatCount: try item.integer("repeatCount", default: 1),
                mirror: try item.boolean("mirror", default: false), gapFrames: try item.integer("gapFrames", default: 0))
        }
    }
    func formats() throws -> [MotionFormat] {
        try objects("formats", limit: 32).map { raw in
            let item = try MotionToolInput(raw)
            try item.only(["id", "name", "width", "height", "overrides"])
            return MotionFormat(id: try item.string("id", default: UUID().uuidString), name: try item.string("name"),
                width: try item.integer("width"), height: try item.integer("height"), overrides: try decode(raw["overrides"] ?? [String: Any]()))
        }
    }
    func cues() throws -> [MotionAudioCue] {
        try objects("soundCues", limit: 256).map { raw in
            let item = try MotionToolInput(raw)
            try item.only(["id", "mediaRef", "frame", "trimStartFrame", "durationFrames", "volumeDB"])
            return MotionAudioCue(id: try item.string("id", default: UUID().uuidString), mediaRef: try item.string("mediaRef"), frame: try item.integer("frame"),
                trimStartFrame: try item.integer("trimStartFrame", default: 0), durationFrames: try item.integer("durationFrames"), volumeDB: try item.number("volumeDB", default: -12))
        }
    }
    private func decode<T: Decodable>(_ object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
    }
}
