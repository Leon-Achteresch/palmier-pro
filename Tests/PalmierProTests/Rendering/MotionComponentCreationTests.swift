import Foundation
import Testing
@testable import PalmierPro

@Suite("Motion component creation")
struct MotionComponentCreationTests {
    @Test(arguments: MotionSceneRuntime.allCases, MotionComponentTemplate.allCases)
    func templatesCompileWithEditableControls(runtime: MotionSceneRuntime, template: MotionComponentTemplate) async throws {
        let result = try await MotionComponentCompiler.shared.compile(source: template.source(runtime: runtime), name: "My component", runtime: runtime)
        #expect(result.runtime == runtime)
        #expect(result.component.name == "My component")
        #expect(result.component.props.first { $0.id == "title" }?.defaultValue == .string("Title"))
        #expect(result.component.props.contains { $0.id == "color" })
        #expect(!result.component.source.isEmpty)
    }

    @Test @MainActor func componentAndFirstLayerPersistAndUndoTogether() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let editor = EditorViewModel()
            editor.projectURL = package.url
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let scene = MotionScene(width: 640, height: 360, fps: 30, durationInFrames: 150)
            let created = try await editor.motionScenes.create(scene, name: "Scene", editor: editor)
            undo.removeAllActions()
            let receipt = try await editor.motionScenes.createComponent(name: "Card", source: MotionComponentTemplate.card.source(runtime: .web),
                mediaRef: created.mediaRef, expectedRevision: created.revision, editor: editor)
            let asset = try #require(editor.mediaAssetsById[created.mediaRef])
            let saved = try await MotionVideoGenerator.loadScene(at: asset.url)
            let component = try #require(saved.components.first)
            let node = try #require(saved.nodes.first)
            #expect(saved.components.count == 1 && saved.nodes.count == 1)
            #expect(node.componentID == component.id)
            #expect(node.value(.x) == .number(160) && node.value(.y) == .number(90))
            #expect(node.durationFrames == 150)
            #expect(Set(receipt.changedIDs) == [component.id, node.id])
            undo.undo()
            let undone = try await MotionVideoGenerator.loadScene(at: asset.url)
            #expect(undone.components.isEmpty && undone.nodes.isEmpty)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(try await MotionVideoGenerator.loadScene(at: asset.url) == saved)
            undo.removeAllActions()
            try await package.remove()
        } catch { try await package.remove(); throw error }
    }

    @Test @MainActor func invalidCancelledAndStaleCreationLeaveNoUndoOrChanges() async throws {
        let package = try await MotionTestPackage.make()
        do {
            let editor = EditorViewModel()
            editor.projectURL = package.url
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let scene = MotionScene(width: 320, height: 180, fps: 30, durationInFrames: 150)
            let created = try await editor.motionScenes.create(scene, name: "Scene", editor: editor)
            undo.removeAllActions()
            let asset = try #require(editor.mediaAssetsById[created.mediaRef])
            let originalURL = asset.url
            await #expect(throws: (any Error).self) {
                try await editor.motionScenes.createComponent(name: "Broken", source: "export default function Card() { return <div> }",
                    mediaRef: created.mediaRef, expectedRevision: created.revision, editor: editor)
            }
            await #expect(throws: (any Error).self) {
                try await editor.motionScenes.createComponent(name: " ", source: MotionComponentTemplate.card.source(runtime: .web),
                    mediaRef: created.mediaRef, expectedRevision: created.revision, editor: editor)
            }
            await #expect(throws: MotionSceneError.invalidField("scene revision conflict; read the current scene and retry")) {
                try await editor.motionScenes.createComponent(name: "Stale", source: MotionComponentTemplate.card.source(runtime: .web),
                    mediaRef: created.mediaRef, expectedRevision: "stale", editor: editor)
            }
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await editor.motionScenes.createComponent(name: "Cancelled", source: MotionComponentTemplate.card.source(runtime: .web),
                    mediaRef: created.mediaRef, expectedRevision: created.revision, editor: editor)
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(asset.url == originalURL)
            #expect(!undo.canUndo)
            let stored = try await MotionVideoGenerator.loadScene(at: asset.url)
            #expect(stored.components.isEmpty && stored.nodes.isEmpty)
            try await package.remove()
        } catch { try await package.remove(); throw error }
    }

    @Test @MainActor func openingCreationDoesNotCreateAnAsset() async throws {
        let editor = EditorViewModel()
        let session = MotionEditorSession(editor: editor, mediaRef: "new")
        await session.open()
        #expect(session.scene == nil)
        #expect(session.error == nil)
        #expect(editor.mediaAssets.isEmpty)
        session.close()
    }
}
