import Accelerate

enum VoiceMastering {
    static let targetRms: Float = 0.112
    static let peakCeiling: Float = 0.89
    static let maxBoost: Float = 8
    static let gateMeanSquare: Float = 1e-6

    static func normalize(_ samples: inout [Float], sampleRate: Int) {
        var gain = normalizationGain(for: samples, sampleRate: sampleRate)
        guard gain != 1 else { return }
        vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))
    }

    static func normalizationGain(for samples: [Float], sampleRate: Int) -> Float {
        guard !samples.isEmpty, sampleRate > 0 else { return 1 }
        let block = max(1, sampleRate * 2 / 5)
        var energies: [Float] = []
        var start = 0
        samples.withUnsafeBufferPointer { buffer in
            while start < buffer.count {
                let length = min(block, buffer.count - start)
                var meanSquare: Float = 0
                vDSP_measqv(buffer.baseAddress! + start, 1, &meanSquare, vDSP_Length(length))
                if meanSquare > gateMeanSquare { energies.append(meanSquare) }
                start += length
            }
        }
        guard !energies.isEmpty else { return 1 }
        let meanSquare = energies.reduce(0, +) / Float(energies.count)
        guard meanSquare.isFinite, meanSquare > 0 else { return 1 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak.isFinite, peak > 0 else { return 1 }
        let loudnessGain = targetRms / sqrt(meanSquare)
        let peakGain = peakCeiling / peak
        return min(loudnessGain, peakGain, maxBoost)
    }
}
