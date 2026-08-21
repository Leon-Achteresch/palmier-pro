import Foundation

enum ClipAttribute: String, CaseIterable, Sendable {
    case transform
    case crop
    case opacity
    case volume
    case fades
    case edges
    case effects
    case color
    case keyframes
    case blendMode
    case textStyle
    case audioMix
}

extension Clip {
    mutating func absorb(_ attributes: Set<ClipAttribute>, from source: Clip) {
        if attributes.contains(.transform) { transform = source.transform }
        if attributes.contains(.crop) { crop = source.crop }
        if attributes.contains(.opacity) { opacity = source.opacity }
        if attributes.contains(.volume) { volume = source.volume }
        if attributes.contains(.fades) {
            fadeInFrames = min(source.fadeInFrames, max(0, durationFrames - source.fadeOutFrames))
            fadeOutFrames = min(source.fadeOutFrames, max(0, durationFrames - fadeInFrames))
            fadeInInterpolation = source.fadeInInterpolation
            fadeOutInterpolation = source.fadeOutInterpolation
        }
        if attributes.contains(.edges) {
            edgeRounding = source.edgeRounding
            edgeSoftness = source.edgeSoftness
        }
        if attributes.contains(.effects) || attributes.contains(.color) {
            let keepColor = !attributes.contains(.color)
            let keepOther = !attributes.contains(.effects)
            var stack = (effects ?? []).filter { $0.isColorGrade ? keepColor : keepOther }
            let incoming = (source.effects ?? []).filter {
                $0.isColorGrade ? attributes.contains(.color) : attributes.contains(.effects)
            }
            for var effect in incoming {
                effect.id = UUID().uuidString
                stack.removeAll { $0.type == effect.type }
                stack.insert(effect, at: EffectRegistry.insertIndex(stack, for: effect.type))
            }
            effects = stack.isEmpty ? nil : stack
        }
        if attributes.contains(.blendMode) { blendMode = source.blendMode }
        if attributes.contains(.audioMix) { audioMix = source.audioMix }
        if attributes.contains(.keyframes) {
            opacityTrack = source.opacityTrack
            positionTrack = source.positionTrack
            scaleTrack = source.scaleTrack
            rotationTrack = source.rotationTrack
            cropTrack = source.cropTrack
            volumeTrack = source.volumeTrack
            clampKeyframesToDuration()
            let withoutSpeed = self
            speedTrack = source.speedTrack
            clampKeyframesToDuration()
            if (try? validateSpeedRamp(speedTrack)) == nil { self = withoutSpeed }
        }
        if attributes.contains(.textStyle) {
            textStyle = source.textStyle
            textFillMode = source.textFillMode
            textAnimation = source.textAnimation
        }
    }
}

extension Effect {
    var isColorGrade: Bool { type.hasPrefix("color.") }
}
