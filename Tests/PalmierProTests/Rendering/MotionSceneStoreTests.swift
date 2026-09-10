import Foundation
import Testing
@testable import PalmierPro

struct MotionTestPackage: Sendable {
    let url: URL
    @concurrent static func make() async throws -> Self {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("motion-test-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(Project.mediaDirectoryName), withIntermediateDirectories: true)
        return Self(url: url)
    }
    @concurrent func remove() async throws { try FileManager.default.removeItem(at: url) }
    @concurrent func clone() async throws -> Self {
        let destination = url.deletingLastPathComponent().appendingPathComponent("motion-copy-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.copyItem(at: url, to: destination)
        return Self(url: destination)
    }
}

@Suite("Motion scene persistence and undo")
@MainActor
struct MotionSceneStoreTests {
    private func setup(_ package: MotionTestPackage) -> (EditorViewModel, UndoManager) {
        let editor = EditorViewModel()
        editor.projectURL = package.url
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undo.attach(undo)
        return (editor, undo)
    }

    @Test func revisionsPersistAndUndoExactlyAcrossSaveAs() async throws {
        let package = try await MotionTestPackage.make()
        let (editor, undo) = setup(package)
        let scene = MotionScene(width: 320, height: 180, fps: 30, durationInFrames: 60)
        let created = try await editor.motionScenes.create(scene, name: "Card", editor: editor)
        let node = MotionNode(id: "card", name: "Card", kind: .shape, durationFrames: 60)
        let added = try await editor.motionScenes.apply([.add([node])], mediaRef: created.mediaRef, expectedRevision: created.revision, actionName: "Add Layer", editor: editor)
        let asset = try #require(editor.mediaAssetsById[created.mediaRef])
        let firstURL = asset.url
        let moved = try await editor.motionScenes.apply([.values(ids: [node.id], values: ["x": .number(37.25)], frame: nil)],
            mediaRef: created.mediaRef, expectedRevision: added.revision, actionName: "Move Layer", editor: editor)
        let movedURL = asset.url
        #expect(movedURL != firstURL)
        #expect(try await MotionVideoGenerator.loadScene(at: movedURL).nodes[0].value(.x) == .number(37.25))
        let copied = try await package.clone()
        editor.projectURL = copied.url
        asset.url = copied.url.appendingPathComponent("media/" + movedURL.lastPathComponent)
        undo.undo()
        #expect(asset.url == copied.url.appendingPathComponent("media/" + firstURL.lastPathComponent))
        #expect(try await editor.motionScenes.load(mediaRef: created.mediaRef, editor: editor).scene.nodes[0].value(.x) == .number(0))
        #expect(editor.motionScenes.snapshot(for: created.mediaRef)?.revision != moved.revision)
        undo.redo()
        #expect(try await MotionVideoGenerator.loadScene(at: asset.url).nodes[0].value(.x) == .number(37.25))
        undo.removeAllActions()
        try await copied.remove()
        try await package.remove()
    }

    @Test func noOpAndStaleRequestDoNotAddUndoEntries() async throws {
        let package = try await MotionTestPackage.make()
        let (editor, undo) = setup(package)
        var scene = MotionScene(width: 320, height: 180, fps: 30, durationInFrames: 60)
        scene.nodes = [MotionNode(id: "card", name: "Card", kind: .shape, durationFrames: 60)]
        let created = try await editor.motionScenes.create(scene, name: "Card", editor: editor)
        undo.removeAllActions()
        let noOp = try await editor.motionScenes.apply([.values(ids: ["card"], values: ["x": .number(0)], frame: nil)],
            mediaRef: created.mediaRef, expectedRevision: created.revision, actionName: "Move", editor: editor)
        #expect(noOp.unchanged)
        #expect(!undo.canUndo)
        await #expect(throws: MotionSceneError.self) {
            try await editor.motionScenes.apply([.remove(ids: ["card"])], mediaRef: created.mediaRef,
                expectedRevision: "old", actionName: "Delete", editor: editor)
        }
        #expect(!undo.canUndo)
        try await package.remove()
    }

    @Test func retriesReplayOnlyTheIdenticalRequest() async throws {
        let package = try await MotionTestPackage.make()
        let (editor, _) = setup(package)
        let scene = MotionScene(width: 320, height: 180, fps: 30, durationInFrames: 60)
        let first = try await editor.motionScenes.create(scene, name: "Card", editor: editor, requestID: "create-card", requestFingerprint: "request-one")
        let replay = try await editor.motionScenes.create(scene, name: "Card", editor: editor, requestID: "create-card", requestFingerprint: "request-one")
        #expect(replay.replayed)
        #expect(replay.mediaRef == first.mediaRef)
        #expect(editor.mediaAssets.count == 1)
        await #expect(throws: MotionSceneError.self) {
            try await editor.motionScenes.create(scene, name: "Different", editor: editor, requestID: "create-card", requestFingerprint: "different-request")
        }
        try await package.remove()
    }

    @Test func cancelledQueuedEditDoesNotInstallOrPublish() async throws {
        let package = try await MotionTestPackage.make()
        let (editor, undo) = setup(package)
        let created = try await editor.motionScenes.create(MotionScene(width: 320, height: 180, fps: 30, durationInFrames: 60), name: "Card", editor: editor)
        undo.removeAllActions()
        editor.projectPackageCoordinator.saveStarted()
        let edit = Task {
            try await editor.motionScenes.apply([.add([MotionNode(name: "Card", kind: .shape, durationFrames: 60)])], mediaRef: created.mediaRef,
                expectedRevision: created.revision, actionName: "Add", editor: editor)
        }
        edit.cancel()
        await #expect(throws: CancellationError.self) { try await edit.value }
        editor.projectPackageCoordinator.saveFinished(success: true)
        #expect(editor.motionScenes.snapshot(for: created.mediaRef)?.scene.nodes.isEmpty == true)
        #expect(!undo.canUndo)
        try await package.remove()
    }
}

@Suite("Motion file mutation coordination")
@MainActor
struct MotionFileMutationTests {
    @Test func synchronousMutationsWaitForFileCommit() async throws {
        let coordinator = ProjectPackageCoordinator()
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        var committed = false
        let work = Task {
            try await coordinator.performFileMutation(validate: {}) {
                #expect(!Thread.isMainThread)
                started.continuation.yield(())
                release.wait()
                return 1
            } rollback: { _ in } commit: { _ in committed = true }
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        var synchronousObservedCommit = false
        let synchronous = Task {
            try await coordinator.performMutation { synchronousObservedCommit = committed }
        }
        release.signal()
        _ = try await work.value
        try await synchronous.value
        #expect(synchronousObservedCommit)
    }

    @Test func cancellationAfterFileWorkRollsBackBeforeCloseCompletes() async throws {
        let coordinator = ProjectPackageCoordinator()
        let started = AsyncStream<Void>.makeStream()
        let rolledBack = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        var committed = false
        let work = Task {
            try await coordinator.performFileMutation(validate: {}) {
                started.continuation.yield(())
                release.wait()
                return 1
            } rollback: { _ in
                #expect(!Thread.isMainThread)
                rolledBack.continuation.yield(())
            } commit: { _ in committed = true }
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        work.cancel()
        let closing = Task { await coordinator.beginClosing() }
        release.signal()
        await #expect(throws: CancellationError.self) { try await work.value }
        await closing.value
        var rollbackIterator = rolledBack.stream.makeAsyncIterator()
        await rollbackIterator.next()
        #expect(!committed)
        #expect(throws: CancellationError.self) { try coordinator.beginMutation() }
    }
}
