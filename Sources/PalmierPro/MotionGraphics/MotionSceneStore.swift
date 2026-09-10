import Foundation

struct MotionSceneReceipt: Codable, Sendable {
    var mediaRef: String
    var sceneID: String
    var revision: String
    var changedIDs: [String]
    var unchanged: Bool
    var status: String = "saved"
    var replayed: Bool = false
}

struct MotionSceneSnapshot: Sendable {
    var scene: MotionScene
    var revision: String
    var url: URL
}

@Observable
@MainActor
final class MotionSceneStore {
    private let ownerID = UUID().uuidString
    private(set) var changeSequence = 0
    private(set) var busyIDs: Set<String> = []
    var presentedMediaRef: String?
    @ObservationIgnored private var cache: [String: MotionSceneSnapshot] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var loads: [URL: Task<MotionScene, any Error>] = [:]
    @ObservationIgnored private var receipts: [String: (fingerprint: String, receipt: MotionSceneReceipt)] = [:]
    @ObservationIgnored private var activeRequests: Set<String> = []
    @ObservationIgnored private var receiptOrder: [String] = []

    func snapshot(for mediaRef: String) -> MotionSceneSnapshot? {
        _ = changeSequence
        return cache[mediaRef]
    }

    func load(mediaRef: String, editor: EditorViewModel) async throws -> MotionSceneSnapshot {
        guard let asset = editor.mediaAssetsById[mediaRef], asset.type == .motion else {
            throw MotionSceneError.invalidField("unknown motion asset '\(mediaRef)'")
        }
        let url = asset.url
        if let cached = cache[mediaRef], cached.url == url { return cached }
        let task: Task<MotionScene, any Error>
        if let existing = loads[url] { task = existing }
        else {
            task = Task { try await MotionVideoGenerator.loadScene(at: url) }
            loads[url] = task
        }
        defer { loads[url] = nil }
        let scene = try await task.value
        try Task.checkCancellation()
        guard editor.mediaAssetsById[mediaRef] === asset, asset.url == url else {
            throw MotionSceneError.invalidField("motion asset changed while loading")
        }
        if let cached = cache[mediaRef], cached.url == url { return cached }
        return cacheScene(scene, mediaRef: mediaRef, url: url)
    }

    func create(_ scene: MotionScene, name: String, editor: EditorViewModel, requestID: String? = nil, requestFingerprint: String? = nil) async throws -> MotionSceneReceipt {
        if let replay = try replayReceipt(requestID, fingerprint: requestFingerprint) { return replay }
        if let requestID { activeRequests.insert(requestID) }
        defer { if let requestID { activeRequests.remove(requestID) } }
        guard scene.runtime.isAvailable else { throw MotionSceneError.reactNativeUnavailable }
        guard let projectURL = editor.projectURL else { throw MotionSceneError.invalidField("open a project before creating a motion scene") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024 else { throw MotionSceneError.invalidField("invalid scene name") }
        let pinned = try await MotionSceneAudio.pin(scene: scene, urls: soundURLs(scene.audioCues.map(\.mediaRef), scene: scene, editor: editor))
        let checked = try await Self.validate(pinned)
        let mediaRef = UUID().uuidString
        let filename = "motion-\(UUID().uuidString).motion"
        busyIDs.insert(mediaRef)
        defer { busyIDs.remove(mediaRef) }
        var receipt: MotionSceneReceipt?
        _ = try await editor.projectPackageCoordinator.performFileMutation {
            guard editor.projectURL == projectURL else { throw MotionSceneError.invalidField("project changed before scene creation") }
        } operation: {
            try Self.install(checked, projectURL: projectURL, filename: filename)
        } rollback: { url in
            try FileManager.default.removeItem(at: url)
        } commit: { url in
            guard editor.projectURL == projectURL else { throw MotionSceneError.invalidField("project changed during scene creation") }
            let before = editor.mediaLibraryUndoSnapshot()
            editor.undo.perform("Create Motion Scene") {
                editor.undo.register("Create Motion Scene", withTarget: editor) { vm in
                    vm.restoreMediaLibraryUndoSnapshot(before, actionName: "Create Motion Scene")
                }
                let asset = MediaAsset(id: mediaRef, url: url, type: .motion, name: name, duration: checked.duration)
                Self.setMetadata(checked, asset: asset)
                editor.importMediaAsset(asset)
                let snapshot = cacheScene(checked, mediaRef: mediaRef, url: url)
                receipt = MotionSceneReceipt(mediaRef: mediaRef, sceneID: checked.id, revision: snapshot.revision,
                                             changedIDs: checked.nodes.map(\.id), unchanged: false)
            }
            editor.onProjectCheckpointRequired?()
        }
        guard let receipt else { throw MotionSceneError.writeFailed }
        remember(receipt, requestID: requestID, fingerprint: requestFingerprint)
        return receipt
    }

    func apply(
        _ operations: [MotionSceneOperation], mediaRef: String, expectedRevision: String,
        actionName: String, editor: EditorViewModel, requestID: String? = nil, requestFingerprint: String? = nil
    ) async throws -> MotionSceneReceipt {
        if let replay = try replayReceipt(requestID, fingerprint: requestFingerprint) { return replay }
        if let requestID { activeRequests.insert(requestID) }
        defer { if let requestID { activeRequests.remove(requestID) } }
        guard !busyIDs.contains(mediaRef) else { throw MotionSceneError.invalidField("scene has an edit in progress; read its revision and retry") }
        busyIDs.insert(mediaRef)
        defer { busyIDs.remove(mediaRef) }
        let original = try await load(mediaRef: mediaRef, editor: editor)
        guard original.revision == expectedRevision else { throw MotionSceneError.invalidField("scene revision conflict; read the current scene and retry") }
        guard let projectURL = editor.projectURL, let asset = editor.mediaAssetsById[mediaRef] else { throw MotionSceneError.invalidField("motion project is unavailable") }
        let soundIDs = operations.compactMap { operation -> String? in
            if case .audioCue(let cue) = operation { return cue.mediaRef }
            return nil
        }
        let pinned = try await MotionSceneAudio.pin(scene: original.scene, urls: soundURLs(soundIDs, scene: original.scene, editor: editor))
        let change = try await Self.plan(operations, original: pinned)
        try Task.checkCancellation()
        guard editor.projectURL == projectURL, editor.mediaAssetsById[mediaRef] === asset,
              asset.url == original.url, cache[mediaRef]?.revision == expectedRevision else {
            throw MotionSceneError.invalidField("scene or project changed while validating the edit")
        }
        if change.unchanged {
            let receipt = MotionSceneReceipt(mediaRef: mediaRef, sceneID: original.scene.id, revision: original.revision, changedIDs: [], unchanged: true)
            remember(receipt, requestID: requestID, fingerprint: requestFingerprint)
            return receipt
        }
        let previousLocation = Location(url: original.url, projectURL: projectURL)
        let filename = "motion-\(UUID().uuidString).motion"
        let identity = ownerID
        var receipt: MotionSceneReceipt?
        let validate = {
            guard editor.projectURL == projectURL, editor.mediaAssetsById[mediaRef] === asset,
                  asset.url == original.url, self.cache[mediaRef]?.revision == expectedRevision else {
                throw MotionSceneError.invalidField("scene or project changed during the edit")
            }
        }
        _ = try await editor.projectPackageCoordinator.performFileMutation(validate: validate) {
            try Self.install(change.scene, projectURL: projectURL, filename: filename)
        } rollback: { url in
            try FileManager.default.removeItem(at: url)
        } commit: { url in
            try validate()
            editor.undo.perform(actionName) {
                editor.undo.register(actionName, withTarget: editor) { vm in
                    vm.motionScenes.restore(original.scene, location: previousLocation, inverse: change.scene,
                                            inverseLocation: .project(Project.mediaDirectoryName + "/" + filename),
                                            mediaRef: mediaRef, projectID: identity, actionName: actionName, editor: vm)
                }
                publish(change.scene, asset: asset, url: url, editor: editor)
                receipt = MotionSceneReceipt(mediaRef: mediaRef, sceneID: change.scene.id, revision: cache[mediaRef]!.revision,
                                             changedIDs: change.changedIDs, unchanged: false)
            }
        }
        guard let receipt else { throw MotionSceneError.writeFailed }
        remember(receipt, requestID: requestID, fingerprint: requestFingerprint)
        return receipt
    }

    private func restore(_ scene: MotionScene, location: Location, inverse: MotionScene, inverseLocation: Location,
                         mediaRef: String, projectID: String, actionName: String, editor: EditorViewModel) {
        guard ownerID == projectID, let projectURL = editor.projectURL,
              let asset = editor.mediaAssetsById[mediaRef] else { return }
        editor.undo.register(actionName, withTarget: editor) { vm in
            vm.motionScenes.restore(inverse, location: inverseLocation, inverse: scene, inverseLocation: location,
                                    mediaRef: mediaRef, projectID: projectID, actionName: actionName, editor: vm)
        }
        publish(scene, asset: asset, url: location.resolve(projectURL: projectURL), editor: editor)
    }

    private func publish(_ scene: MotionScene, asset: MediaAsset, url: URL, editor: EditorViewModel) {
        asset.url = url
        Self.setMetadata(scene, asset: asset)
        cacheScene(scene, mediaRef: asset.id, url: url)
        editor.mediaVisualCache.invalidate(asset.id)
        editor.updateManifestMetadata(for: [asset])
        editor.timelineRenderRevision &+= 1
        editor.videoEngine?.rebuild()
        editor.onProjectCheckpointRequired?()
    }

    @discardableResult
    private func cacheScene(_ scene: MotionScene, mediaRef: String, url: URL) -> MotionSceneSnapshot {
        let snapshot = MotionSceneSnapshot(scene: scene, revision: UUID().uuidString, url: url)
        cache[mediaRef] = snapshot
        cacheOrder.removeAll { $0 == mediaRef }
        cacheOrder.append(mediaRef)
        while cacheOrder.count > 16 {
            let removed = cacheOrder.removeFirst()
            cache.removeValue(forKey: removed)
        }
        changeSequence &+= 1
        return snapshot
    }

    func replayReceipt(_ requestID: String?, fingerprint: String?) throws -> MotionSceneReceipt? {
        guard let requestID else { return nil }
        guard MotionScene.validID(requestID), let fingerprint, !fingerprint.isEmpty else {
            throw MotionSceneError.invalidField("request ID requires a valid request fingerprint")
        }
        if let previous = receipts[requestID] {
            guard previous.fingerprint == fingerprint else { throw MotionSceneError.invalidField("request ID was already used for a different request") }
            var receipt = previous.receipt
            receipt.replayed = true
            return receipt
        }
        guard !activeRequests.contains(requestID) else { throw MotionSceneError.invalidField("request is still running; retry after it finishes") }
        return nil
    }

    private func remember(_ receipt: MotionSceneReceipt, requestID: String?, fingerprint: String?) {
        guard let requestID, let fingerprint else { return }
        receipts[requestID] = (fingerprint, receipt)
        receiptOrder.append(requestID)
        while receiptOrder.count > 128 { receipts.removeValue(forKey: receiptOrder.removeFirst()) }
    }

    private static func setMetadata(_ scene: MotionScene, asset: MediaAsset) {
        asset.hasAudio = true
        asset.duration = scene.duration
        asset.sourceWidth = scene.width
        asset.sourceHeight = scene.height
        asset.sourceFPS = scene.fps
    }

    private func soundURLs(_ ids: [String], scene: MotionScene, editor: EditorViewModel) throws -> [String: URL] {
        var urls: [String: URL] = [:]
        for id in Set(ids) where scene.sounds[id] == nil {
            guard let asset = editor.mediaAssetsById[id], asset.type == .audio || asset.type == .video && asset.hasAudio else {
                throw MotionSceneError.invalidField("audio cue refers to unavailable sound '\(id)'")
            }
            urls[id] = asset.url
        }
        return urls
    }

    @concurrent private static func validate(_ scene: MotionScene) async throws -> MotionScene { try scene.validated() }
    @concurrent private static func plan(_ operations: [MotionSceneOperation], original: MotionScene) async throws -> MotionSceneChange {
        try MotionSceneOperations.apply(operations, to: original)
    }

    nonisolated private static func install(_ scene: MotionScene, projectURL: URL, filename: String) throws -> URL {
        try Task.checkCancellation()
        let data = try scene.encoded()
        guard data.count <= MotionScene.maxDocumentBytes else { throw MotionSceneError.invalidField("scene package is too large") }
        let staged = try FileIO.stageData(data, pathExtension: "motion")
        defer { try? FileManager.default.removeItem(at: staged) }
        let prepared = try FileIO.prepareStagedFile(from: staged, nextTo: projectURL)
        defer { try? FileManager.default.removeItem(at: prepared) }
        try Task.checkCancellation()
        let destination = projectURL.appendingPathComponent(Project.mediaDirectoryName).appendingPathComponent(filename)
        try FileIO.installPreparedFile(from: prepared, to: destination)
        return destination
    }

    private enum Location {
        case project(String)
        case external(URL)

        init(url: URL, projectURL: URL) {
            let prefix = projectURL.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            self = path.hasPrefix(prefix) ? .project(String(path.dropFirst(prefix.count))) : .external(url)
        }

        func resolve(projectURL: URL) -> URL {
            switch self {
            case .project(let path): projectURL.appendingPathComponent(path)
            case .external(let url): url
            }
        }
    }
}
