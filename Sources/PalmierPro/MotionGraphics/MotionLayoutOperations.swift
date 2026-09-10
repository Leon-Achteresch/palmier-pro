import Foundation

enum MotionAlignment: String, Codable, CaseIterable, Sendable { case left, center, right, top, middle, bottom }

enum MotionLayoutOperations {
    static let gridStep: Double = 8

    @concurrent static func translateSlot(scene: MotionScene, revision: String, frame: Int, slot: MotionSlotBounds,
                                         dx: Double, dy: Double, autoKey: Bool) async throws -> [MotionSceneOperation] {
        guard dx.isFinite, dy.isFinite, abs(dx) <= 65536, abs(dy) <= 65536 else { throw MotionSceneError.invalidField("invalid slot translation") }
        let result = try await MotionFrameEvaluator.shared.evaluate(scene, key: revision, frame: frame)
        let state = try requiredState(slot.nodeID, states: Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) }))
        guard let node = scene.nodes.first(where: { $0.id == slot.nodeID }) else { throw MotionSceneError.invalidField("unknown slot owner") }
        let inverse = try await MotionFrameEvaluator.shared.inverse(slot.parentMatrix)
        let deltas = ["x": inverse[0] * dx + inverse[2] * dy, "y": inverse[1] * dx + inverse[3] * dy]
        return deltas.sorted(by: { $0.key < $1.key }).map { property, delta in
            let binding = "slots.\(slot.slotID).\(property)"
            if !autoKey, var track = node.tracks.first(where: { $0.binding == binding }) {
                for index in track.keys.indices { track.keys[index].value = .number((track.keys[index].value.number ?? 0) + delta) }
                return .track(id: node.id, track: track)
            }
            return .values(ids: [node.id], values: [binding: .number((state.slots[slot.slotID]?[property]?.number ?? 0) + delta)], frame: autoKey ? frame : nil)
        }
    }

    @concurrent static func transform(scene: MotionScene, revision: String, frame: Int, id: String,
                                     dx: Double, dy: Double, rotating: Bool, autoKey: Bool) async throws -> [MotionSceneOperation] {
        guard dx.isFinite, dy.isFinite, abs(dx) <= 65536, abs(dy) <= 65536 else { throw MotionSceneError.invalidField("invalid transform") }
        let evaluated = try await MotionFrameEvaluator.shared.evaluate(scene, key: revision, frame: frame)
        let state = try requiredState(id, states: Dictionary(uniqueKeysWithValues: evaluated.nodes.map { ($0.id, $0) }))
        guard let node = scene.nodes.first(where: { $0.id == id }) else { throw MotionSceneError.invalidField("unknown layer") }
        guard let inverse = state.inverseParentMatrix else { throw MotionSceneError.invalidField("cannot transform a layer inside a zero-scale group") }
        let anchorX = (state.properties["width"]?.number ?? 0) * (state.properties["anchorX"]?.number ?? 0.5)
        let anchorY = (state.properties["height"]?.number ?? 0) * (state.properties["anchorY"]?.number ?? 0.5)
        let matrix = state.worldMatrix
        let pivotX = matrix[0] * anchorX + matrix[2] * anchorY + matrix[4]
        let pivotY = matrix[1] * anchorX + matrix[3] * anchorY + matrix[5]
        let handleX = state.bounds.x + state.bounds.width - pivotX
        let handleY = state.bounds.y + (rotating ? 0 : state.bounds.height) - pivotY
        let startX = inverse[0] * handleX + inverse[2] * handleY
        let startY = inverse[1] * handleX + inverse[3] * handleY
        let endX = startX + inverse[0] * dx + inverse[2] * dy
        let endY = startY + inverse[1] * dx + inverse[3] * dy
        let lengthSquared = startX * startX + startY * startY
        guard lengthSquared > 0.000001 else { throw MotionSceneError.invalidField("transform handle coincides with the layer anchor") }
        let bindings: [String]
        let adjustment: Double
        if rotating {
            bindings = ["rotation"]
            adjustment = atan2(startX * endY - startY * endX, startX * endX + startY * endY) * 180 / .pi
        } else {
            bindings = ["scaleX", "scaleY"]
            adjustment = max(0.01, (endX * startX + endY * startY) / lengthSquared)
        }
        func adjusted(_ value: Double) -> Double { rotating ? value + adjustment : value * adjustment }
        var values: [String: MotionValue] = [:]
        var operations: [MotionSceneOperation] = []
        for binding in bindings {
            let base = autoKey ? state.animatedProperties[binding] : node.value(MotionProperty(rawValue: binding)!)
            values[binding] = .number(adjusted(base?.number ?? (rotating ? 0 : 1)))
            if !autoKey, var track = node.tracks.first(where: { $0.binding == binding }) {
                for i in track.keys.indices { track.keys[i].value = .number(adjusted(track.keys[i].value.number!)) }
                operations.append(.track(id: id, track: track))
            }
        }
        operations.insert(.values(ids: [id], values: values, frame: autoKey ? frame : nil), at: 0)
        return operations
    }

    @concurrent static func translate(
        scene: MotionScene, revision: String, frame: Int, ids: [String], dx: Double, dy: Double, snap: Bool, autoKey: Bool
    ) async throws -> [MotionSceneOperation] {
        guard dx.isFinite, dy.isFinite, abs(dx) <= 65536, abs(dy) <= 65536 else { throw MotionSceneError.invalidField("invalid translation") }
        let evaluated = try await MotionFrameEvaluator.shared.evaluate(scene, key: revision, frame: frame)
        let roots = try rootSelection(ids, scene: scene)
        let states = Dictionary(uniqueKeysWithValues: evaluated.nodes.map { ($0.id, $0) })
        let first = try requiredState(roots[0], states: states)
        let deltaX = snap ? ((first.bounds.x + dx) / gridStep).rounded() * gridStep - first.bounds.x : dx
        let deltaY = snap ? ((first.bounds.y + dy) / gridStep).rounded() * gridStep - first.bounds.y : dy
        return try roots.flatMap { id in
            let state = try requiredState(id, states: states)
            guard let inverse = state.inverseParentMatrix else { throw MotionSceneError.invalidField("cannot move a layer inside a zero-scale group") }
            return try offset(id: id, dx: inverse[0] * deltaX + inverse[2] * deltaY,
                              dy: inverse[1] * deltaX + inverse[3] * deltaY, scene: scene, state: state, frame: frame, autoKey: autoKey)
        }
    }

    @concurrent static func align(
        scene: MotionScene, revision: String, frame: Int, ids: [String], alignment: MotionAlignment, autoKey: Bool
    ) async throws -> [MotionSceneOperation] {
        let roots = try rootSelection(ids, scene: scene)
        let evaluated = try await MotionFrameEvaluator.shared.evaluate(scene, key: revision, frame: frame)
        let states = Dictionary(uniqueKeysWithValues: evaluated.nodes.map { ($0.id, $0) })
        let selected = try roots.map { try requiredState($0, states: states) }
        let target = selected.count == 1 ? CGRect(x: 0, y: 0, width: scene.width, height: scene.height)
            : selected.dropFirst().reduce(selected[0].bounds.rect) { $0.union($1.bounds.rect) }
        return try selected.flatMap { state in
            let bounds = state.bounds.rect
            let dx: Double
            let dy: Double
            switch alignment {
            case .left: dx = target.minX - bounds.minX; dy = 0
            case .center: dx = target.midX - bounds.midX; dy = 0
            case .right: dx = target.maxX - bounds.maxX; dy = 0
            case .top: dx = 0; dy = target.minY - bounds.minY
            case .middle: dx = 0; dy = target.midY - bounds.midY
            case .bottom: dx = 0; dy = target.maxY - bounds.maxY
            }
            guard let inverse = state.inverseParentMatrix else { throw MotionSceneError.invalidField("cannot align a layer inside a zero-scale group") }
            return try offset(id: state.id, dx: inverse[0] * dx + inverse[2] * dy, dy: inverse[1] * dx + inverse[3] * dy,
                              scene: scene, state: state, frame: frame, autoKey: autoKey)
        }
    }

    private static func requiredState(_ id: String, states: [String: MotionEvaluatedNode]) throws -> MotionEvaluatedNode {
        guard let state = states[id], state.active, !state.locked else { throw MotionSceneError.invalidField("layer '\(id)' is unavailable or locked at this frame") }
        return state
    }

    private static func rootSelection(_ ids: [String], scene: MotionScene) throws -> [String] {
        try MotionScene.uniqueIDs(ids)
        guard !ids.isEmpty else { throw MotionSceneError.invalidField("select at least one layer") }
        let nodes = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0) })
        let selection = Set(ids)
        return try ids.filter { id in
            guard let node = nodes[id] else { throw MotionSceneError.invalidField("unknown layer '\(id)'") }
            var ancestor = node.parentID
            while let parent = ancestor {
                if selection.contains(parent) { return false }
                ancestor = nodes[parent]?.parentID
            }
            return true
        }
    }

    private static func offset(id: String, dx: Double, dy: Double, scene: MotionScene, state: MotionEvaluatedNode,
                               frame: Int, autoKey: Bool) throws -> [MotionSceneOperation] {
        guard let node = scene.nodes.first(where: { $0.id == id }) else { throw MotionSceneError.invalidField("unknown layer") }
        if autoKey {
            return [.values(ids: [id], values: ["x": .number((state.animatedProperties["x"]?.number ?? 0) + dx),
                                               "y": .number((state.animatedProperties["y"]?.number ?? 0) + dy)], frame: frame)]
        }
        var operations: [MotionSceneOperation] = [.values(ids: [id], values: ["x": .number((node.value(.x).number ?? 0) + dx),
                                                                           "y": .number((node.value(.y).number ?? 0) + dy)], frame: nil)]
        for track in node.tracks where track.binding == "x" || track.binding == "y" {
            var updated = track
            for i in updated.keys.indices {
                guard let number = updated.keys[i].value.number else { throw MotionSceneError.invalidField("position track must be numeric") }
                updated.keys[i].value = .number(number + (track.binding == "x" ? dx : dy))
            }
            operations.append(.track(id: id, track: updated))
        }
        return operations
    }
}
