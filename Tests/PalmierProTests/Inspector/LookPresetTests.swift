import Testing
@testable import PalmierPro

struct LookPresetTests {
    @Test(arguments: LookPreset.allCases)
    func adjustmentsMatchRegistrySpecs(preset: LookPreset) throws {
        #expect(!preset.adjustments.isEmpty)
        for adjustment in preset.adjustments {
            #expect(LookPreset.effectIds.contains(adjustment.type))
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
        var effects: [Effect] = []
        for preset in [LookPreset.cinematic, .moody] {
            effects.removeAll { LookPreset.effectIds.contains($0.type) }
            for adjustment in preset.adjustments {
                effects.insert(
                    Effect.make(adjustment.type, adjustment.params),
                    at: EffectRegistry.insertIndex(effects, for: adjustment.type)
                )
            }
        }
        let types = effects.map(\.type)
        #expect(types.count == Set(types).count)
        #expect(Set(types) == Set(LookPreset.moody.adjustments.map(\.type)))
    }
}
