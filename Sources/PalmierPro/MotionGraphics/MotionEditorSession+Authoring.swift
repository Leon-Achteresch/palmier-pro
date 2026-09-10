import Foundation

extension MotionEditorSession {
    func saveFixture(_ name: String, component: MotionComponent, node: MotionNode) {
        var updated = component
        let values = evaluated?.nodes.first(where: { $0.id == node.id })?.props
            ?? Dictionary(uniqueKeysWithValues: component.props.map { ($0.id, node.props[$0.id] ?? $0.defaultValue) })
        updated.fixtures[name] = values
        perform([.component(updated)], name: "Save Motion Fixture")
    }
    func placeOnTimeline() {
        guard !busy, let asset = editor.mediaAssetsById[mediaRef] else { return }
        editor.placeDroppedAssets([asset], cursor: .newTrackAt(0), atFrame: editor.activeFrame, ripple: false)
    }

    func addKey(_ binding: String, value: MotionValue) {
        perform([.values(ids: orderedSelection, values: [binding: value], frame: frame)], name: "Add Motion Keyframe")
        selectedBinding = binding
    }

    func applyFixture(_ name: String, component: MotionComponent) {
        guard let values = component.fixtures[name] else { return }
        if autoKey {
            perform([.values(ids: orderedSelection, values: Dictionary(uniqueKeysWithValues: values.map { ("props." + $0.key, $0.value) }), frame: frame)])
        } else { perform([.fixture(ids: orderedSelection, name: name)]) }
    }

    func slotValue(node: MotionNode, slot: String, property: MotionProperty) -> MotionValue {
        evaluated?.nodes.first { $0.id == node.id }?.slots[slot]?[property.rawValue] ?? property.defaultValue
    }

    func addAudioCue(_ asset: MediaAsset) {
        guard let scene, asset.duration.isFinite, asset.duration > 0 else { return }
        let duration = min(scene.durationInFrames - frame, Int(min(asset.duration * scene.fps, 36000)))
        guard duration > 0 else { return }
        perform([.audioCue(MotionAudioCue(mediaRef: asset.id, frame: frame, durationFrames: duration))], name: "Add Motion Sound Cue")
    }

    func curveSamples(node: MotionNode, track: MotionTrack) async throws -> [Double] {
        guard let scene, let start = track.keys.first?.frame, let end = track.keys.last?.frame else { return [] }
        let snapshotRevision = revision
        var values: [Double] = []
        for index in 0...64 {
            try Task.checkCancellation()
            let frame = node.startFrame + start + (end - start) * index / 64
            let result = try await MotionFrameEvaluator.shared.evaluate(scene, key: snapshotRevision, frame: frame)
            guard let state = result.nodes.first(where: { $0.id == node.id }) else { return [] }
            let value = track.binding.hasPrefix("props.") ? state.props[String(track.binding.dropFirst(6))] : state.animatedProperties[track.binding]
            guard let number = value?.number else { return [] }
            values.append(number)
        }
        return values
    }

    func expandRecipe(node: MotionNode, recipe: MotionRecipe) {
        guard let scene, !busy else { return }
        let expected = revision
        run {
            let operations = try await MotionRecipeOperations.expand(scene: scene, nodeID: node.id, recipeID: recipe.id)
            _ = try await self.editor.motionScenes.apply(operations, mediaRef: self.mediaRef, expectedRevision: expected,
                actionName: "Expand Motion Recipe", editor: self.editor)
        }
    }
}
