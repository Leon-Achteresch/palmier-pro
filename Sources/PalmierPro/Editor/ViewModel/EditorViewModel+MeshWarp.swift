import CoreGraphics

@MainActor
extension EditorViewModel {

    /// The single selected visual clip while it carries an enabled mesh warp — the
    /// clip the preview overlay edits. A corner pin on the same clip wins, matching the renderer.
    var meshWarpedClip: Clip? {
        guard activePreviewTab == .timeline,
              selectedClipIds.count == 1,
              let id = selectedClipIds.first,
              let clip = clipFor(id: id),
              clip.cornerPinQuad(at: activeFrame) == nil,
              clip.meshWarpGrid(at: activeFrame) != nil else { return nil }
        return clip
    }

    var canEditMeshWarp: Bool {
        guard let clip = meshWarpedClip else { return false }
        return clip.contains(timelineFrame: activeFrame)
    }

    /// Adds the warp seeded from the clip's current placement, so enabling it doesn't move the clip.
    func addMeshWarp(clipId: String) {
        guard let clip = clipFor(id: clipId), clip.meshWarpEffect == nil else { return }
        let t = clip.transformAt(frame: activeFrame)
        let tl = t.topLeft
        let grid = MeshWarp.Grid(rect: CGRect(x: tl.x, y: tl.y, width: t.width, height: t.height))
        commitClipProperty(clipId: clipId, actionName: "Add Mesh Warp") { clip in
            var effect = Effect(type: MeshWarp.effectType)
            Self.write(grid, into: &effect, keyframeAt: nil)
            var stack = clip.effects ?? []
            stack.insert(effect, at: EffectRegistry.insertIndex(stack, for: MeshWarp.effectType))
            clip.effects = stack
        }
    }

    func removeMeshWarp(clipId: String) {
        commitClipProperty(clipId: clipId, actionName: "Remove Mesh Warp") { clip in
            var stack = clip.effects ?? []
            stack.removeAll { $0.type == MeshWarp.effectType }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    /// Live drag update — pair with `commitMeshWarp` on release for one undo entry.
    func applyMeshWarp(clipId: String, grid: MeshWarp.Grid) {
        applyClipProperty(clipId: clipId) { self.writeMeshWarp(into: &$0, grid: grid) }
    }

    func commitMeshWarp(clipId: String, grid: MeshWarp.Grid) {
        commitClipProperty(clipId: clipId, actionName: "Change Mesh Warp") {
            self.writeMeshWarp(into: &$0, grid: grid)
        }
    }

    /// Stamps the grid's current points as a keyframe at the playhead, which is what
    /// starts the animation: from here every drag writes a keyframe instead of a static value.
    func stampMeshWarpKeyframe(clipId: String) {
        guard let clip = clipFor(id: clipId),
              clip.contains(timelineFrame: activeFrame),
              let grid = clip.meshWarpGrid(at: activeFrame) else { return }
        let offset = activeFrame - clip.startFrame
        commitClipProperty(clipId: clipId, actionName: "Add Mesh Warp Keyframe") { clip in
            guard let i = clip.effects?.firstIndex(where: { $0.type == MeshWarp.effectType }) else { return }
            Self.write(grid, into: &clip.effects![i], keyframeAt: offset)
        }
    }

    /// Keyframes when the warp is already animated, static values otherwise — the same
    /// stopwatch rule the transform keyframe tracks use.
    private func writeMeshWarp(into clip: inout Clip, grid: MeshWarp.Grid) {
        guard let i = clip.effects?.firstIndex(where: { $0.type == MeshWarp.effectType }) else { return }
        let offset = activeFrame - clip.startFrame
        let animated = clip.isMeshWarpAnimated && clip.contains(timelineFrame: activeFrame)
        Self.write(grid, into: &clip.effects![i], keyframeAt: animated ? offset : nil)
    }

    static func write(_ grid: MeshWarp.Grid, into effect: inout Effect, keyframeAt offset: Int?) {
        for point in MeshWarp.Point.allCases {
            let p = grid[point]
            writeWarpParam(p.x, key: point.xKey, into: &effect, keyframeAt: offset)
            writeWarpParam(p.y, key: point.yKey, into: &effect, keyframeAt: offset)
        }
    }
}
