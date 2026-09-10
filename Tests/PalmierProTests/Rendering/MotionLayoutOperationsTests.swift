import Foundation
import Testing
@testable import PalmierPro

@Suite("Motion stage transforms")
struct MotionLayoutOperationsTests {
    private func scene() -> MotionScene {
        var scene = MotionScene(width: 800, height: 600, fps: 30, durationInFrames: 60)
        var parent = MotionNode(id: "parent", name: "Parent", kind: .group, durationFrames: 60)
        parent.properties = ["scaleX": .number(2), "scaleY": .number(0.5), "rotation": .number(30)]
        var child = MotionNode(id: "child", name: "Child", kind: .shape, durationFrames: 60)
        child.parentID = parent.id
        child.properties = ["width": .number(100), "height": .number(80), "anchorX": .number(0), "anchorY": .number(0)]
        scene.nodes = [parent, child]
        return scene
    }

    @Test func rotationUsesTheAnchorInsideANonuniformParent() async throws {
        let scene = scene()
        let key = UUID().uuidString
        let evaluated = try await MotionFrameEvaluator.shared.evaluate(scene, key: key, frame: 0)
        let state = try #require(evaluated.nodes.first { $0.id == "child" })
        let matrix = state.worldMatrix
        let inverse = try #require(state.inverseParentMatrix)
        let x = state.bounds.x + state.bounds.width - matrix[4]
        let y = state.bounds.y - matrix[5]
        let localX = inverse[0] * x + inverse[2] * y
        let localY = inverse[1] * x + inverse[3] * y
        let endX = matrix[0] * -localY + matrix[2] * localX
        let endY = matrix[1] * -localY + matrix[3] * localX
        let operations = try await MotionLayoutOperations.transform(scene: scene, revision: key, frame: 0, id: "child",
            dx: endX - x, dy: endY - y, rotating: true, autoKey: false)
        let result = try MotionSceneOperations.apply(operations, to: scene).scene
        #expect(abs((result.nodes[1].value(.rotation).number ?? 0) - 90) < 0.000001)
    }

    @Test func scalingUsesTheActualAnchorAndWritesOnlyTheActiveKey() async throws {
        let scene = scene()
        let key = UUID().uuidString
        let evaluated = try await MotionFrameEvaluator.shared.evaluate(scene, key: key, frame: 20)
        let state = try #require(evaluated.nodes.first { $0.id == "child" })
        let operations = try await MotionLayoutOperations.transform(scene: scene, revision: key, frame: 20, id: "child",
            dx: state.bounds.x + state.bounds.width - state.worldMatrix[4],
            dy: state.bounds.y + state.bounds.height - state.worldMatrix[5], rotating: false, autoKey: true)
        let result = try MotionSceneOperations.apply(operations, to: scene).scene.nodes[1]
        #expect(result.value(.scaleX) == .number(1))
        #expect(result.tracks.count == 2)
        for track in result.tracks {
            #expect(track.keys.count == 1)
            #expect(track.keys[0].frame == 20)
            #expect(abs((track.keys[0].value.number ?? 0) - 2) < 0.000001)
        }
    }

    @Test func movingAParentAndChildDoesNotTranslateTheChildTwice() async throws {
        let scene = scene()
        let operations = try await MotionLayoutOperations.translate(scene: scene, revision: UUID().uuidString, frame: 0,
            ids: ["parent", "child"], dx: 40, dy: 20, snap: false, autoKey: false)
        let result = try MotionSceneOperations.apply(operations, to: scene).scene
        #expect(result.nodes[0].value(.x) == .number(40))
        #expect(result.nodes[0].value(.y) == .number(20))
        #expect(result.nodes[1] == scene.nodes[1])
    }

    @Test func movingASlotConvertsThroughItsMeasuredParent() async throws {
        var scene = scene()
        scene.components = [MotionComponent(id: "card", name: "Card", source: "export default () => null", slots: ["title"])]
        scene.nodes[1].kind = .component
        scene.nodes[1].componentID = "card"
        let slot = MotionSlotBounds(nodeID: "child", slotID: "title", bounds: .init(x: 0, y: 0, width: 100, height: 20),
                                    parentMatrix: [0, 2, -3, 0, 0, 0])
        let operations = try await MotionLayoutOperations.translateSlot(scene: scene, revision: UUID().uuidString, frame: 10,
            slot: slot, dx: 30, dy: 20, autoKey: true)
        let result = try MotionSceneOperations.apply(operations, to: scene).scene.nodes[1]
        #expect(result.tracks.first { $0.binding == "slots.title.x" }?.keys[0].value == .number(10))
        #expect(result.tracks.first { $0.binding == "slots.title.y" }?.keys[0].value == .number(-10))
    }
}
