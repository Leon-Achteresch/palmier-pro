import Foundation

enum Interpolation: String, Codable, CaseIterable, Sendable {
    case linear, hold, smooth
    case easeIn, easeOut, easeInOut
    case sineIn, sineOut, sineInOut
    case circIn, circOut, circInOut
    case expoIn, expoOut, expoInOut
    case backIn, backOut, backInOut
    case elasticIn, elasticOut, elasticInOut
    case bounceIn, bounceOut, bounceInOut
    case anticipate, spring, cubicBezier, steps

    var displayName: String {
        switch self {
        case .linear:       "Linear"
        case .hold:         "Hold"
        case .smooth:       "Smooth"
        case .easeIn:       "Ease In"
        case .easeOut:      "Ease Out"
        case .easeInOut:    "Ease In-Out"
        case .sineIn:       "Sine In"
        case .sineOut:      "Sine Out"
        case .sineInOut:    "Sine In-Out"
        case .circIn:       "Circular In"
        case .circOut:      "Circular Out"
        case .circInOut:    "Circular In-Out"
        case .expoIn:       "Expo In"
        case .expoOut:      "Expo Out"
        case .expoInOut:    "Expo In-Out"
        case .backIn:       "Overshoot In"
        case .backOut:      "Overshoot"
        case .backInOut:    "Overshoot In-Out"
        case .elasticIn:    "Elastic In"
        case .elasticOut:   "Elastic"
        case .elasticInOut: "Elastic In-Out"
        case .bounceIn:     "Bounce In"
        case .bounceOut:    "Bounce"
        case .bounceInOut:  "Bounce In-Out"
        case .anticipate:   "Anticipate"
        case .spring:       "Spring"
        case .cubicBezier:  "Custom Bezier"
        case .steps:        "Steps"
        }
    }

    /// Time-reversed counterpart, used when a repeated animation plays backward.
    var mirrored: Interpolation {
        switch self {
        case .easeIn:     .easeOut
        case .easeOut:    .easeIn
        case .sineIn:     .sineOut
        case .sineOut:    .sineIn
        case .circIn:     .circOut
        case .circOut:    .circIn
        case .expoIn:     .expoOut
        case .expoOut:    .expoIn
        case .backIn:     .backOut
        case .backOut:    .backIn
        case .elasticIn:  .elasticOut
        case .elasticOut: .elasticIn
        case .bounceIn:   .bounceOut
        case .bounceOut:  .bounceIn
        default:          self
        }
    }

    func ease(_ t: Double, params: [Double]? = nil) -> Double {
        switch self {
        case .linear, .hold:
            return t
        case .smooth:
            return smoothstep(t)
        case .easeIn:
            return t * t * t
        case .easeOut:
            return 1 - pow(1 - t, 3)
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .sineIn:
            return 1 - cos(t * .pi / 2)
        case .sineOut:
            return sin(t * .pi / 2)
        case .sineInOut:
            return -(cos(.pi * t) - 1) / 2
        case .expoIn:
            return t <= 0 ? 0 : pow(2, 10 * t - 10)
        case .expoOut:
            return t >= 1 ? 1 : 1 - pow(2, -10 * t)
        case .expoInOut:
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            return t < 0.5 ? pow(2, 20 * t - 10) / 2 : (2 - pow(2, -20 * t + 10)) / 2
        case .circIn:
            return 1 - sqrt(max(0, 1 - t * t))
        case .circOut:
            return sqrt(max(0, 1 - (t - 1) * (t - 1)))
        case .circInOut:
            return t < 0.5
                ? (1 - sqrt(max(0, 1 - 4 * t * t))) / 2
                : (sqrt(max(0, 1 - pow(-2 * t + 2, 2))) + 1) / 2
        case .backIn:
            let c1 = params?.first ?? Self.defaultBackOvershoot, c3 = c1 + 1
            return c3 * t * t * t - c1 * t * t
        case .backOut:
            let c1 = params?.first ?? Self.defaultBackOvershoot, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .backInOut:
            let c2 = (params?.first ?? Self.defaultBackOvershoot) * 1.525
            return t < 0.5
                ? pow(2 * t, 2) * ((c2 + 1) * 2 * t - c2) / 2
                : (pow(2 * t - 2, 2) * ((c2 + 1) * (2 * t - 2) + c2) + 2) / 2
        case .elasticIn:
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            let e = Self.elasticSpec(params, defaultPeriod: 0.3)
            return -(e.a * pow(2, 10 * (t - 1)) * sin(((t - 1) - e.s) * 2 * .pi / e.p))
        case .elasticOut:
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            let e = Self.elasticSpec(params, defaultPeriod: 0.3)
            return e.a * pow(2, -10 * t) * sin((t - e.s) * 2 * .pi / e.p) + 1
        case .elasticInOut:
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            let e = Self.elasticSpec(params, defaultPeriod: 0.45)
            let u = 2 * t - 1
            return u < 0
                ? -0.5 * e.a * pow(2, 10 * u) * sin((u - e.s) * 2 * .pi / e.p)
                : 0.5 * e.a * pow(2, -10 * u) * sin((u - e.s) * 2 * .pi / e.p) + 1
        case .bounceIn:
            return 1 - Self.bounceOutCurve(1 - t)
        case .bounceOut:
            return Self.bounceOutCurve(t)
        case .bounceInOut:
            return t < 0.5
                ? (1 - Self.bounceOutCurve(1 - 2 * t)) / 2
                : (1 + Self.bounceOutCurve(2 * t - 1)) / 2
        case .anticipate:
            if t >= 1 { return 1 }
            let p = 2 * t
            if p < 1 {
                let c1 = 1.70158, c3 = c1 + 1
                return 0.5 * (c3 * p * p * p - c1 * p * p)
            }
            return 0.5 * (2 - pow(2, -10 * (p - 1)))
        case .spring:
            return Self.springCurve(t, bounce: params?.first ?? 0.25)
        case .cubicBezier:
            let p = (params?.count == 4 ? params! : [0.42, 0, 0.58, 1])
            return Self.cubicBezierCurve(t, x1: p[0], y1: p[1], x2: p[2], y2: p[3])
        case .steps:
            if t >= 1 { return 1 }
            let n = max(1, (params?.first).map { Int($0) } ?? 4)
            return (Double(n) * t).rounded(.down) / Double(n)
        }
    }

    static let defaultBackOvershoot = 1.70158

    /// Penner elastic: amplitude below 1 behaves as 1; s is the phase shift keeping f(1) = 1.
    private static func elasticSpec(_ params: [Double]?, defaultPeriod: Double) -> (a: Double, p: Double, s: Double) {
        let rawA = params?.first ?? 1
        let p = (params?.count ?? 0) >= 2 ? params![1] : defaultPeriod
        let a = max(1, rawA)
        let s = rawA < 1 ? p / 4 : p / (2 * .pi) * asin(1 / a)
        return (a, p, s)
    }

    private static func bounceOutCurve(_ t: Double) -> Double {
        let n1 = 7.5625, d1 = 2.75
        if t < 1 / d1 { return n1 * t * t }
        if t < 2 / d1 { let u = t - 1.5 / d1; return n1 * u * u + 0.75 }
        if t < 2.5 / d1 { let u = t - 2.25 / d1; return n1 * u * u + 0.9375 }
        let u = t - 2.625 / d1
        return n1 * u * u + 0.984375
    }

    /// Step response of a damped oscillator normalized to settle at t = 1.
    /// bounce 0 = critically damped glide, 1 = maximally bouncy (motion.js semantics).
    private static func springCurve(_ t: Double, bounce: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let zeta = min(1, max(0.1, 1 - min(1, max(0, bounce))))
        let omega0 = 8.0 / zeta
        if zeta >= 1 {
            return 1 - exp(-omega0 * t) * (1 + omega0 * t)
        }
        let omegaD = omega0 * sqrt(1 - zeta * zeta)
        let envelope = exp(-zeta * omega0 * t)
        return 1 - envelope * (cos(omegaD * t) + (zeta * omega0 / omegaD) * sin(omegaD * t))
    }

    /// CSS/motion.js cubic-bezier: solve x(u) = t for u, return y(u).
    private static func cubicBezierCurve(_ t: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        func sampleCurve(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
            let c = 3 * p1
            let b = 3 * (p2 - p1) - c
            let a = 1 - c - b
            return ((a * u + b) * u + c) * u
        }
        func sampleDerivative(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
            let c = 3 * p1
            let b = 3 * (p2 - p1) - c
            let a = 1 - c - b
            return (3 * a * u + 2 * b) * u + c
        }
        var u = t
        for _ in 0..<8 {
            let x = sampleCurve(u, x1, x2) - t
            if abs(x) < 1e-7 { return sampleCurve(u, y1, y2) }
            let d = sampleDerivative(u, x1, x2)
            if abs(d) < 1e-7 { break }
            u -= x / d
        }
        var lo = 0.0, hi = 1.0
        u = t
        while hi - lo > 1e-7 {
            if sampleCurve(u, x1, x2) < t { lo = u } else { hi = u }
            u = (lo + hi) / 2
        }
        return sampleCurve(u, y1, y2)
    }
}

struct Keyframe<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var frame: Int
    var value: Value
    var interpolationOut: Interpolation = .smooth
    var easingParams: [Double]? = nil
    /// Optional arrival easing for the segment this keyframe starts. When set, the
    /// segment departs on `interpolationOut` and blends into this curve toward the
    /// next keyframe (After-Effects-style split in/out ease). Nil = single curve.
    var interpolationIn: Interpolation? = nil
    var easingParamsIn: [Double]? = nil

    /// Eased progress for the segment this keyframe starts, blending depart and arrival curves.
    func segmentEase(_ t: Double) -> Double {
        let out = interpolationOut.ease(t, params: easingParams)
        guard let arrive = interpolationIn else { return out }
        let w = smoothstep(t)
        return out * (1 - w) + arrive.ease(t, params: easingParamsIn) * w
    }

    func retimed(to frame: Int) -> Keyframe {
        var kf = self
        kf.frame = frame
        return kf
    }

    func withValue(_ value: Value) -> Keyframe {
        var kf = self
        kf.value = value
        return kf
    }
}

extension Keyframe: Hashable where Value: Hashable {}

struct KeyframeTrack<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var keyframes: [Keyframe<Value>] = []

    var isActive: Bool { !keyframes.isEmpty }

    mutating func upsert(_ kf: Keyframe<Value>) {
        if let i = keyframes.firstIndex(where: { $0.frame == kf.frame }) {
            keyframes[i] = kf
        } else {
            let at = keyframes.firstIndex { $0.frame > kf.frame } ?? keyframes.endIndex
            keyframes.insert(kf, at: at)
        }
    }

    mutating func remove(at frame: Int) {
        keyframes.removeAll { $0.frame == frame }
    }

    mutating func move(from oldFrame: Int, to newFrame: Int) {
        guard let i = keyframes.firstIndex(where: { $0.frame == oldFrame }) else { return }
        if newFrame != oldFrame, keyframes.contains(where: { $0.frame == newFrame }) { return }
        var kf = keyframes.remove(at: i)
        kf.frame = newFrame
        upsert(kf)
    }
}

extension KeyframeTrack: Hashable where Value: Hashable {}

extension KeyframeTrack where Value: KeyframeInterpolatable {
    func rebased(by offset: Int, fallback: Value) -> KeyframeTrack? {
        guard isActive else { return nil }
        let boundary = sample(at: offset, fallback: fallback)
        var kfs = keyframes
            .filter { $0.frame >= offset }
            .map { $0.retimed(to: $0.frame - offset) }
        if kfs.first?.frame != 0 {
            if let before = keyframes.last(where: { $0.frame < offset }) {
                kfs.insert(before.retimed(to: 0).withValue(boundary), at: 0)
            } else {
                kfs.insert(Keyframe(frame: 0, value: boundary), at: 0)
            }
        }
        return kfs.isEmpty ? nil : KeyframeTrack(keyframes: kfs)
    }
}

@inlinable func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }

protocol KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: Self, _ b: Self, t: Double) -> Self
}

extension Double: KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: Double, _ b: Double, t: Double) -> Double {
        a + (b - a) * t
    }
}

/// Two-component keyframe value used for position (x, y) and scale (width, height).
struct AnimPair: Codable, Sendable, Equatable, KeyframeInterpolatable {
    var a: Double
    var b: Double

    static func keyframeInterpolate(_ from: AnimPair, _ to: AnimPair, t: Double) -> AnimPair {
        AnimPair(
            a: Double.keyframeInterpolate(from.a, to.a, t: t),
            b: Double.keyframeInterpolate(from.b, to.b, t: t)
        )
    }
}

extension Crop: KeyframeInterpolatable {
    static func keyframeInterpolate(_ a: Crop, _ b: Crop, t: Double) -> Crop {
        Crop(
            left: Double.keyframeInterpolate(a.left, b.left, t: t),
            top: Double.keyframeInterpolate(a.top, b.top, t: t),
            right: Double.keyframeInterpolate(a.right, b.right, t: t),
            bottom: Double.keyframeInterpolate(a.bottom, b.bottom, t: t)
        )
    }
}

/// Identifies which clip property an inspector lane / stamp button drives.
enum AnimatableProperty: String, CaseIterable, Sendable {
    case opacity, position, scale, rotation, crop, volume, speed

    var displayName: String {
        switch self {
        case .opacity:  "Opacity"
        case .position: "Position"
        case .scale:    "Scale"
        case .rotation: "Rotation"
        case .crop:     "Crop"
        case .volume:   "Volume"
        case .speed:    "Speed"
        }
    }
}

// MARK: - Clip keyframe helpers

extension Clip {
    func contains(timelineFrame frame: Int) -> Bool {
        frame >= startFrame && frame < endFrame
    }

    /// Absolute timeline frame → clip-relative offset (used internally in track storage)
    private func toOffset(_ timelineFrame: Int) -> Int { timelineFrame - startFrame }
    /// Clip-relative offset → absolute timeline frame (used in public API)
    private func toAbs(_ offset: Int) -> Int { startFrame + offset }

    func keyframeFrames(for property: AnimatableProperty) -> [Int] {
        let offsets: [Int]
        switch property {
        case .opacity:  offsets = opacityTrack?.keyframes.map(\.frame) ?? []
        case .position: offsets = positionTrack?.keyframes.map(\.frame) ?? []
        case .scale:    offsets = scaleTrack?.keyframes.map(\.frame) ?? []
        case .rotation: offsets = rotationTrack?.keyframes.map(\.frame) ?? []
        case .crop:     offsets = cropTrack?.keyframes.map(\.frame) ?? []
        case .volume:   offsets = volumeTrack?.keyframes.map(\.frame) ?? []
        case .speed:    offsets = speedTrack?.keyframes.map(\.frame) ?? []
        }
        return offsets.map(toAbs)
    }

    func interpolation(for property: AnimatableProperty, atFrame frame: Int) -> Interpolation? {
        let o = toOffset(frame)
        switch property {
        case .opacity:  return opacityTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .position: return positionTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .scale:    return scaleTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .rotation: return rotationTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .crop:     return cropTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .volume:   return volumeTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        case .speed:    return speedTrack?.keyframes.first(where: { $0.frame == o })?.interpolationOut
        }
    }

    mutating func upsertKeyframe<V>(
        in keyPath: WritableKeyPath<Clip, KeyframeTrack<V>?>,
        frame: Int,
        value: V
    ) {
        var t = self[keyPath: keyPath] ?? KeyframeTrack<V>()
        // `frame` is an absolute timeline frame; storage is converted to clip-relative via `toOffset`
        let offset = toOffset(frame)
        if let existing = t.keyframes.first(where: { $0.frame == offset }) {
            t.upsert(existing.withValue(value))
        } else {
            t.upsert(Keyframe(frame: offset, value: value))
        }
        self[keyPath: keyPath] = t
    }

    func arrivalInterpolation(for property: AnimatableProperty, atFrame frame: Int) -> Interpolation? {
        let o = toOffset(frame)
        func read<V>(_ track: KeyframeTrack<V>?) -> Interpolation? {
            track?.keyframes.first(where: { $0.frame == o })?.interpolationIn
        }
        switch property {
        case .opacity:  return read(opacityTrack)
        case .position: return read(positionTrack)
        case .scale:    return read(scaleTrack)
        case .rotation: return read(rotationTrack)
        case .crop:     return read(cropTrack)
        case .volume:   return read(volumeTrack)
        case .speed:    return read(speedTrack)
        }
    }

    mutating func setArrivalInterpolation(for property: AnimatableProperty, atFrame frame: Int, _ interpolation: Interpolation?) {
        let o = toOffset(frame)
        func update<V>(_ track: inout KeyframeTrack<V>?) {
            guard let i = track?.keyframes.firstIndex(where: { $0.frame == o }) else { return }
            track?.keyframes[i].interpolationIn = interpolation
            track?.keyframes[i].easingParamsIn = nil
        }
        switch property {
        case .opacity:  update(&opacityTrack)
        case .position: update(&positionTrack)
        case .scale:    update(&scaleTrack)
        case .rotation: update(&rotationTrack)
        case .crop:     update(&cropTrack)
        case .volume:   update(&volumeTrack)
        case .speed:    update(&speedTrack)
        }
    }

    mutating func removeKeyframe(for property: AnimatableProperty, at frame: Int) {
        let o = toOffset(frame)
        switch property {
        case .opacity:
            opacityTrack?.remove(at: o)
            if opacityTrack?.keyframes.isEmpty == true { opacityTrack = nil }
        case .position:
            positionTrack?.remove(at: o)
            if positionTrack?.keyframes.isEmpty == true { positionTrack = nil }
        case .scale:
            scaleTrack?.remove(at: o)
            if scaleTrack?.keyframes.isEmpty == true { scaleTrack = nil }
        case .rotation:
            rotationTrack?.remove(at: o)
            if rotationTrack?.keyframes.isEmpty == true { rotationTrack = nil }
        case .crop:
            cropTrack?.remove(at: o)
            if cropTrack?.keyframes.isEmpty == true { cropTrack = nil }
        case .volume:
            volumeTrack?.remove(at: o)
            if volumeTrack?.keyframes.isEmpty == true { volumeTrack = nil }
        case .speed:
            speedTrack?.remove(at: o)
            if speedTrack?.keyframes.isEmpty == true { speedTrack = nil }
        }
    }

    mutating func setInterpolation(for property: AnimatableProperty, atFrame frame: Int, _ interpolation: Interpolation) {
        let o = toOffset(frame)
        switch property {
        case .opacity:
            if let i = opacityTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                opacityTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .position:
            if let i = positionTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                positionTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .scale:
            if let i = scaleTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                scaleTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .rotation:
            if let i = rotationTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                rotationTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .crop:
            if let i = cropTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                cropTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .volume:
            if let i = volumeTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                volumeTrack?.keyframes[i].interpolationOut = interpolation
            }
        case .speed:
            if let i = speedTrack?.keyframes.firstIndex(where: { $0.frame == o }) {
                speedTrack?.keyframes[i].interpolationOut = interpolation
            }
        }
    }

    mutating func moveKeyframe(for property: AnimatableProperty, from: Int, to: Int) {
        let fromO = toOffset(from), toO = toOffset(to)
        switch property {
        case .opacity:  opacityTrack?.move(from: fromO, to: toO)
        case .position: positionTrack?.move(from: fromO, to: toO)
        case .scale:    scaleTrack?.move(from: fromO, to: toO)
        case .rotation: rotationTrack?.move(from: fromO, to: toO)
        case .crop:     cropTrack?.move(from: fromO, to: toO)
        case .volume:   volumeTrack?.move(from: fromO, to: toO)
        case .speed:    speedTrack?.move(from: fromO, to: toO)
        }
    }
}

extension KeyframeTrack where Value: KeyframeInterpolatable {
    func sample(at frame: Int, fallback: Value) -> Value {
        guard !keyframes.isEmpty else { return fallback }
        if keyframes.count == 1 { return keyframes[0].value }
        if frame <= keyframes[0].frame { return keyframes[0].value }
        if frame >= keyframes.last!.frame { return keyframes.last!.value }

        guard let bIdx = keyframes.firstIndex(where: { $0.frame > frame }) else {
            return keyframes.last!.value
        }
        let a = keyframes[bIdx - 1]
        let b = keyframes[bIdx]
        let raw = Double(frame - a.frame) / Double(b.frame - a.frame)
        if a.interpolationOut == .hold { return a.value }
        return Value.keyframeInterpolate(a.value, b.value, t: a.segmentEase(raw))
    }
}
