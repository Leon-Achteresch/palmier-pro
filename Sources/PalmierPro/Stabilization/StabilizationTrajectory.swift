import Foundation

enum StabilizationTrajectory {
    static let minSmoothingRadius = 2
    static let maxSmoothingRadius = 60

    struct Plan: Sendable, Equatable {
        var samples: [StabilizationSample]
        var cropScale: Double
    }

    static func smoothingRadius(for strength: Double, sampleCount: Int) -> Int {
        guard sampleCount > 1 else { return 0 }
        let clamped = ClipStabilization.clampedSmoothing(strength)
        let span = Double(maxSmoothingRadius - minSmoothingRadius)
        let radius = minSmoothingRadius + Int((clamped * span).rounded())
        return min(radius, max(1, sampleCount / 2))
    }

    static func path(from motions: [StabilizationSample]) -> [StabilizationSample] {
        var accumulated = StabilizationSample.identity
        return motions.map { motion in
            accumulated.dx += motion.dx
            accumulated.dy += motion.dy
            accumulated.rotation += motion.rotation
            return accumulated
        }
    }

    static func smoothed(_ path: [StabilizationSample], radius: Int) -> [StabilizationSample] {
        guard radius > 0, path.count > 1 else { return path }
        func filtered(_ values: [Double]) -> [Double] {
            let count = values.count
            let reach = min(radius, count - 1)
            let leadSlope = (values[reach] - values[0]) / Double(reach)
            let tailSlope = (values[count - 1] - values[count - 1 - reach]) / Double(reach)
            func padded(_ i: Int) -> Double {
                if i < 0 { return values[0] + Double(i) * leadSlope }
                if i >= count { return values[count - 1] + Double(i - count + 1) * tailSlope }
                return values[i]
            }
            var out = [Double](repeating: 0, count: count)
            var sum = 0.0
            for i in -radius...radius { sum += padded(i) }
            let window = Double(2 * radius + 1)
            for i in values.indices {
                out[i] = sum / window
                sum += padded(i + radius + 1) - padded(i - radius)
            }
            return out
        }
        let dx = filtered(path.map(\.dx))
        let dy = filtered(path.map(\.dy))
        let rotation = filtered(path.map(\.rotation))
        return path.indices.map { StabilizationSample(dx: dx[$0], dy: dy[$0], rotation: rotation[$0]) }
    }

    static func corrections(path: [StabilizationSample], smoothed: [StabilizationSample]) -> [StabilizationSample] {
        guard path.count == smoothed.count else { return [] }
        return path.indices.map {
            StabilizationSample(
                dx: smoothed[$0].dx - path[$0].dx,
                dy: smoothed[$0].dy - path[$0].dy,
                rotation: smoothed[$0].rotation - path[$0].rotation
            )
        }
    }

    static func rotationCoverScale(_ rotation: Double, aspect: Double) -> Double {
        guard rotation.isFinite, rotation != 0, aspect.isFinite, aspect > 0 else { return 1 }
        let k = max(aspect, 1 / aspect)
        let angle = min(abs(rotation), atan(k))
        return cos(angle) + k * sin(angle)
    }

    static func maxRotation(forCoverScale scale: Double, aspect: Double) -> Double {
        guard scale > 1, aspect.isFinite, aspect > 0 else { return 0 }
        let k = max(aspect, 1 / aspect)
        let radius = (1 + k * k).squareRoot()
        let phase = atan(k)
        return phase - acos(min(scale, radius) / radius)
    }

    static func coverScale(for sample: StabilizationSample, aspect: Double) -> Double {
        let offset = max(abs(sample.dx), abs(sample.dy))
        guard offset.isFinite else { return 1 }
        return rotationCoverScale(sample.rotation, aspect: aspect) * (1 + 2 * offset)
    }

    static let negligibleCrop = 1e-6

    static func cropScale(for corrections: [StabilizationSample], aspect: Double) -> Double {
        let required = corrections.reduce(1.0) { max($0, coverScale(for: $1, aspect: aspect)) }
        return required <= 1 + negligibleCrop ? 1 : required
    }

    static func clamping(
        _ corrections: [StabilizationSample],
        toCropScale cropScale: Double,
        aspect: Double
    ) -> [StabilizationSample] {
        let rotationLimit = maxRotation(forCoverScale: cropScale, aspect: aspect)
        return corrections.map { sample in
            var clamped = sample
            if abs(clamped.rotation) > rotationLimit {
                clamped.rotation = clamped.rotation < 0 ? -rotationLimit : rotationLimit
            }
            let allowed = cropScale / rotationCoverScale(clamped.rotation, aspect: aspect)
            let maxOffset = max(0, (allowed - 1) / 2)
            let offset = max(abs(clamped.dx), abs(clamped.dy))
            if offset > maxOffset {
                let factor = maxOffset / offset
                clamped.dx *= factor
                clamped.dy *= factor
            }
            return clamped
        }
    }

    static func plan(motions: [StabilizationSample], smoothing: Double, aspect: Double) -> Plan {
        guard !motions.isEmpty else { return Plan(samples: [], cropScale: 1) }
        let radius = smoothingRadius(for: smoothing, sampleCount: motions.count)
        let travelled = path(from: motions)
        let corrections = corrections(path: travelled, smoothed: smoothed(travelled, radius: radius))
        let required = cropScale(for: corrections, aspect: aspect)
        let capped = min(required, ClipStabilization.maxCropScale)
        guard required > capped else { return Plan(samples: corrections, cropScale: capped) }
        return Plan(
            samples: clamping(corrections, toCropScale: capped, aspect: aspect),
            cropScale: capped
        )
    }
}
