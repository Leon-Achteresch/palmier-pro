import Foundation

extension MotionScene {
    func validated() throws -> MotionScene {
        guard version == Self.currentVersion else { throw MotionSceneError.unsupportedVersion(version) }
        guard Self.validID(id), revision >= 0, revision < Int.max,
              Self.dimensionRange.contains(width), Self.dimensionRange.contains(height),
              fps.isFinite, Self.fpsRange.contains(fps), Self.frameCountRange.contains(durationInFrames),
              MotionProperty.isColor(background), components.count <= 128, nodes.count <= 1000,
              audioCues.count <= 256, sounds.count <= 32, formats.count <= 32 else {
            throw MotionSceneError.invalidField("invalid scene identity, dimensions, timing, or capacity")
        }
        try Self.uniqueIDs(components.map(\.id))
        try Self.uniqueIDs(nodes.map(\.id))
        try Self.uniqueIDs(audioCues.map(\.id))
        try Self.uniqueIDs(formats.map(\.id))
        let componentMap = Dictionary(uniqueKeysWithValues: components.map { ($0.id, $0) })
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for component in components { try validate(component) }
        guard nodes.filter({ $0.kind == .camera }).count <= 1 else { throw MotionSceneError.invalidField("only one camera is allowed") }
        for node in nodes {
            guard !node.name.isEmpty, node.name.utf8.count <= 1024, (0..<durationInFrames).contains(node.startFrame), node.durationFrames > 0,
                  node.durationFrames <= durationInFrames - node.startFrame, node.tracks.count <= 128, node.recipes.count <= 64
            else { throw MotionSceneError.invalidField("invalid timing or track capacity for '\(node.id)'") }
            if let parentID = node.parentID {
                guard nodeMap[parentID]?.kind == .group, node.kind != .camera else { throw MotionSceneError.invalidField("parent must be a group") }
                var seen: Set<String> = [node.id]
                var ancestor: String? = parentID
                while let current = ancestor {
                    guard seen.insert(current).inserted, seen.count <= 32 else { throw MotionSceneError.invalidField("cyclic or excessively deep scene hierarchy") }
                    ancestor = nodeMap[current]?.parentID
                }
            }
            let component = node.componentID.flatMap { componentMap[$0] }
            guard (node.kind == .component) == (component != nil), node.kind == .component || node.componentID == nil else {
                throw MotionSceneError.invalidField("invalid component reference for '\(node.id)'")
            }
            for (key, value) in node.properties {
                guard let property = MotionProperty(rawValue: key) else { throw MotionSceneError.invalidField("unknown property '\(key)'") }
                try property.validate(value)
            }
            for (key, value) in node.props {
                guard let schema = component?.props.first(where: { $0.id == key }) else { throw MotionSceneError.invalidField("unknown component prop '\(key)'") }
                try schema.validate(value)
            }
            try Self.uniqueIDs(node.tracks.map(\.id))
            try Self.uniqueIDs(node.recipes.map(\.id))
            guard Set(node.tracks.map(\.binding)).count == node.tracks.count else { throw MotionSceneError.invalidField("duplicate animation binding") }
            for track in node.tracks { try validate(track, node: node, component: component) }
            for recipe in node.recipes {
                try recipe.easing.validated()
                guard recipe.amount.isFinite, (-10000...10000).contains(recipe.amount),
                      recipe.startFrame >= 0, recipe.startFrame < node.durationFrames,
                      recipe.durationFrames > 0, recipe.durationFrames <= node.durationFrames - recipe.startFrame,
                      (1...1000).contains(recipe.repeatCount), (0...36000).contains(recipe.gapFrames),
                      recipe.kind != .typewriter && recipe.kind != .textStagger || node.kind == .text else {
                    throw MotionSceneError.invalidField("invalid animation recipe")
                }
                try validateRepeat(start: recipe.startFrame, duration: recipe.durationFrames, count: recipe.repeatCount,
                                   gap: recipe.gapFrames, limit: node.durationFrames)
            }
        }
        for (id, sound) in sounds {
            guard Self.validID(id), !sound.name.isEmpty, sound.name.utf8.count <= 1024,
                  !sound.fileExtension.isEmpty, sound.fileExtension.count <= 16, sound.fileExtension.allSatisfy({ $0.isLetter || $0.isNumber }),
                  !sound.data.isEmpty, sound.data.count <= 20 * 1024 * 1024, sound.duration.isFinite, sound.duration > 0 else {
                throw MotionSceneError.invalidField("invalid pinned sound source")
            }
        }
        for cue in audioCues {
            guard Self.validID(cue.mediaRef), (0..<durationInFrames).contains(cue.frame), cue.trimStartFrame >= 0,
                  cue.trimStartFrame <= 36_000_000, cue.durationFrames > 0, cue.durationFrames <= durationInFrames - cue.frame,
                  cue.volumeDB.isFinite, (-96...12).contains(cue.volumeDB) else { throw MotionSceneError.invalidField("invalid audio cue") }
            guard let source = sounds[cue.mediaRef], Double(cue.trimStartFrame + cue.durationFrames) / fps <= source.duration + 0.000001 else {
                throw MotionSceneError.invalidField("audio cue exceeds its pinned source")
            }
        }
        var events: [(frame: Int, delta: Int)] = []
        for cue in audioCues {
            events.append((cue.frame, 1))
            events.append((cue.frame + cue.durationFrames, -1))
        }
        events.sort { left, right in left.frame == right.frame ? left.delta < right.delta : left.frame < right.frame }
        var simultaneous = 0
        for event in events {
            simultaneous += event.delta
            guard simultaneous <= 8 else { throw MotionSceneError.invalidField("at most eight sounds may overlap") }
        }
        for format in formats {
            guard !format.name.isEmpty, format.name.utf8.count <= 1024, Self.dimensionRange.contains(format.width), Self.dimensionRange.contains(format.height) else {
                throw MotionSceneError.invalidField("invalid format dimensions")
            }
            for (nodeID, values) in format.overrides {
                guard nodeMap[nodeID] != nil else { throw MotionSceneError.invalidField("format refers to missing layer") }
                for (key, value) in values {
                    guard let property = MotionProperty(rawValue: key) else { throw MotionSceneError.invalidField("unknown format property") }
                    try property.validate(value)
                }
            }
        }
        return self
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_:-.".unicodeScalars.contains($0)
        } && MotionValue.isSafeKey(id)
    }

    static func uniqueIDs(_ ids: [String]) throws {
        guard ids.allSatisfy(validID), Set(ids).count == ids.count else { throw MotionSceneError.invalidField("invalid or duplicate IDs") }
    }

    func validateBinding(_ binding: String, value: MotionValue, node: MotionNode, component: MotionComponent?, animating: Bool = true) throws {
        if let property = MotionProperty(rawValue: binding) { try property.validate(value); return }
        if binding.hasPrefix("props."), let prop = component?.props.first(where: { $0.id == String(binding.dropFirst(6)) }), !animating || prop.animatable {
            try prop.validate(value)
            return
        }
        let parts = binding.split(separator: ".").map(String.init)
        if parts.count == 3, parts[0] == "slots", component?.slots.contains(parts[1]) == true,
           let property = MotionProperty(rawValue: parts[2]), [.x, .y, .scaleX, .scaleY, .rotation, .opacity, .reveal].contains(property) {
            try property.validate(value)
            return
        }
        throw MotionSceneError.invalidField("unknown or non-animatable binding '\(binding)'")
    }

    private func validate(_ component: MotionComponent) throws {
        guard !component.name.isEmpty, component.name.utf8.count <= 1024, !component.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              component.source.utf8.count <= Self.maxSourceBytes, component.stylesheet.utf8.count <= 4 * 1024 * 1024,
              component.props.count <= 128, component.fixtures.count <= 128, component.slots.count <= 128 else {
            throw MotionSceneError.invalidField("invalid component source or capacity")
        }
        try Self.uniqueIDs(component.props.map(\.id))
        try Self.uniqueIDs(component.slots)
        guard component.slots.allSatisfy({ !$0.contains(".") }) else { throw MotionSceneError.invalidField("slot IDs must not contain periods") }
        for prop in component.props {
            guard !prop.id.contains("."), !prop.label.isEmpty, prop.label.utf8.count <= 1024, prop.choices.count <= 1024,
                  prop.minimum.map({ $0.isFinite }) ?? true, prop.maximum.map({ $0.isFinite }) ?? true,
                  (prop.minimum ?? -1e12) <= (prop.maximum ?? 1e12) else { throw MotionSceneError.invalidField("invalid property schema") }
            try prop.validate(prop.defaultValue)
        }
        for (name, values) in component.fixtures {
            guard Self.validID(name) else { throw MotionSceneError.invalidField("invalid fixture ID") }
            for (key, value) in values {
                guard let prop = component.props.first(where: { $0.id == key }) else { throw MotionSceneError.invalidField("fixture contains unknown prop") }
                try prop.validate(value)
            }
        }
    }

    private func validate(_ track: MotionTrack, node: MotionNode, component: MotionComponent?) throws {
        guard !track.keys.isEmpty, track.keys.count <= 36000, (1...1000).contains(track.repeatCount),
              (0...36000).contains(track.gapFrames) else { throw MotionSceneError.invalidField("invalid animation track") }
        try Self.uniqueIDs(track.keys.map(\.id))
        var previous = -1
        var numeric: Bool?
        let component = component
        for key in track.keys {
            guard key.frame > previous, key.frame < node.durationFrames else { throw MotionSceneError.invalidField("keyframes must be unique, ordered, and within the layer") }
            try validateBinding(track.binding, value: key.value, node: node, component: component)
            try key.easing.validated()
            let isNumeric = key.value.number != nil
            guard numeric == nil || numeric == isNumeric else { throw MotionSceneError.invalidField("track values must have consistent types") }
            numeric = isNumeric
            previous = key.frame
        }
        if track.repeatCount > 1 {
            let duration = track.keys.last!.frame - track.keys.first!.frame
            guard duration > 0 else { throw MotionSceneError.invalidField("a repeated track needs a nonzero cycle") }
            try validateRepeat(start: track.keys.first!.frame, duration: duration, count: track.repeatCount, gap: track.gapFrames, limit: node.durationFrames)
        }
    }

    private func validateRepeat(start: Int, duration: Int, count: Int, gap: Int, limit: Int) throws {
        let end = Int64(start) + Int64(duration) * Int64(count) + Int64(gap) * Int64(count - 1)
        guard end <= Int64(limit) else { throw MotionSceneError.invalidField("animation repeats exceed layer duration") }
    }
}
