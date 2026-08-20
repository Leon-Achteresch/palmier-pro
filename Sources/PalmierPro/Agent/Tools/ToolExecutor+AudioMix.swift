import Foundation

struct ParsedAudioMix: Decodable {
    var pan: Double?
    var eq: ParsedAudioEQ?
    var compressor: ParsedAudioCompressor?
    var reset: Bool?

    static let allowedKeys: Set<String> = ["pan", "eq", "compressor", "reset"]

    var hasAnyField: Bool {
        pan != nil || eq?.hasAnyField == true || compressor?.hasAnyField == true || reset != nil
    }

    func validated(path: String) throws {
        guard hasAnyField else {
            throw ToolError("\(path): pass at least one of pan, eq, compressor, reset")
        }
        if reset == true, pan != nil || eq?.hasAnyField == true || compressor?.hasAnyField == true {
            throw ToolError("\(path).reset clears the whole mix — call it without other fields")
        }
        if let pan {
            try Self.require(pan, in: ClipAudioMixLimits.pan, name: "\(path).pan")
        }
        if let eq {
            try eq.validated(path: "\(path).eq")
        }
        if let compressor {
            try compressor.validated(path: "\(path).compressor")
        }
    }

    func apply(to clip: inout Clip) {
        if reset == true {
            clip.audioMix = nil
            return
        }
        var mix = clip.audioMix ?? ClipAudioMix()
        if let pan { mix.pan = pan }
        if let eq, eq.hasAnyField {
            var settings = mix.eq ?? AudioEQSettings()
            eq.apply(to: &settings)
            mix.eq = settings
        }
        if let compressor, compressor.hasAnyField {
            if compressor.enabled == false {
                mix.compressor = nil
            } else {
                var settings = mix.compressor ?? AudioCompressorSettings()
                compressor.apply(to: &settings)
                mix.compressor = settings
            }
        }
        clip.audioMix = mix.normalized
    }

    static func require(_ value: Double, in range: ClosedRange<Double>, name: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw ToolError("\(name) must be between \(range.lowerBound) and \(range.upperBound) (got \(value))")
        }
    }
}

struct ParsedAudioEQ: Decodable {
    var lowGainDb: Double?
    var midGainDb: Double?
    var highGainDb: Double?
    var midFrequency: Double?

    static let allowedKeys: Set<String> = ["lowGainDb", "midGainDb", "highGainDb", "midFrequency"]

    var hasAnyField: Bool {
        lowGainDb != nil || midGainDb != nil || highGainDb != nil || midFrequency != nil
    }

    func validated(path: String) throws {
        for (name, value) in [
            ("lowGainDb", lowGainDb), ("midGainDb", midGainDb), ("highGainDb", highGainDb),
        ] {
            guard let value else { continue }
            try ParsedAudioMix.require(value, in: ClipAudioMixLimits.eqGainDb, name: "\(path).\(name)")
        }
        if let midFrequency {
            try ParsedAudioMix.require(midFrequency, in: ClipAudioMixLimits.midFrequency, name: "\(path).midFrequency")
        }
    }

    func apply(to settings: inout AudioEQSettings) {
        if let lowGainDb { settings.lowGainDb = lowGainDb }
        if let midGainDb { settings.midGainDb = midGainDb }
        if let highGainDb { settings.highGainDb = highGainDb }
        if let midFrequency { settings.midFrequency = midFrequency }
    }
}

struct ParsedAudioCompressor: Decodable {
    var enabled: Bool?
    var thresholdDb: Double?
    var ratio: Double?
    var attackMs: Double?
    var releaseMs: Double?
    var makeupGainDb: Double?

    static let allowedKeys: Set<String> = [
        "enabled", "thresholdDb", "ratio", "attackMs", "releaseMs", "makeupGainDb",
    ]

    var hasAnyField: Bool {
        enabled != nil || thresholdDb != nil || ratio != nil
            || attackMs != nil || releaseMs != nil || makeupGainDb != nil
    }

    private var hasParameterField: Bool {
        thresholdDb != nil || ratio != nil || attackMs != nil || releaseMs != nil || makeupGainDb != nil
    }

    func validated(path: String) throws {
        if enabled == false, hasParameterField {
            throw ToolError("\(path).enabled false removes compression — call it without parameter fields")
        }
        for (name, value, range) in [
            ("thresholdDb", thresholdDb, ClipAudioMixLimits.thresholdDb),
            ("ratio", ratio, ClipAudioMixLimits.ratio),
            ("attackMs", attackMs, ClipAudioMixLimits.attackMs),
            ("releaseMs", releaseMs, ClipAudioMixLimits.releaseMs),
            ("makeupGainDb", makeupGainDb, ClipAudioMixLimits.makeupGainDb),
        ] {
            guard let value else { continue }
            try ParsedAudioMix.require(value, in: range, name: "\(path).\(name)")
        }
    }

    func apply(to settings: inout AudioCompressorSettings) {
        if let thresholdDb { settings.thresholdDb = thresholdDb }
        if let ratio { settings.ratio = ratio }
        if let attackMs { settings.attackMs = attackMs }
        if let releaseMs { settings.releaseMs = releaseMs }
        if let makeupGainDb { settings.makeupGainDb = makeupGainDb }
    }
}
