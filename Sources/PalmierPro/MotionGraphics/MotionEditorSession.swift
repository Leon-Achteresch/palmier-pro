import AppKit
import ImageIO
import UniformTypeIdentifiers

@Observable
@MainActor
final class MotionEditorSession {
    let editor: EditorViewModel
    private(set) var mediaRef: String
    private(set) var scene: MotionScene?
    private(set) var revision = ""
    private(set) var evaluated: MotionEvaluatedFrame?
    private(set) var presentationView: NSView?
    private(set) var slots: [MotionSlotBounds] = []
    var selectedSlotID: String?
    private(set) var busy = false
    private(set) var playing = false
    private(set) var frame = 0
    var selection: Set<String> = []
    var autoKey = false
    var snapping = true
    var interacting = false
    var zoom: Double = 1
    var staggerFrames = 4
    private(set) var interactionGeneration = 0
    var error: String?
    var selectedBinding: String?
    var selectedKeyID: String?
    var importExportName = "default"
    var search = ""
    var selectedComponentID: String?
    var repositoryURL: URL?
    var repositoryIndex: MotionRepositoryIndex?
    var componentCandidate: MotionComponentCandidate?
    var showingComponentCreation = false
    @ObservationIgnored private var renderer: (any MotionSceneRendering)?
    @ObservationIgnored private var rendererSize: CGSize?
    @ObservationIgnored private var rendererRuntime: MotionSceneRuntime?
    @ObservationIgnored private var loadedRenderKey: String?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private let audioPreview = MotionAudioPreview()
    @ObservationIgnored private var audioStopTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRender: RenderRequest?
    @ObservationIgnored private var renderGeneration = 0
    @ObservationIgnored private var gesture: GestureSnapshot?
    @ObservationIgnored private var cancelledGesture = false
    @ObservationIgnored private var preview: MotionScene?
    @ObservationIgnored private var previewKey = ""
    @ObservationIgnored private var previewOperations: [MotionSceneOperation] = []
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var closed = false

    private struct RenderRequest {
        var scene: MotionScene
        var key: String
        var frame: Int
        var generation: Int
    }

    private struct GestureSnapshot {
        var scene: MotionScene
        var revision: String
        var frame: Int
        var ids: [String]
    }

    init(editor: EditorViewModel, mediaRef: String) {
        self.editor = editor
        self.mediaRef = mediaRef
    }

    func open() async {
        do {
            if mediaRef == "new" { return }
            let snapshot = try await editor.motionScenes.load(mediaRef: mediaRef, editor: editor)
            try Task.checkCancellation()
            guard !closed else { return }
            accept(snapshot)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func createScene(name: String, runtime: MotionSceneRuntime) {
        guard scene == nil, mediaRef == "new" else { return }
        run {
            guard (1...120).contains(self.editor.timeline.fps) else { throw MotionSceneError.invalidField("unsupported timeline frame rate") }
            let document = MotionScene(width: self.editor.timeline.width, height: self.editor.timeline.height,
                                       fps: Double(self.editor.timeline.fps), durationInFrames: self.editor.timeline.fps * 5, runtime: runtime)
            let receipt = try await self.editor.motionScenes.create(document, name: name, editor: self.editor)
            self.mediaRef = receipt.mediaRef
            if let snapshot = self.editor.motionScenes.snapshot(for: receipt.mediaRef) { self.accept(snapshot) }
        }
    }

    func refresh() {
        guard let snapshot = editor.motionScenes.snapshot(for: mediaRef), snapshot.revision != revision else { return }
        cancelGesture()
        accept(snapshot)
    }

    private func accept(_ snapshot: MotionSceneSnapshot) {
        stopPlayback()
        scene = snapshot.scene
        revision = snapshot.revision
        selection.formIntersection(Set(snapshot.scene.nodes.map(\.id)))
        frame = min(frame, snapshot.scene.durationInFrames - 1)
        preview = nil
        requestRender()
    }

    func select(_ id: String, extending: Bool = false) {
        cancelGesture()
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else { selection = [id] }
        selectedBinding = nil
        selectedKeyID = nil
        selectedComponentID = nil
        selectedSlotID = nil
    }

    func seek(_ value: Int) {
        guard let scene else { return }
        stopPlayback()
        cancelGesture()
        frame = min(max(value, 0), scene.durationInFrames - 1)
        requestRender()
    }

    func togglePlayback() {
        if playing { stopPlayback(); return }
        guard let scene else { return }
        cancelGesture()
        if frame == scene.durationInFrames - 1 { seek(0) }
        playing = true
        let startFrame = frame
        let currentRevision = revision
        let stop = audioStopTask
        playbackTask = Task { @MainActor in
            await stop?.value
            do {
                if !scene.audioCues.isEmpty { try await audioPreview.play(scene: scene, revision: currentRevision, frame: startFrame) }
                try Task.checkCancellation()
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription; stopPlayback(); return }
            let start = ContinuousClock.now
            while !Task.isCancelled, !closed {
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let next = startFrame + Int(seconds * scene.fps)
                frame = min(next, scene.durationInFrames - 1)
                requestRender()
                if next >= scene.durationInFrames - 1 { stopPlayback(); return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    func stopPlayback() {
        guard playing || playbackTask != nil else { return }
        playing = false
        playbackTask?.cancel()
        playbackTask = nil
        audioStopTask = Task { await audioPreview.stop() }
    }

    func perform(_ operations: [MotionSceneOperation], name: String = "Edit Motion Scene") {
        guard !busy, scene != nil else { return }
        cancelGesture()
        let expected = revision
        run {
            _ = try await self.editor.motionScenes.apply(operations, mediaRef: self.mediaRef, expectedRevision: expected,
                                                         actionName: name, editor: self.editor)
        }
    }

    func setValue(_ binding: String, value: MotionValue) {
        perform([.values(ids: orderedSelection, values: [binding: value], frame: autoKey ? frame : nil)])
    }

    var orderedSelection: [String] { scene?.nodes.filter { selection.contains($0.id) }.map(\.id) ?? [] }
    var selectedNode: MotionNode? { selection.count == 1 ? scene?.nodes.first { selection.contains($0.id) } : nil }

    func add(_ kind: MotionNode.Kind, componentID: String? = nil) {
        guard let scene else { return }
        let name = componentID.flatMap { id in scene.components.first { $0.id == id }?.name } ?? kind.title
        var node = scene.makeLayer(kind: kind, name: name, componentID: componentID)
        if kind == .text { node.properties["text"] = .string(L10n.string("Title")) }
        if kind == .path {
            node.properties["path"] = .string("M 20 150 C 80 20 240 20 300 150")
            node.properties["fill"] = .string("transparent")
            node.properties["stroke"] = .string("#ffffff")
            node.properties["strokeWidth"] = .number(4)
        }
        perform([.add([node])], name: "Add Motion Layer")
        selection = [node.id]
    }

    func addRecipe(_ kind: MotionRecipe.Kind) {
        guard let scene, !selection.isEmpty else { return }
        let duration = min(18, scene.durationInFrames - frame)
        perform([.recipe(ids: orderedSelection, recipe: MotionRecipe(kind: kind, startFrame: frame, durationFrames: duration), stagger: staggerFrames)], name: "Animate Motion Layers")
    }

    func align(_ alignment: MotionAlignment) {
        guard let scene, !busy else { return }
        let expected = revision, ids = orderedSelection, currentFrame = frame, key = autoKey
        run {
            let operations = try await MotionLayoutOperations.align(scene: scene, revision: expected, frame: currentFrame, ids: ids, alignment: alignment, autoKey: key)
            _ = try await self.editor.motionScenes.apply(operations, mediaRef: self.mediaRef, expectedRevision: expected,
                                                         actionName: "Align Motion Layers", editor: self.editor)
        }
    }

    func previewTranslation(id: String, dx: Double, dy: Double) {
        guard !busy, !interacting, !cancelledGesture, let scene else { return }
        if gesture == nil {
            stopPlayback()
            if !selection.contains(id) { selection = [id] }
            gesture = GestureSnapshot(scene: scene, revision: revision, frame: frame, ids: orderedSelection)
        }
        guard let gesture else { return }
        previewGeneration &+= 1
        let generation = previewGeneration, key = autoKey, snap = snapping
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do {
                let operations = try await MotionLayoutOperations.translate(scene: gesture.scene, revision: gesture.revision,
                    frame: gesture.frame, ids: gesture.ids, dx: dx, dy: dy, snap: snap, autoKey: key)
                let change = try await Self.plan(operations, scene: gesture.scene)
                try Task.checkCancellation()
                guard generation == previewGeneration, self.revision == gesture.revision else { return }
                previewOperations = operations
                preview = change.scene
                previewKey = UUID().uuidString
                requestRender()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func previewTransform(id: String, dx: Double, dy: Double, rotating: Bool) {
        guard !busy, !interacting, !cancelledGesture, let scene else { return }
        if gesture == nil {
            stopPlayback()
            selection = [id]
            gesture = GestureSnapshot(scene: scene, revision: revision, frame: frame, ids: [id])
        }
        guard let gesture else { return }
        previewGeneration &+= 1
        let generation = previewGeneration, key = autoKey
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do {
                let operations = try await MotionLayoutOperations.transform(scene: gesture.scene, revision: gesture.revision,
                    frame: gesture.frame, id: id, dx: dx, dy: dy, rotating: rotating, autoKey: key)
                let change = try await Self.plan(operations, scene: gesture.scene)
                try Task.checkCancellation()
                guard generation == previewGeneration, revision == gesture.revision else { return }
                previewOperations = operations
                preview = change.scene
                previewKey = UUID().uuidString
                requestRender()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func commitGesture() {
        cancelledGesture = false
        guard let gesture else { return }
        let task = previewTask
        run {
            await task?.value
            guard self.gesture?.revision == gesture.revision, !self.previewOperations.isEmpty else { return }
            let operations = self.previewOperations
            self.gesture = nil
            _ = try await self.editor.motionScenes.apply(operations, mediaRef: self.mediaRef, expectedRevision: gesture.revision,
                                                         actionName: "Move Motion Layers", editor: self.editor)
            self.preview = nil
            self.previewOperations = []
        }
    }

    func resetInteraction() {
        cancelGesture()
        requestRender()
    }

    func cancelGesture() {
        interactionGeneration &+= 1
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        guard gesture != nil || preview != nil else { return }
        if gesture != nil { cancelledGesture = true }
        gesture = nil
        preview = nil
        previewOperations = []
        requestRender()
    }

    func importComponent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["tsx", "jsx", "ts", "js", "mjs", "json"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url, self.scene != nil else { return }
                self.importComponent(at: url, exportName: self.importExportName)

            }
        }
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url, let scene = self.scene else { return }
                let expected = self.revision
                self.run {
                    let node = try await Self.imageNode(url: url, scene: scene)
                    _ = try await self.editor.motionScenes.apply([.add([node])], mediaRef: self.mediaRef,
                        expectedRevision: expected, actionName: "Add Motion Image", editor: self.editor)
                    self.selection = [node.id]
                }
            }
        }
    }

    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy, !closed else { return }
        busy = true
        error = nil
        operationTask = Task { @MainActor in
            defer { busy = false; operationTask = nil }
            do {
                try await work()
                try Task.checkCancellation()
                guard !closed else { return }
                refresh()
            } catch is CancellationError { cancelGesture() }
            catch { self.error = error.localizedDescription; cancelGesture() }
        }
    }

    func cancelOperation() { operationTask?.cancel(); cancelGesture(); stopPlayback() }

    func close() {
        closed = true
        cancelOperation()
        renderTask?.cancel()
        pendingRender = nil
        renderer?.tearDown()
        renderer = nil
        presentationView = nil
        audioStopTask = Task { await audioPreview.close() }
    }

    private func requestRender() {
        guard !closed, let document = preview ?? scene else { return }
        renderGeneration &+= 1
        pendingRender = RenderRequest(scene: document, key: preview == nil ? revision : previewKey, frame: frame, generation: renderGeneration)
        guard renderTask == nil else { return }
        renderTask = Task { @MainActor in
            defer { renderTask = nil }
            while let request = pendingRender, !Task.isCancelled, !closed {
                pendingRender = nil
                do {
                    if renderer == nil || rendererSize != request.scene.size || rendererRuntime != request.scene.runtime {
                        renderer?.tearDown()
                        presentationView = nil
                        let created = try await MotionSceneRendererFactory.renderer(for: request.scene)
                        if Task.isCancelled || closed { created.tearDown(); return }
                        renderer = created
                        rendererSize = request.scene.size
                        rendererRuntime = request.scene.runtime
                        loadedRenderKey = nil
                    }
                    guard let renderer else { return }
                    if loadedRenderKey != request.key {
                        try await renderer.load(scene: request.scene)
                        loadedRenderKey = request.key
                    }
                    try Task.checkCancellation()
                    try await renderer.seek(toMilliseconds: Double(request.frame) / request.scene.fps * 1000)
                    let result = try await MotionFrameEvaluator.shared.evaluate(request.scene, key: request.key, frame: request.frame)
                    let measuredSlots = try await renderer.slotBounds()
                    let registeredSlots = measuredSlots.filter { slot in
                        guard let node = request.scene.nodes.first(where: { $0.id == slot.nodeID }) else { return false }
                        return request.scene.components.first(where: { $0.id == node.componentID })?.slots.contains(slot.slotID) == true
                    }
                    guard Set(registeredSlots.map(\.id)).count == registeredSlots.count else {
                        throw MotionSceneError.sceneFailed("editable slots require unique IDs; supply stable itemKey values for repeated slots")
                    }
                    try Task.checkCancellation()
                    guard request.generation == renderGeneration, !closed else { continue }
                    evaluated = result
                    slots = registeredSlots
                    presentationView = renderer.presentationView
                } catch is CancellationError { return }
                catch {
                    if request.generation == renderGeneration, !closed { self.error = error.localizedDescription }
                    loadedRenderKey = nil
                }
            }
        }
    }

    @concurrent private static func plan(_ operations: [MotionSceneOperation], scene: MotionScene) async throws -> MotionSceneChange {
        try MotionSceneOperations.apply(operations, to: scene)
    }

    func previewSlot(_ slot: MotionSlotBounds, dx: Double, dy: Double) {
        guard !busy, !interacting, !cancelledGesture, let scene else { return }
        if gesture == nil {
            stopPlayback()
            selection = [slot.nodeID]
            selectedSlotID = slot.id
            gesture = GestureSnapshot(scene: scene, revision: revision, frame: frame, ids: [slot.nodeID])
        }
        guard let gesture else { return }
        previewGeneration &+= 1
        let generation = previewGeneration, key = autoKey
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do {
                let operations = try await MotionLayoutOperations.translateSlot(scene: gesture.scene, revision: gesture.revision,
                    frame: gesture.frame, slot: slot, dx: dx, dy: dy, autoKey: key)
                let change = try await Self.plan(operations, scene: gesture.scene)
                try Task.checkCancellation()
                guard generation == previewGeneration, revision == gesture.revision else { return }
                previewOperations = operations
                preview = change.scene
                previewKey = UUID().uuidString
                requestRender()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    @concurrent private static func imageNode(url: URL, scene: MotionScene) async throws -> MotionNode {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw MotionSceneError.invalidField("choose an image smaller than 20 MB") }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MotionSceneError.invalidField("image could not be decoded") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw MotionSceneError.writeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MotionSceneError.writeFailed }
        let width = min(Double(image.width), Double(scene.width) / 2)
        let height = width * Double(image.height) / Double(image.width)
        return MotionNode(name: url.deletingPathExtension().lastPathComponent, kind: .image, durationFrames: scene.durationInFrames,
            properties: ["image": .string("data:image/png;base64," + (output as Data).base64EncodedString()), "width": .number(width), "height": .number(height),
                         "x": .number((Double(scene.width) - width) / 2), "y": .number((Double(scene.height) - height) / 2)])
    }
}
