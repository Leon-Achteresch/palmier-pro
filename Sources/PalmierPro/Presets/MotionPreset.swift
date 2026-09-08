import Foundation

enum MotionPresetCategory: String, Sendable {
    case entrance, emphasis, exit
}

struct MotionPose: Sendable {
    var t: Double
    var scale: Double = 1
    var dx: Double = 0
    var dy: Double = 0
    var rotation: Double = 0
    var opacity: Double = 1
    var blur: Double = 0
    var ease: Interpolation = .easeInOut
    var easeParams: [Double]? = nil
}

enum MotionPreset: String, CaseIterable, Sendable {
    case focusIn = "focus-in"
    case depthEmerge = "depth-emerge"
    case popIn = "pop-in"
    case slideUp = "slide-up"
    case whipIn = "whip-in"
    case spinReveal = "spin-reveal"
    case kenBurns = "ken-burns"
    case punchIn = "punch-in"
    case floatHold = "float-hold"
    case pulse = "pulse"
    case fadeDown = "fade-down"
    case scaleBlurOut = "scale-blur-out"
    case flickOut = "flick-out"
    case whipOut = "whip-out"

    var category: MotionPresetCategory {
        switch self {
        case .focusIn, .depthEmerge, .popIn, .slideUp, .whipIn, .spinReveal:
            .entrance
        case .kenBurns, .punchIn, .floatHold, .pulse:
            .emphasis
        case .fadeDown, .scaleBlurOut, .flickOut, .whipOut:
            .exit
        }
    }

    var displayName: String {
        switch self {
        case .focusIn:      "Focus In"
        case .depthEmerge:  "Depth Emerge"
        case .popIn:        "Pop In"
        case .slideUp:      "Slide Up"
        case .whipIn:       "Whip In"
        case .spinReveal:   "Spin Reveal"
        case .kenBurns:     "Ken Burns"
        case .punchIn:      "Punch In"
        case .floatHold:    "Float"
        case .pulse:        "Pulse"
        case .fadeDown:     "Fade Down"
        case .scaleBlurOut: "Scale Blur Out"
        case .flickOut:     "Flick Out"
        case .whipOut:      "Whip Out"
        }
    }

    var defaultDurationSeconds: Double {
        switch category {
        case .entrance, .exit: 0.8
        case .emphasis: 0
        }
    }

    var affectedProperties: [AnimatableProperty] {
        var set: Set<AnimatableProperty> = []
        for pose in poses(intensity: 1) {
            if pose.scale != 1 { set.insert(.scale); set.insert(.position) }
            if pose.dx != 0 || pose.dy != 0 { set.insert(.position) }
            if pose.rotation != 0 { set.insert(.rotation) }
            if pose.opacity != 1 { set.insert(.opacity) }
            if pose.blur != 0 { set.insert(.blur) }
        }
        if self == .punchIn { set.formUnion([.scale, .position]) }
        return AnimatableProperty.allCases.filter { set.contains($0) }
    }

    func poses(intensity i: Double) -> [MotionPose] {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * i }
        switch self {
        case .focusIn:
            return [
                MotionPose(t: 0, scale: lerp(1.04, 1.1), opacity: 0.3, blur: lerp(6, 22), ease: .easeOut),
                MotionPose(t: 1),
            ]
        case .depthEmerge:
            return [
                MotionPose(t: 0, scale: lerp(0.35, 0.15), opacity: 0, blur: lerp(12, 28), ease: .easeOut),
                MotionPose(t: 0.45, scale: 1.08, ease: .backOut),
                MotionPose(t: 1),
            ]
        case .popIn:
            return [
                MotionPose(t: 0, scale: lerp(0.6, 0.3), opacity: 0, ease: .backOut,
                           easeParams: [lerp(1.2, 2.4)]),
                MotionPose(t: 1),
            ]
        case .slideUp:
            return [
                MotionPose(t: 0, dy: lerp(0.08, 0.25), opacity: 0, ease: .expoOut),
                MotionPose(t: 1),
            ]
        case .whipIn:
            return [
                MotionPose(t: 0, dx: lerp(-0.3, -0.8), opacity: 0.6, blur: lerp(8, 24), ease: .expoOut),
                MotionPose(t: 1),
            ]
        case .spinReveal:
            return [
                MotionPose(t: 0, scale: lerp(0.8, 0.65), rotation: lerp(-45, -95), opacity: 0, ease: .easeInOut),
                MotionPose(t: 1),
            ]
        case .kenBurns:
            return [
                MotionPose(t: 0, ease: .sineInOut),
                MotionPose(t: 1, scale: lerp(1.05, 1.16)),
            ]
        case .punchIn:
            let zoom = lerp(1.2, 2.0)
            return [
                MotionPose(t: 0, ease: .easeInOut),
                MotionPose(t: 0.25, scale: zoom, ease: .hold),
                MotionPose(t: 0.75, scale: zoom, ease: .easeInOut),
                MotionPose(t: 1),
            ]
        case .floatHold:
            return [
                MotionPose(t: 0, ease: .sineInOut),
                MotionPose(t: 0.5, dy: lerp(-0.01, -0.035), ease: .sineInOut),
                MotionPose(t: 1),
            ]
        case .pulse:
            return [
                MotionPose(t: 0, ease: .sineInOut),
                MotionPose(t: 0.5, scale: lerp(1.03, 1.09), ease: .sineInOut),
                MotionPose(t: 1),
            ]
        case .fadeDown:
            return [
                MotionPose(t: 0, ease: .easeIn),
                MotionPose(t: 1, scale: lerp(0.97, 0.9), dy: lerp(0.05, 0.15), opacity: 0),
            ]
        case .scaleBlurOut:
            return [
                MotionPose(t: 0, ease: .easeIn),
                MotionPose(t: 1, scale: lerp(1.1, 1.45), opacity: 0, blur: lerp(10, 30)),
            ]
        case .flickOut:
            return [
                MotionPose(t: 0, ease: .backIn),
                MotionPose(t: 1, dx: lerp(0.4, 1.0), rotation: lerp(10, 30), opacity: 0),
            ]
        case .whipOut:
            return [
                MotionPose(t: 0, ease: .expoIn),
                MotionPose(t: 1, dx: lerp(0.3, 0.8), opacity: 0.4, blur: lerp(8, 24)),
            ]
        }
    }
}

struct MotionApplication {
    var preset: MotionPreset
    var intensity: Double
    var rampFrames: Int
    var focusX: Double?
    var focusY: Double?
    var delayFrames: Int = 0

    struct Receipt: Sendable {
        var properties: [AnimatableProperty]
        var segment: ClosedRange<Int>
        var keyframeCount: Int
    }

    @discardableResult
    func apply(to clip: inout Clip) -> Receipt {
        let dur = max(clip.durationFrames - 1, 0)
        let delay = min(max(delayFrames, 0), max(dur - 1, 0))
        let segment: ClosedRange<Int>
        switch preset.category {
        case .entrance:
            let start = delay
            segment = start...min(start + max(rampFrames, 1), dur)
        case .exit:
            let end = max(dur - delay, 0)
            segment = max(0, end - max(rampFrames, 1))...end
        case .emphasis:
            segment = 0...dur
        }
        let segStart = segment.lowerBound
        let segLen = max(segment.upperBound - segment.lowerBound, 1)

        let intensity = min(max(intensity, 0), 1)
        let poses = preset.poses(intensity: intensity)
        let properties = preset.affectedProperties
        let baseW = clip.transform.width
        let baseH = clip.transform.height
        let center = clip.transform.center
        let baseRotation = clip.transform.rotation
        let baseOpacity = clip.opacity
        let fx = min(max(focusX ?? 0.5, 0), 1)
        let fy = min(max(focusY ?? 0.5, 0), 1)

        for property in properties {
            clearSegment(&clip, property: property, segment: segment)
        }

        var blurTrack = clip.blurKeyframeTrack ?? KeyframeTrack<Double>()
        var count = 0
        for pose in poses {
            let frame = segStart + Int((pose.t * Double(segLen)).rounded())
            count += 1
            for property in properties {
                switch property {
                case .scale:
                    upsert(&clip, \.scaleTrack, frame, AnimPair(a: baseW * pose.scale, b: baseH * pose.scale), pose)
                case .position:
                    let w = baseW * pose.scale
                    let h = baseH * pose.scale
                    let anchorX = center.x + (fx - 0.5) * baseW
                    let anchorY = center.y + (fy - 0.5) * baseH
                    let topLeftX = anchorX - fx * w + pose.dx
                    let topLeftY = anchorY - fy * h + pose.dy
                    upsert(&clip, \.positionTrack, frame, AnimPair(a: topLeftX, b: topLeftY), pose)
                case .rotation:
                    upsert(&clip, \.rotationTrack, frame, baseRotation + pose.rotation, pose)
                case .opacity:
                    upsert(&clip, \.opacityTrack, frame, min(max(baseOpacity * pose.opacity, 0), 1), pose)
                case .blur:
                    var kf = Keyframe(frame: frame, value: min(max(pose.blur, 0), 100))
                    kf.interpolationOut = pose.ease
                    kf.easingParams = pose.easeParams
                    blurTrack.upsert(kf)
                case .crop, .volume, .speed:
                    break
                }
            }
        }
        if properties.contains(.blur) {
            clip.setBlurKeyframeTrack(blurTrack)
        }
        return Receipt(properties: properties, segment: segment, keyframeCount: count)
    }

    private func upsert<V: Codable & Sendable & Equatable>(
        _ clip: inout Clip,
        _ keyPath: WritableKeyPath<Clip, KeyframeTrack<V>?>,
        _ frame: Int,
        _ value: V,
        _ pose: MotionPose
    ) {
        var track = clip[keyPath: keyPath] ?? KeyframeTrack<V>()
        var kf = Keyframe(frame: frame, value: value)
        kf.interpolationOut = pose.ease
        kf.easingParams = pose.easeParams
        track.upsert(kf)
        clip[keyPath: keyPath] = track
    }

    private func clearSegment(_ clip: inout Clip, property: AnimatableProperty, segment: ClosedRange<Int>) {
        if property == .blur {
            guard var track = clip.blurKeyframeTrack else { return }
            track.keyframes.removeAll { segment.contains($0.frame) }
            clip.setBlurKeyframeTrack(track.keyframes.isEmpty ? nil : track)
            return
        }
        func clear<V>(_ keyPath: WritableKeyPath<Clip, KeyframeTrack<V>?>) {
            guard var track = clip[keyPath: keyPath] else { return }
            track.keyframes.removeAll { segment.contains($0.frame) }
            clip[keyPath: keyPath] = track.keyframes.isEmpty ? nil : track
        }
        switch property {
        case .opacity:  clear(\.opacityTrack)
        case .position: clear(\.positionTrack)
        case .scale:    clear(\.scaleTrack)
        case .rotation: clear(\.rotationTrack)
        case .crop:     clear(\.cropTrack)
        case .volume:   clear(\.volumeTrack)
        case .speed:    clear(\.speedTrack)
        case .blur:     break
        }
    }
}
