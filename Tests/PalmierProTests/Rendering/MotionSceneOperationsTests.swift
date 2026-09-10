import Foundation
import Testing
@testable import PalmierPro

@Suite("Structured motion scene operations")
struct MotionSceneOperationsTests {
    private func scene() -> MotionScene {
        var scene = MotionScene(width: 1920, height: 1080, fps: 30, durationInFrames: 300)
        scene.nodes = [MotionNode(id: "a", name: "A", kind: .shape, durationFrames: 300),
                       MotionNode(id: "b", name: "B", kind: .shape, durationFrames: 300)]
        return scene
    }

    @Test func defaultValueEditIsANoOp() throws {
        let original = scene()
        let result = try MotionSceneOperations.apply([.values(ids: ["a"], values: ["x": .number(0)], frame: nil)], to: original)
        #expect(result.unchanged)
        #expect(result.scene == original)
        #expect(result.changedIDs.isEmpty)
    }

    @Test func invalidBatchLeavesOriginalIntact() {
        let original = scene()
        #expect(throws: MotionSceneError.self) {
            try MotionSceneOperations.apply([.values(ids: ["a"], values: ["x": .number(100)], frame: nil),
                                             .values(ids: ["missing"], values: ["x": .number(20)], frame: nil)], to: original)
        }
        #expect(original.nodes[0].value(.x) == .number(0))
    }

    @Test func keyUpdatesPreserveIdentityAndUseLayerRelativeFrames() throws {
        var original = scene()
        original.nodes[0].startFrame = 50
        original.nodes[0].durationFrames = 200
        let first = try MotionSceneOperations.apply([.values(ids: ["a"], values: ["x": .number(100)], frame: 60)], to: original).scene
        let second = try MotionSceneOperations.apply([.values(ids: ["a"], values: ["x": .number(120)], frame: 60)], to: first).scene
        #expect(second.nodes[0].tracks[0].keys.count == 1)
        #expect(second.nodes[0].tracks[0].keys[0].frame == 10)
        #expect(second.nodes[0].tracks[0].keys[0].id == first.nodes[0].tracks[0].keys[0].id)
        #expect(second.revision == 2)
    }

    @Test func groupingAndUngroupingRestoreLayerStructure() throws {
        let original = scene()
        let grouped = try MotionSceneOperations.apply([.group(ids: ["a", "b"], name: "Cards")], to: original).scene
        let group = try #require(grouped.nodes.first { $0.kind == .group })
        #expect(grouped.nodes.filter { $0.parentID == group.id }.count == 2)
        let ungrouped = try MotionSceneOperations.apply([.ungroup(id: group.id)], to: grouped).scene
        #expect(ungrouped.nodes == original.nodes)
    }

    @Test func lockedAncestorsPreventChildMutation() throws {
        var grouped = try MotionSceneOperations.apply([.group(ids: ["a", "b"], name: "Cards")], to: scene()).scene
        grouped.nodes[0].locked = true
        #expect(throws: MotionSceneError.self) {
            try MotionSceneOperations.apply([.values(ids: ["a"], values: ["x": .number(1)], frame: nil)], to: grouped)
        }
    }

    @Test func staggerUsesRequestedOrderAndRejectsOutOfBoundsAtomically() throws {
        let original = scene()
        let recipe = MotionRecipe(kind: .slideUp, durationFrames: 18)
        let result = try MotionSceneOperations.apply([.recipe(ids: ["b", "a"], recipe: recipe, stagger: 4)], to: original)
        #expect(result.scene.nodes[0].recipes[0].startFrame == 4)
        #expect(result.scene.nodes[1].recipes[0].startFrame == 0)
        #expect(throws: MotionSceneError.self) {
            try MotionSceneOperations.apply([.recipe(ids: ["a", "b"], recipe: recipe, stagger: 299)], to: original)
        }
    }

    @Test(arguments: [Int.min, Int.max, -1, 36001])
    func unsafeRecipeFrameIsRejectedBeforeArithmetic(frame: Int) {
        let recipe = MotionRecipe(kind: .slideUp, startFrame: frame)
        #expect(throws: MotionSceneError.self) {
            try MotionSceneOperations.apply([.recipe(ids: ["a", "b"], recipe: recipe, stagger: 4)], to: scene())
        }
    }

    @Test func componentUpdateCannotOrphanAnAnimatedProp() throws {
        var original = scene()
        original.components = [MotionComponent(id: "card", name: "Card", source: "export default () => null",
            props: [MotionPropSchema(id: "price", label: "Price", kind: .number, defaultValue: .number(10))])]
        original.nodes[0].kind = .component
        original.nodes[0].componentID = "card"
        original.nodes[0].tracks = [MotionTrack(binding: "props.price", keys: [MotionKey(frame: 0, value: .number(5))])]
        let replacement = MotionComponent(id: "card", name: "Card", source: "export default () => null")
        #expect(throws: MotionSceneError.self) { try MotionSceneOperations.apply([.component(replacement)], to: original) }
    }

    @Test func duplicateRegeneratesChildAndAnimationIDs() throws {
        let grouped = try MotionSceneOperations.apply([.group(ids: ["a", "b"], name: "Cards")], to: scene()).scene
        let group = try #require(grouped.nodes.first { $0.kind == .group })
        let copied = try MotionSceneOperations.apply([.duplicate(ids: [group.id])], to: grouped).scene
        #expect(copied.nodes.count == 6)
        #expect(Set(copied.nodes.map(\.id)).count == 6)
        #expect(copied.nodes[4].parentID == copied.nodes[3].id)
    }

    @Test func cyclicHierarchyIsRejected() {
        var invalid = scene()
        invalid.nodes[0].kind = .group
        invalid.nodes[1].kind = .group
        invalid.nodes[0].parentID = "b"
        invalid.nodes[1].parentID = "a"
        #expect(throws: MotionSceneError.self) { try invalid.validated() }
    }
}
