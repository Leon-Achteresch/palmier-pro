import Foundation

enum MotionSceneOperation: Codable, Sendable {
    case add([MotionNode])
    case values(ids: [String], values: [String: MotionValue], frame: Int?)
    case rename(id: String, name: String)
    case visibility(ids: [String], hidden: Bool)
    case lock(ids: [String], locked: Bool)
    case timing(ids: [String], startFrame: Int, durationFrames: Int)
    case remove(ids: [String])
    case duplicate(ids: [String])
    case group(ids: [String], name: String)
    case ungroup(id: String)
    case reorder(ids: [String])
    case track(id: String, track: MotionTrack)
    case removeTrack(id: String, binding: String)
    case removeKey(id: String, binding: String, keyID: String)
    case recipe(ids: [String], recipe: MotionRecipe, stagger: Int)
    case removeRecipe(id: String, recipeID: String)
    case fixture(ids: [String], name: String)
    case component(MotionComponent)
    case audioCue(MotionAudioCue)
    case removeAudioCue(id: String)
    case format(MotionFormat)
    case removeFormat(id: String)
    case applyFormat(id: String)
    case configure(width: Int, height: Int, fps: Double, duration: Int, background: String)
}

struct MotionSceneChange: Sendable {
    var scene: MotionScene
    var changedIDs: [String]
    var unchanged: Bool
}

enum MotionSceneOperations {
    static func apply(_ operations: [MotionSceneOperation], to original: MotionScene) throws -> MotionSceneChange {
        guard !operations.isEmpty, operations.count <= 256 else { throw MotionSceneError.invalidField("provide 1–256 scene operations") }
        var scene = try original.validated()
        var changedIDs: Set<String> = []
        for operation in operations { try apply(operation, to: &scene, changedIDs: &changedIDs) }
        scene = try scene.validated()
        let unchanged = scene == original
        if !unchanged {
            guard original.revision < Int.max - 1 else { throw MotionSceneError.invalidField("scene revision exhausted") }
            scene.revision = original.revision + 1
        }
        return MotionSceneChange(scene: scene, changedIDs: unchanged ? [] : changedIDs.sorted(), unchanged: unchanged)
    }

    private static func indices(_ ids: [String], in scene: MotionScene, allowLocked: Bool = false) throws -> [Int] {
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw MotionSceneError.invalidField("provide unique layer IDs") }
        let index = Dictionary(uniqueKeysWithValues: scene.nodes.enumerated().map { ($0.element.id, $0.offset) })
        return try ids.map { id in
            guard let position = index[id] else { throw MotionSceneError.invalidField("unknown layer '\(id)'") }
            if !allowLocked {
                var current: Int? = position
                while let i = current {
                    guard !scene.nodes[i].locked else { throw MotionSceneError.invalidField("layer '\(id)' is locked") }
                    current = scene.nodes[i].parentID.flatMap { index[$0] }
                }
            }
            return position
        }
    }

    private static func descendants(_ ids: [String], in scene: MotionScene) -> Set<String> {
        var all = Set(ids)
        var children: [String: [String]] = [:]
        for node in scene.nodes { if let parent = node.parentID { children[parent, default: []].append(node.id) } }
        var queue = ids
        while let id = queue.popLast() {
            for child in children[id, default: []] where all.insert(child).inserted { queue.append(child) }
        }
        return all
    }

    private static func apply(_ operation: MotionSceneOperation, to scene: inout MotionScene, changedIDs: inout Set<String>) throws {
        switch operation {
        case .add(let nodes):
            guard !nodes.isEmpty else { throw MotionSceneError.invalidField("no layers supplied") }
            for node in nodes { if let parent = node.parentID, !nodes.contains(where: { $0.id == parent }) { _ = try indices([parent], in: scene) } }
            scene.nodes.append(contentsOf: nodes)
            changedIDs.formUnion(nodes.map(\.id))
        case .values(let ids, let values, let frame):
            let targets = try indices(ids, in: scene)
            guard !values.isEmpty else { throw MotionSceneError.invalidField("no properties supplied") }
            for index in targets {
                let node = scene.nodes[index]
                let component = node.componentID.flatMap { id in scene.components.first { $0.id == id } }
                for (binding, value) in values {
                    try scene.validateBinding(binding, value: value, node: node, component: component, animating: frame != nil)
                    if let frame {
                        guard frame >= node.startFrame, frame < node.startFrame + node.durationFrames else {
                            throw MotionSceneError.invalidField("keyframe is outside layer '\(node.id)'")
                        }
                        putKey(binding: binding, frame: frame - node.startFrame, value: value, node: &scene.nodes[index])
                    } else if binding.hasPrefix("props.") {
                        let key = String(binding.dropFirst(6))
                        if (node.props[key] ?? component?.props.first(where: { $0.id == key })?.defaultValue) != value {
                            scene.nodes[index].props[key] = value
                        }
                    } else if binding.hasPrefix("slots.") {
                        putKey(binding: binding, frame: 0, value: value, node: &scene.nodes[index])
                    } else if let property = MotionProperty(rawValue: binding), node.value(property) != value {
                        scene.nodes[index].properties[binding] = value
                    }
                }
            }
            changedIDs.formUnion(ids)
        case .rename(let id, let name):
            let index = try indices([id], in: scene)[0]
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024 else { throw MotionSceneError.invalidField("invalid layer name") }
            scene.nodes[index].name = name
            changedIDs.insert(id)
        case .visibility(let ids, let hidden):
            for i in try indices(ids, in: scene) { scene.nodes[i].hidden = hidden }
            changedIDs.formUnion(ids)
        case .lock(let ids, let locked):
            for i in try indices(ids, in: scene, allowLocked: true) { scene.nodes[i].locked = locked }
            changedIDs.formUnion(ids)
        case .timing(let ids, let start, let duration):
            for i in try indices(ids, in: scene) { scene.nodes[i].startFrame = start; scene.nodes[i].durationFrames = duration }
            changedIDs.formUnion(ids)
        case .remove(let ids):
            let all = descendants(ids, in: scene)
            _ = try indices(Array(all), in: scene)
            scene.nodes.removeAll { all.contains($0.id) }
            for i in scene.formats.indices { scene.formats[i].overrides = scene.formats[i].overrides.filter { !all.contains($0.key) } }
            changedIDs.formUnion(all)
        case .duplicate(let ids):
            let all = descendants(ids, in: scene)
            _ = try indices(Array(all), in: scene)
            let mapping = Dictionary(uniqueKeysWithValues: all.map { ($0, UUID().uuidString) })
            let copies = scene.nodes.filter { all.contains($0.id) }.map { original -> MotionNode in
                var node = original
                node.id = mapping[original.id]!
                node.parentID = original.parentID.map { mapping[$0] ?? $0 }
                node.tracks = node.tracks.map { original in
                    var track = original; track.id = UUID().uuidString
                    track.keys = track.keys.map { original in var key = original; key.id = UUID().uuidString; return key }
                    return track
                }
                node.recipes = node.recipes.map { original in var recipe = original; recipe.id = UUID().uuidString; return recipe }
                return node
            }
            scene.nodes.append(contentsOf: copies)
            for i in scene.formats.indices {
                for (oldID, newID) in mapping { scene.formats[i].overrides[newID] = scene.formats[i].overrides[oldID] }
            }
            changedIDs.formUnion(copies.map(\.id))
        case .group(let ids, let name):
            let targets = try indices(ids, in: scene)
            let parent = scene.nodes[targets[0]].parentID
            guard targets.allSatisfy({ scene.nodes[$0].parentID == parent && scene.nodes[$0].kind != .camera }) else {
                throw MotionSceneError.invalidField("group layers with the same parent")
            }
            let siblings = scene.nodes.filter { $0.parentID == parent }.map(\.id)
            let selectedPositions = siblings.enumerated().filter { ids.contains($0.element) }.map(\.offset)
            guard selectedPositions.last! - selectedPositions.first! + 1 == ids.count else {
                throw MotionSceneError.invalidField("group adjacent layers to preserve stacking order")
            }
            let group = MotionNode(name: name, kind: .group, parentID: parent, durationFrames: scene.durationInFrames,
                                   properties: ["width": .number(Double(scene.width)), "height": .number(Double(scene.height))])
            for i in targets { scene.nodes[i].parentID = group.id }
            scene.nodes.insert(group, at: targets.min()!)
            changedIDs.formUnion(ids + [group.id])
        case .ungroup(let id):
            let index = try indices([id], in: scene)[0]
            let group = scene.nodes[index]
            guard group.kind == .group, group.tracks.isEmpty, group.recipes.isEmpty, !group.hidden,
                  group.startFrame == 0, group.durationFrames == scene.durationInFrames,
                  [.x, .y, .rotation, .scaleX, .scaleY, .opacity, .blur, .mask, .reveal].allSatisfy({ group.value($0) == $0.defaultValue }) else {
                throw MotionSceneError.invalidField("ungroup requires an unanimated identity group")
            }
            let children = scene.nodes.filter { $0.parentID == id }.map(\.id)
            _ = children.isEmpty ? [] : try indices(children, in: scene)
            for i in scene.nodes.indices where scene.nodes[i].parentID == id { scene.nodes[i].parentID = group.parentID }
            scene.nodes.remove(at: index)
            for i in scene.formats.indices { scene.formats[i].overrides.removeValue(forKey: id) }
            changedIDs.formUnion(children + [id])
        case .reorder(let ids):
            _ = try indices(ids, in: scene)
            guard ids.count == scene.nodes.count else { throw MotionSceneError.invalidField("reorder requires every layer ID") }
            let nodes = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0) })
            scene.nodes = ids.map { nodes[$0]! }
            changedIDs.formUnion(ids)
        case .track(let id, let track):
            let i = try indices([id], in: scene)[0]
            if let t = scene.nodes[i].tracks.firstIndex(where: { $0.binding == track.binding }) {
                let previous = scene.nodes[i].tracks[t]
                var replacement = track
                replacement.id = previous.id
                let previousIDs = Set(previous.keys.map(\.id))
                let keysByFrame = Dictionary(uniqueKeysWithValues: previous.keys.map { ($0.frame, $0.id) })
                for k in replacement.keys.indices where !previousIDs.contains(replacement.keys[k].id) {
                    if let id = keysByFrame[replacement.keys[k].frame] { replacement.keys[k].id = id }
                }
                scene.nodes[i].tracks[t] = replacement
            } else { scene.nodes[i].tracks.append(track) }
            changedIDs.insert(id)
        case .removeTrack(let id, let binding):
            let i = try indices([id], in: scene)[0]
            scene.nodes[i].tracks.removeAll { $0.binding == binding }
            changedIDs.insert(id)
        case .removeKey(let id, let binding, let keyID):
            let i = try indices([id], in: scene)[0]
            guard let t = scene.nodes[i].tracks.firstIndex(where: { $0.binding == binding }) else { return }
            scene.nodes[i].tracks[t].keys.removeAll { $0.id == keyID }
            scene.nodes[i].tracks.removeAll { $0.keys.isEmpty }
            changedIDs.insert(id)
        case .recipe(let ids, let recipe, let stagger):
            guard (0...36000).contains(stagger), (0...36000).contains(recipe.startFrame) else { throw MotionSceneError.invalidField("invalid stagger or recipe start") }
            for (offset, i) in try indices(ids, in: scene).enumerated() {
                var instance = recipe
                instance.startFrame = recipe.startFrame - scene.nodes[i].startFrame + offset * stagger
                instance.id = ids.count == 1 ? recipe.id : UUID().uuidString
                if let r = scene.nodes[i].recipes.firstIndex(where: { $0.id == instance.id }) { scene.nodes[i].recipes[r] = instance }
                else { scene.nodes[i].recipes.append(instance) }
            }
            changedIDs.formUnion(ids)
        case .removeRecipe(let id, let recipeID):
            let i = try indices([id], in: scene)[0]
            scene.nodes[i].recipes.removeAll { $0.id == recipeID }
            changedIDs.insert(id)
        case .fixture(let ids, let name):
            for i in try indices(ids, in: scene) {
                guard let component = scene.components.first(where: { $0.id == scene.nodes[i].componentID }),
                      let values = component.fixtures[name] else { throw MotionSceneError.invalidField("unknown component fixture '\(name)'") }
                scene.nodes[i].props.merge(values) { _, new in new }
            }
            changedIDs.formUnion(ids)
        case .component(let component):
            if let i = scene.components.firstIndex(where: { $0.id == component.id }) { scene.components[i] = component }
            else { scene.components.append(component) }
            changedIDs.insert(component.id)
        case .audioCue(let cue):
            if let i = scene.audioCues.firstIndex(where: { $0.id == cue.id }) { scene.audioCues[i] = cue }
            else { scene.audioCues.append(cue) }
            changedIDs.insert(cue.id)
        case .removeAudioCue(let id): scene.audioCues.removeAll { $0.id == id }; changedIDs.insert(id)
        case .format(let format):
            if let i = scene.formats.firstIndex(where: { $0.id == format.id }) { scene.formats[i] = format }
            else { scene.formats.append(format) }
            changedIDs.insert(format.id)
        case .removeFormat(let id): scene.formats.removeAll { $0.id == id }; changedIDs.insert(id)
        case .applyFormat(let id):
            guard let format = scene.formats.first(where: { $0.id == id }) else { throw MotionSceneError.invalidField("unknown format") }
            for (nodeID, values) in format.overrides {
                try apply(.values(ids: [nodeID], values: values, frame: nil), to: &scene, changedIDs: &changedIDs)
            }
            scene.width = format.width; scene.height = format.height
            changedIDs.insert(scene.id)
        case .configure(let width, let height, let fps, let duration, let background):
            scene.width = width; scene.height = height; scene.fps = fps; scene.durationInFrames = duration; scene.background = background
            changedIDs.insert(scene.id)
        }
    }

    private static func putKey(binding: String, frame: Int, value: MotionValue, node: inout MotionNode) {
        if let index = node.tracks.firstIndex(where: { $0.binding == binding }) {
            if let key = node.tracks[index].keys.firstIndex(where: { $0.frame == frame }) {
                node.tracks[index].keys[key].value = value
            } else {
                node.tracks[index].keys.append(MotionKey(frame: frame, value: value))
                node.tracks[index].keys.sort { $0.frame < $1.frame }
            }
        } else { node.tracks.append(MotionTrack(binding: binding, keys: [MotionKey(frame: frame, value: value)])) }
    }
}


extension MotionScene {
    func makeLayer(kind: MotionNode.Kind, name: String, componentID: String? = nil) -> MotionNode {
        let width = kind == .group || kind == .camera ? Double(self.width) : 320
        let height = kind == .group || kind == .camera ? Double(self.height) : 180
        return MotionNode(name: name, kind: kind, componentID: componentID, durationFrames: durationInFrames,
                          properties: ["width": .number(width), "height": .number(height),
                                       "x": .number((Double(self.width) - width) / 2), "y": .number((Double(self.height) - height) / 2)])
    }
}
