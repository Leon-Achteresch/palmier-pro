import Foundation

struct LoudnessMeasurement: Sendable, Equatable {
    let integratedLufs: Double?
    let truePeakDbtp: Double?
    let analyzedSeconds: Double

    static let silent = LoudnessMeasurement(integratedLufs: nil, truePeakDbtp: nil, analyzedSeconds: 0)
}

struct LoudnessMeter {
    static let sampleRate: Double = 48_000
    static let subBlockFrames = 4_800
    static let blockSubBlocks = 4
    static let absoluteGateLufs: Double = -70
    static let offsetDb: Double = -0.691

    private static let preFilter = Biquad(
        b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
        a1: -1.69065929318241, a2: 0.73248077421585
    )
    private static let highPass = Biquad(
        b0: 1.0, b1: -2.0, b2: 1.0,
        a1: -1.99004745483398, a2: 0.99007225036621
    )

    private let channelCount: Int
    private var preState: [BiquadState]
    private var highState: [BiquadState]
    private var subBlockSum: Double = 0
    private var subBlockFilled = 0
    private var subBlockSums: [Double] = []
    private var blockPowers: [Double] = []
    private var truePeak: TruePeakDetector
    private var totalFrames = 0

    init(channelCount: Int) {
        let channels = max(1, min(channelCount, ClipAudioProcessorState.maxChannels))
        self.channelCount = channels
        preState = Array(repeating: BiquadState(), count: channels)
        highState = Array(repeating: BiquadState(), count: channels)
        truePeak = TruePeakDetector(channelCount: channels)
    }

    mutating func ingest(_ planes: [[Float]]) {
        guard let frameCount = planes.first?.count, frameCount > 0 else { return }
        truePeak.ingest(planes)
        for frame in 0..<frameCount {
            var weightedSum: Double = 0
            for channel in 0..<min(channelCount, planes.count) {
                guard frame < planes[channel].count else { continue }
                let filtered = highState[channel].process(
                    preState[channel].process(Double(planes[channel][frame]), Self.preFilter),
                    Self.highPass
                )
                weightedSum += filtered * filtered
            }
            subBlockSum += weightedSum
            subBlockFilled += 1
            if subBlockFilled == Self.subBlockFrames {
                closeSubBlock()
            }
        }
        totalFrames += frameCount
    }

    private mutating func closeSubBlock() {
        subBlockSums.append(subBlockSum)
        if subBlockSums.count > Self.blockSubBlocks { subBlockSums.removeFirst() }
        if subBlockSums.count == Self.blockSubBlocks {
            let frames = Double(Self.subBlockFrames * Self.blockSubBlocks)
            blockPowers.append(subBlockSums.reduce(0, +) / frames)
        }
        subBlockSum = 0
        subBlockFilled = 0
    }

    func measurement() -> LoudnessMeasurement {
        LoudnessMeasurement(
            integratedLufs: Self.integrated(blockPowers: blockPowers),
            truePeakDbtp: truePeak.peak > 0 ? 20 * log10(truePeak.peak) : nil,
            analyzedSeconds: Double(totalFrames) / Self.sampleRate
        )
    }

    static func integrated(blockPowers: [Double]) -> Double? {
        let absoluteThreshold = pow(10, (absoluteGateLufs - offsetDb) / 10)
        let aboveAbsolute = blockPowers.filter { $0 > 0 && $0 >= absoluteThreshold }
        guard !aboveAbsolute.isEmpty else { return nil }
        let mean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let relativeThreshold = mean / 10
        let gated = aboveAbsolute.filter { $0 >= relativeThreshold }
        guard !gated.isEmpty else { return nil }
        let gatedMean = gated.reduce(0, +) / Double(gated.count)
        guard gatedMean > 0 else { return nil }
        return offsetDb + 10 * log10(gatedMean)
    }
}

struct TruePeakDetector {
    private static let halfTaps = 6
    private static let tapCount = halfTaps * 2
    private static let phases: [[Double]] = (1...3).map { phase in
        coefficients(delay: Double(phase) / 4)
    }

    private var tails: [[Float]]
    private(set) var peak: Double = 0

    init(channelCount: Int = 2) {
        tails = Array(repeating: [], count: max(1, channelCount))
    }

    mutating func ingest(_ planes: [[Float]]) {
        for channel in 0..<min(tails.count, planes.count) {
            var samples = tails[channel]
            samples.append(contentsOf: planes[channel])
            scan(samples)
            let keep = min(samples.count, Self.tapCount)
            tails[channel] = Array(samples.suffix(keep))
        }
    }

    private mutating func scan(_ samples: [Float]) {
        guard samples.count > 2 else {
            for sample in samples { peak = max(peak, abs(Double(sample))) }
            return
        }
        var samplePeak: Double = 0
        for sample in samples { samplePeak = max(samplePeak, abs(Double(sample))) }
        peak = max(peak, samplePeak)
        guard samplePeak > 0 else { return }
        let gate = samplePeak * 0.5
        for index in 1..<(samples.count - 1) {
            let magnitude = abs(Double(samples[index]))
            guard magnitude >= gate,
                  magnitude >= abs(Double(samples[index - 1])),
                  magnitude >= abs(Double(samples[index + 1])) else { continue }
            for origin in [index - 1, index] {
                for phase in Self.phases {
                    var sum: Double = 0
                    for tap in 0..<Self.tapCount {
                        let position = origin - Self.halfTaps + 1 + tap
                        guard position >= 0, position < samples.count else { continue }
                        sum += Double(samples[position]) * phase[tap]
                    }
                    peak = max(peak, abs(sum))
                }
            }
        }
    }

    private static func coefficients(delay: Double) -> [Double] {
        var taps = [Double](repeating: 0, count: tapCount)
        var sum: Double = 0
        for index in 0..<tapCount {
            let t = Double(index - halfTaps + 1) - delay
            let window = 0.42 + 0.5 * cos(Double.pi * t / Double(halfTaps))
                + 0.08 * cos(2 * Double.pi * t / Double(halfTaps))
            let value = sinc(t) * window
            taps[index] = value
            sum += value
        }
        guard sum != 0 else { return taps }
        return taps.map { $0 / sum }
    }

    private static func sinc(_ t: Double) -> Double {
        guard abs(t) > 1e-9 else { return 1 }
        let x = Double.pi * t
        return sin(x) / x
    }
}
