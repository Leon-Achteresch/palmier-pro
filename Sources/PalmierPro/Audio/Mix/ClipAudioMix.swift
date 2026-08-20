import Foundation

struct ClipAudioMix: Sendable, Equatable, Codable {
    var pan: Double = ClipAudioMixLimits.panDefault
    var eq: AudioEQSettings?
    var compressor: AudioCompressorSettings?

    init(
        pan: Double = ClipAudioMixLimits.panDefault,
        eq: AudioEQSettings? = nil,
        compressor: AudioCompressorSettings? = nil
    ) {
        self.pan = pan
        self.eq = eq
        self.compressor = compressor
    }

    var isBypass: Bool {
        pan == 0 && (eq?.isFlat ?? true) && compressor == nil
    }

    var normalized: ClipAudioMix? {
        var mix = self
        if mix.eq?.isFlat ?? false { mix.eq = nil }
        return mix.isBypass ? nil : mix
    }

    private enum CodingKeys: String, CodingKey { case pan, eq, compressor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pan = ClipAudioMixLimits.clamp(
            (try? c.decode(Double.self, forKey: .pan)) ?? ClipAudioMixLimits.panDefault,
            to: ClipAudioMixLimits.pan
        )
        eq = try? c.decode(AudioEQSettings.self, forKey: .eq)
        compressor = try? c.decode(AudioCompressorSettings.self, forKey: .compressor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if pan != ClipAudioMixLimits.panDefault { try c.encode(pan, forKey: .pan) }
        try c.encodeIfPresent(eq, forKey: .eq)
        try c.encodeIfPresent(compressor, forKey: .compressor)
    }
}

struct AudioEQSettings: Sendable, Equatable, Codable {
    var lowGainDb: Double = 0
    var midGainDb: Double = 0
    var highGainDb: Double = 0
    var midFrequency: Double = ClipAudioMixLimits.midFrequencyDefault

    static let lowShelfFrequency: Double = 120
    static let highShelfFrequency: Double = 8_000
    static let shelfSlope: Double = 0.7
    static let midQ: Double = 1.0

    var isFlat: Bool { lowGainDb == 0 && midGainDb == 0 && highGainDb == 0 }

    private enum CodingKeys: String, CodingKey { case lowGainDb, midGainDb, highGainDb, midFrequency }

    init(
        lowGainDb: Double = 0,
        midGainDb: Double = 0,
        highGainDb: Double = 0,
        midFrequency: Double = ClipAudioMixLimits.midFrequencyDefault
    ) {
        self.lowGainDb = lowGainDb
        self.midGainDb = midGainDb
        self.highGainDb = highGainDb
        self.midFrequency = midFrequency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let gain = ClipAudioMixLimits.eqGainDb
        lowGainDb = ClipAudioMixLimits.clamp((try? c.decode(Double.self, forKey: .lowGainDb)) ?? 0, to: gain)
        midGainDb = ClipAudioMixLimits.clamp((try? c.decode(Double.self, forKey: .midGainDb)) ?? 0, to: gain)
        highGainDb = ClipAudioMixLimits.clamp((try? c.decode(Double.self, forKey: .highGainDb)) ?? 0, to: gain)
        midFrequency = ClipAudioMixLimits.clamp(
            (try? c.decode(Double.self, forKey: .midFrequency)) ?? ClipAudioMixLimits.midFrequencyDefault,
            to: ClipAudioMixLimits.midFrequency
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if lowGainDb != 0 { try c.encode(lowGainDb, forKey: .lowGainDb) }
        if midGainDb != 0 { try c.encode(midGainDb, forKey: .midGainDb) }
        if highGainDb != 0 { try c.encode(highGainDb, forKey: .highGainDb) }
        if midFrequency != ClipAudioMixLimits.midFrequencyDefault { try c.encode(midFrequency, forKey: .midFrequency) }
    }
}

struct AudioCompressorSettings: Sendable, Equatable, Codable {
    var thresholdDb: Double = ClipAudioMixLimits.thresholdDbDefault
    var ratio: Double = ClipAudioMixLimits.ratioDefault
    var attackMs: Double = ClipAudioMixLimits.attackMsDefault
    var releaseMs: Double = ClipAudioMixLimits.releaseMsDefault
    var makeupGainDb: Double = 0

    private enum CodingKeys: String, CodingKey { case thresholdDb, ratio, attackMs, releaseMs, makeupGainDb }

    init(
        thresholdDb: Double = ClipAudioMixLimits.thresholdDbDefault,
        ratio: Double = ClipAudioMixLimits.ratioDefault,
        attackMs: Double = ClipAudioMixLimits.attackMsDefault,
        releaseMs: Double = ClipAudioMixLimits.releaseMsDefault,
        makeupGainDb: Double = 0
    ) {
        self.thresholdDb = thresholdDb
        self.ratio = ratio
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.makeupGainDb = makeupGainDb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thresholdDb = ClipAudioMixLimits.clamp(
            (try? c.decode(Double.self, forKey: .thresholdDb)) ?? ClipAudioMixLimits.thresholdDbDefault,
            to: ClipAudioMixLimits.thresholdDb
        )
        ratio = ClipAudioMixLimits.clamp(
            (try? c.decode(Double.self, forKey: .ratio)) ?? ClipAudioMixLimits.ratioDefault,
            to: ClipAudioMixLimits.ratio
        )
        attackMs = ClipAudioMixLimits.clamp(
            (try? c.decode(Double.self, forKey: .attackMs)) ?? ClipAudioMixLimits.attackMsDefault,
            to: ClipAudioMixLimits.attackMs
        )
        releaseMs = ClipAudioMixLimits.clamp(
            (try? c.decode(Double.self, forKey: .releaseMs)) ?? ClipAudioMixLimits.releaseMsDefault,
            to: ClipAudioMixLimits.releaseMs
        )
        makeupGainDb = ClipAudioMixLimits.clamp(
            (try? c.decode(Double.self, forKey: .makeupGainDb)) ?? 0,
            to: ClipAudioMixLimits.makeupGainDb
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(thresholdDb, forKey: .thresholdDb)
        try c.encode(ratio, forKey: .ratio)
        try c.encode(attackMs, forKey: .attackMs)
        try c.encode(releaseMs, forKey: .releaseMs)
        if makeupGainDb != 0 { try c.encode(makeupGainDb, forKey: .makeupGainDb) }
    }
}

enum ClipAudioMixLimits {
    static let pan: ClosedRange<Double> = -1...1
    static let eqGainDb: ClosedRange<Double> = -24...24
    static let midFrequency: ClosedRange<Double> = 200...8_000
    static let thresholdDb: ClosedRange<Double> = -60...0
    static let ratio: ClosedRange<Double> = 1...60
    static let attackMs: ClosedRange<Double> = 0.1...200
    static let releaseMs: ClosedRange<Double> = 5...2_000
    static let makeupGainDb: ClosedRange<Double> = -24...24

    static let panDefault: Double = 0
    static let midFrequencyDefault: Double = 1_000
    static let thresholdDbDefault: Double = -18
    static let ratioDefault: Double = 4
    static let attackMsDefault: Double = 10
    static let releaseMsDefault: Double = 120

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return min(max(0, range.lowerBound), range.upperBound) }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

