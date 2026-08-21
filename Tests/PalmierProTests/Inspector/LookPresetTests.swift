import Testing
@testable import PalmierPro

struct LookPresetTests {
    @Test(arguments: LookPreset.allCases)
    func adjustmentsMatchRegistrySpecs(preset: LookPreset) throws {
        #expect(!preset.adjustments.isEmpty)
        #expect(preset.preset.payload.matches(.look))
        for adjustment in preset.adjustments {
            let descriptor = try #require(EffectRegistry.descriptor(id: adjustment.type))
            for (key, value) in adjustment.params {
                let spec = try #require(descriptor.params.first { $0.key == key })
                #expect(spec.range.contains(value))
                #expect(value != spec.defaultValue)
            }
        }
    }

    @Test
    func applyingPresetOverEarlierPresetLeavesOneEffectPerType() {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 60)
        for look in [LookPreset.cinematic, .moody] {
            clip.absorb([.color], from: look.preset.donorClip)
        }
        let types = clip.effects?.map(\.type) ?? []
        #expect(types.count == Set(types).count)
        #expect(Set(types) == Set(LookPreset.moody.adjustments.map(\.type)))
    }

    @Test
    func applyingPresetReplacesTheWholeGradeButKeepsOtherEffects() {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 60)
        clip.effects = [
            Effect.make("color.lut", [:]),
            Effect.make("blur.gaussian", ["radius": 4]),
        ]
        clip.absorb([.color], from: LookPreset.monochrome.preset.donorClip)
        let types = clip.effects?.map(\.type) ?? []
        #expect(!types.contains("color.lut"))
        #expect(types.contains("blur.gaussian"))
        #expect(Set(types).isSuperset(of: LookPreset.monochrome.adjustments.map(\.type)))
    }
}
