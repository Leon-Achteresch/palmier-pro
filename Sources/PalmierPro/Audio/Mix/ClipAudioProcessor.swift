import Foundation

struct Biquad: Sendable, Equatable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static let identity = Biquad()

    var isIdentity: Bool { self == .identity }

    static func lowShelf(frequency: Double, slope: Double, gainDb: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDb / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let alpha = sinW / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) - (a - 1) * cosW + twoSqrtAAlpha)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
        let b2 = a * ((a + 1) - (a - 1) * cosW - twoSqrtAAlpha)
        let a0 = (a + 1) + (a - 1) * cosW + twoSqrtAAlpha
        let a1 = -2 * ((a - 1) + (a + 1) * cosW)
        let a2 = (a + 1) + (a - 1) * cosW - twoSqrtAAlpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highShelf(frequency: Double, slope: Double, gainDb: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDb / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let alpha = sinW / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) + (a - 1) * cosW + twoSqrtAAlpha)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
        let b2 = a * ((a + 1) + (a - 1) * cosW - twoSqrtAAlpha)
        let a0 = (a + 1) - (a - 1) * cosW + twoSqrtAAlpha
        let a1 = 2 * ((a - 1) - (a + 1) * cosW)
        let a2 = (a + 1) - (a - 1) * cosW - twoSqrtAAlpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func peaking(frequency: Double, q: Double, gainDb: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDb / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let alpha = sinW / (2 * q)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0,
            b1: (-2 * cosW) / a0,
            b2: (1 - alpha * a) / a0,
            a1: (-2 * cosW) / a0,
            a2: (1 - alpha / a) / a0
        )
    }

    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w), sinW = sin(w)
        let cos2W = cos(2 * w), sin2W = sin(2 * w)
        let numReal = b0 + b1 * cosW + b2 * cos2W
        let numImag = -(b1 * sinW + b2 * sin2W)
        let denReal = 1 + a1 * cosW + a2 * cos2W
        let denImag = -(a1 * sinW + a2 * sin2W)
        let num = (numReal * numReal + numImag * numImag).squareRoot()
        let den = (denReal * denReal + denImag * denImag).squareRoot()
        guard den > 0 else { return 0 }
        return num / den
    }
}

struct BiquadState: Sendable {
    var z1: Double = 0
    var z2: Double = 0

    mutating func reset() { z1 = 0; z2 = 0 }

    mutating func process(_ x: Double, _ c: Biquad) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

struct ClipAudioProcessorConfiguration: Sendable {
    let lowShelf: Biquad
    let mid: Biquad
    let highShelf: Biquad
    let hasEQ: Bool
    let compressor: AudioCompressorSettings?
    let attackCoefficient: Double
    let releaseCoefficient: Double
    let makeupGain: Double
    let leftGain: Double
    let rightGain: Double
    let hasPan: Bool

    init(mix: ClipAudioMix, sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        if let eq = mix.eq, !eq.isFlat {
            lowShelf = eq.lowGainDb == 0 ? .identity : .lowShelf(
                frequency: AudioEQSettings.lowShelfFrequency,
                slope: AudioEQSettings.shelfSlope,
                gainDb: eq.lowGainDb,
                sampleRate: rate
            )
            mid = eq.midGainDb == 0 ? .identity : .peaking(
                frequency: min(eq.midFrequency, rate / 2.2),
                q: AudioEQSettings.midQ,
                gainDb: eq.midGainDb,
                sampleRate: rate
            )
            highShelf = eq.highGainDb == 0 ? .identity : .highShelf(
                frequency: min(AudioEQSettings.highShelfFrequency, rate / 2.2),
                slope: AudioEQSettings.shelfSlope,
                gainDb: eq.highGainDb,
                sampleRate: rate
            )
            hasEQ = true
        } else {
            lowShelf = .identity
            mid = .identity
            highShelf = .identity
            hasEQ = false
        }

        compressor = mix.compressor
        if let comp = mix.compressor {
            attackCoefficient = Self.smoothingCoefficient(milliseconds: comp.attackMs, sampleRate: rate)
            releaseCoefficient = Self.smoothingCoefficient(milliseconds: comp.releaseMs, sampleRate: rate)
            makeupGain = pow(10, comp.makeupGainDb / 20)
        } else {
            attackCoefficient = 0
            releaseCoefficient = 0
            makeupGain = 1
        }

        let gains = ClipAudioProcessorConfiguration.panGains(mix.pan)
        leftGain = gains.left
        rightGain = gains.right
        hasPan = mix.pan != 0
    }

    static func panGains(_ pan: Double) -> (left: Double, right: Double) {
        let clamped = ClipAudioMixLimits.clamp(pan, to: ClipAudioMixLimits.pan)
        let angle = (clamped + 1) * Double.pi / 4
        return (left: 2.0.squareRoot() * cos(angle), right: 2.0.squareRoot() * sin(angle))
    }

    private static func smoothingCoefficient(milliseconds: Double, sampleRate: Double) -> Double {
        let seconds = max(milliseconds, 0.01) / 1_000
        return exp(-1 / (seconds * sampleRate))
    }
}

struct ClipAudioProcessorState: Sendable {
    static let maxChannels = 8

    private var low = [BiquadState](repeating: BiquadState(), count: maxChannels)
    private var mid = [BiquadState](repeating: BiquadState(), count: maxChannels)
    private var high = [BiquadState](repeating: BiquadState(), count: maxChannels)
    private var envelope: Double = 0

    init() {}

    mutating func reset() {
        for i in 0..<Self.maxChannels {
            low[i].reset()
            mid[i].reset()
            high[i].reset()
        }
        envelope = 0
    }

    mutating func process(
        channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>,
        stride: Int,
        frameCount: Int,
        configuration: ClipAudioProcessorConfiguration
    ) {
        guard frameCount > 0, !channels.isEmpty, stride > 0 else { return }
        let channelCount = min(channels.count, Self.maxChannels)

        if configuration.hasEQ {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let index = frame * stride
                    var value = Double(samples[index])
                    if !configuration.lowShelf.isIdentity { value = low[channel].process(value, configuration.lowShelf) }
                    if !configuration.mid.isIdentity { value = mid[channel].process(value, configuration.mid) }
                    if !configuration.highShelf.isIdentity { value = high[channel].process(value, configuration.highShelf) }
                    samples[index] = Float(value)
                }
            }
        }

        if let compressor = configuration.compressor {
            let threshold = pow(10, compressor.thresholdDb / 20)
            let slope = 1 - 1 / max(compressor.ratio, 1)
            for frame in 0..<frameCount {
                let index = frame * stride
                var peak: Double = 0
                for channel in 0..<channelCount {
                    peak = max(peak, abs(Double(channels[channel][index])))
                }
                let coefficient = peak > envelope ? configuration.attackCoefficient : configuration.releaseCoefficient
                envelope = coefficient * envelope + (1 - coefficient) * peak
                var gain = configuration.makeupGain
                if envelope > threshold, envelope > 0 {
                    gain *= pow(threshold / envelope, slope)
                }
                if gain != 1 {
                    for channel in 0..<channelCount {
                        channels[channel][index] = Float(Double(channels[channel][index]) * gain)
                    }
                }
            }
        }

        if configuration.hasPan, channelCount >= 2 {
            for frame in 0..<frameCount {
                let index = frame * stride
                channels[0][index] = Float(Double(channels[0][index]) * configuration.leftGain)
                channels[1][index] = Float(Double(channels[1][index]) * configuration.rightGain)
            }
        }
    }
}

extension ClipAudioProcessorState {
    mutating func process(_ planes: inout [[Float]], configuration: ClipAudioProcessorConfiguration) {
        guard let frameCount = planes.first?.count, frameCount > 0,
              planes.allSatisfy({ $0.count == frameCount }) else { return }
        let channelCount = planes.count
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * frameCount)
        defer { storage.deallocate() }
        for channel in 0..<channelCount {
            planes[channel].withUnsafeBufferPointer {
                storage.advanced(by: channel * frameCount).update(from: $0.baseAddress!, count: frameCount)
            }
        }
        var pointers = (0..<channelCount).map { storage.advanced(by: $0 * frameCount) }
        pointers.withUnsafeMutableBufferPointer {
            process(channels: $0, stride: 1, frameCount: frameCount, configuration: configuration)
        }
        for channel in 0..<channelCount {
            planes[channel].withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: storage.advanced(by: channel * frameCount), count: frameCount)
            }
        }
    }
}
