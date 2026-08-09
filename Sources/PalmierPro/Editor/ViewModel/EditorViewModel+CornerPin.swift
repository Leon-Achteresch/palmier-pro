import CoreGraphics

@MainActor
extension EditorViewModel {

    /// The single selected visual clip while it carries an enabled corner pin — the
    /// clip the preview overlay edits.
    var cornerPinnedClip: Clip? {
        guard activePreviewTab == .timeline,
              selectedClipIds.count == 1,
              let id = selectedClipIds.first,
              let clip = clipFor(id: id),
              clip.cornerPinQuad(at: activeFrame) != nil else { return nil }
        return clip
    }

    var canEditCornerPin: Bool {
        guard let clip = cornerPinnedClip else { return false }
        return clip.contains(timelineFrame: activeFrame)
    }

    /// Adds the pin seeded from the clip's current placement, so enabling it doesn't move the clip.
    func addCornerPin(clipId: String) {
        guard let clip = clipFor(id: clipId), clip.cornerPinEffect == nil else { return }
        let t = clip.transformAt(frame: activeFrame)
        let tl = t.topLeft
        let quad = CornerPin.Quad(rect: CGRect(x: tl.x, y: tl.y, width: t.width, height: t.height))
        commitClipProperty(clipId: clipId, actionName: "Add Corner Pin") { clip in
            var effect = Effect(type: CornerPin.effectType)
            Self.write(quad, into: &effect, keyframeAt: nil)
            var stack = clip.effects ?? []
            stack.insert(effect, at: EffectRegistry.insertIndex(stack, for: CornerPin.effectType))
            clip.effects = stack
        }
    }

    func removeCornerPin(clipId: String) {
        commitClipProperty(clipId: clipId, actionName: "Remove Corner Pin") { clip in
            var stack = clip.effects ?? []
            stack.removeAll { $0.type == CornerPin.effectType }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    /// Live drag update — pair with `commitCornerPin` on release for one undo entry.
    func applyCornerPin(clipId: String, quad: CornerPin.Quad) {
        applyClipProperty(clipId: clipId) { self.writeCornerPin(into: &$0, quad: quad) }
    }

    func commitCornerPin(clipId: String, quad: CornerPin.Quad) {
        commitClipProperty(clipId: clipId, actionName: "Change Corner Pin") {
            self.writeCornerPin(into: &$0, quad: quad)
        }
    }

    /// Stamps the pin's current corners as a keyframe at the playhead, which is what
    /// starts the animation: from here every drag writes a keyframe instead of a static value.
    func stampCornerPinKeyframe(clipId: String) {
        guard let clip = clipFor(id: clipId),
              clip.contains(timelineFrame: activeFrame),
              let quad = clip.cornerPinQuad(at: activeFrame) else { return }
        let offset = activeFrame - clip.startFrame
        commitClipProperty(clipId: clipId, actionName: "Add Corner Pin Keyframe") { clip in
            guard let i = clip.effects?.firstIndex(where: { $0.type == CornerPin.effectType }) else { return }
            Self.write(quad, into: &clip.effects![i], keyframeAt: offset)
        }
    }

    /// Keyframes when the pin is already animated, static values otherwise — the same
    /// stopwatch rule the transform keyframe tracks use.
    private func writeCornerPin(into clip: inout Clip, quad: CornerPin.Quad) {
        guard let i = clip.effects?.firstIndex(where: { $0.type == CornerPin.effectType }) else { return }
        let offset = activeFrame - clip.startFrame
        let animated = clip.isCornerPinAnimated && clip.contains(timelineFrame: activeFrame)
        Self.write(quad, into: &clip.effects![i], keyframeAt: animated ? offset : nil)
    }

    /// Tracking keyframes interpolate linearly; eased corners read as a wobble against the plate.
    private static func write(_ quad: CornerPin.Quad, into effect: inout Effect, keyframeAt offset: Int?) {
        for corner in CornerPin.Corner.allCases {
            let point = quad[corner]
            write(point.x, key: corner.xKey, into: &effect, keyframeAt: offset)
            write(point.y, key: corner.yKey, into: &effect, keyframeAt: offset)
        }
    }

    private static func write(_ value: CGFloat, key: String, into effect: inout Effect, keyframeAt offset: Int?) {
        let clamped = min(CornerPin.range.upperBound, max(CornerPin.range.lowerBound, Double(value)))
        guard let offset else {
            effect.params[key] = EffectParam(value: clamped, track: effect.params[key]?.track)
            return
        }
        var track = effect.params[key]?.track ?? KeyframeTrack<Double>()
        var keyframe = track.keyframes.first { $0.frame == offset }
            ?? Keyframe(frame: offset, value: clamped, interpolationOut: .linear)
        keyframe.value = clamped
        track.upsert(keyframe)
        effect.params[key] = EffectParam(value: effect.params[key]?.value ?? clamped, track: track)
    }
}
