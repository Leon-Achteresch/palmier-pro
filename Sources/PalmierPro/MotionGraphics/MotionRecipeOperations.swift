import Foundation

extension MotionRecipe.Kind {
    var bindings: [String] {
        switch self {
        case .slideUp: ["y", "opacity"]
        case .slideLeft: ["x", "opacity"]
        case .pop: ["scaleX", "scaleY", "opacity"]
        case .fadeIn, .fadeOut: ["opacity"]
        case .float: ["y"]
        case .pulse: ["scaleX", "scaleY"]
        case .spin: ["rotation"]
        case .typewriter: ["text"]
        case .textStagger: ["textProgress"]
        }
    }
}

enum MotionRecipeOperations {
    @concurrent static func expand(scene: MotionScene, nodeID: String, recipeID: String) async throws -> [MotionSceneOperation] {
        _ = try scene.validated()
        guard let index = scene.nodes.firstIndex(where: { $0.id == nodeID }),
              let recipe = scene.nodes[index].recipes.first(where: { $0.id == recipeID }) else {
            throw MotionSceneError.invalidField("unknown recipe")
        }
        let node = scene.nodes[index]
        let bindings = recipe.kind.bindings
        guard node.recipes.filter({ $0.id != recipeID }).allSatisfy({ Set($0.kind.bindings).isDisjoint(with: bindings) }) else {
            throw MotionSceneError.invalidField("expand overlapping recipes together or remove their shared bindings first")
        }
        var isolated = scene
        isolated.nodes[index].recipes = [recipe]
        let revision = UUID().uuidString
        var keys = Dictionary(uniqueKeysWithValues: bindings.map { ($0, [MotionKey]()) })
        for frame in 0..<node.durationFrames {
            try Task.checkCancellation()
            let result = try await MotionFrameEvaluator.shared.evaluate(isolated, key: revision, frame: frame + node.startFrame)
            guard let state = result.nodes.first(where: { $0.id == nodeID }) else { throw MotionSceneError.sceneFailed("missing evaluated layer") }
            for binding in bindings {
                guard let value = state.properties[binding] else { throw MotionSceneError.sceneFailed("missing recipe property") }
                keys[binding]!.append(MotionKey(frame: frame, value: value, easing: .init(kind: .linear)))
            }
        }
        return [.removeRecipe(id: nodeID, recipeID: recipeID)] + bindings.map { .track(id: nodeID, track: MotionTrack(binding: $0, keys: keys[$0]!)) }
    }
}
