import Testing
import Foundation
import SpeechRestoration
@testable import PalmierPro

struct AudioEnhancerRestoreTests {
    private let config = SidonConfig.default

    private func outputValue(_ index: Int) -> Float {
        sin(2 * .pi * 50 * Float(index) / Float(config.outputSampleRate))
    }

    private func restored(inputCount: Int) throws -> [Float] {
        let ratio = config.outputSampleRate / config.inputSampleRate
        let hop = config.windowSamples - config.inputSampleRate
        let input = [Float](repeating: 0, count: inputCount)
        var call = 0
        return try AudioEnhancer.overlapAddRestore(input, config: config) { _ in
            let outStart = call * hop * ratio
            call += 1
            return (0..<config.outputSamplesPerWindow).map { outputValue(outStart + $0) }
        }
    }

    @Test func outputMatchesInputDurationExactly() throws {
        let inputCount = config.inputSampleRate * 25
        let out = try restored(inputCount: inputCount)
        #expect(out.count == inputCount * 3)
    }

    @Test func windowJoinsAreContinuousWithoutDrift() throws {
        let inputCount = config.inputSampleRate * 25
        let out = try restored(inputCount: inputCount)
        var maxError: Float = 0
        for i in out.indices {
            maxError = max(maxError, abs(out[i] - outputValue(i)))
        }
        #expect(maxError < 1e-4)
    }

    @Test func shortInputProducesSingleWindowTrimmedToDuration() throws {
        let inputCount = config.inputSampleRate * 2
        let out = try restored(inputCount: inputCount)
        #expect(out.count == inputCount * 3)
        #expect(abs(out[out.count - 1] - outputValue(out.count - 1)) < 1e-4)
    }

    @Test func emptyInputProducesEmptyOutput() throws {
        #expect(try restored(inputCount: 0).isEmpty)
    }
}
