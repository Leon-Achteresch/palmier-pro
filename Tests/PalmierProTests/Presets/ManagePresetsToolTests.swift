import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — manage_presets")
@MainActor
struct ManagePresetsToolTests {
    private func harness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "source-clip", start: 0, duration: 120),
                Fixtures.clip(id: "target-clip", start: 120, duration: 120),
                Fixtures.clip(id: "text-clip", mediaType: .text, start: 240, duration: 60),
            ]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "audio-clip", mediaType: .audio, start: 0, duration: 120)]),
        ]))
    }

    private func gradeSource(_ h: ToolHarness) {
        h.editor.timeline.tracks[0].clips[0].effects = [
            Effect.make("color.exposure", ["ev": 0.5]),
            Effect.make("color.saturation", ["amount": 1.4]),
            Effect.make("stylize.grain", ["amount": 0.3]),
        ]
    }

    private func presets(_ json: Any?) -> [[String: Any]] {
        ((json as? [String: Any])?["presets"] as? [[String: Any]]) ?? []
    }

    @Test func listsBuiltInLooksBeforeAnythingIsSaved() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }

        let json = try await h.runOK("manage_presets", args: ["action": "list", "kind": "look"])
        let looks = presets(json)
        #expect(looks.count == LookPreset.allCases.count)
        #expect(looks.allSatisfy { $0["builtIn"] as? Bool == true })
        #expect(looks.first?["color"] != nil)
        #expect((json as? [String: Any])?["count"] as? Int == LookPreset.allCases.count)
    }

    @Test func savesALookFromAClipAndReportsItInApplyColorVocabulary() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ]) as? [String: Any]
        #expect(saved?["name"] as? String == "Warm")
        #expect(saved?["kind"] as? String == "look")
        #expect(saved?["savedFromClipId"] as? String == "source-clip")
        let color = try #require(saved?["color"] as? [String: Any])
        #expect((color["exposure"] as? NSNumber)?.doubleValue == 0.5)
        #expect((color["saturation"] as? NSNumber)?.doubleValue == 1.4)
        #expect(saved?["effects"] == nil)

        let listed = presets(try await h.runOK("manage_presets", args: ["action": "list", "kind": "look"]))
        #expect(listed.filter { $0["builtIn"] == nil }.count == 1)
    }

    @Test func savedEffectStackExcludesTheGrade() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "effects", "sourceClipId": "source-clip",
        ]) as? [String: Any]
        let effects = try #require(saved?["effects"] as? [[String: Any]])
        #expect(effects.map { $0["type"] as? String } == ["stylize.grain"])
        #expect(saved?["color"] == nil)
    }

    @Test func appliedLookMatchesCopyAttributesOnTheSameFixture() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)
        h.editor.timeline.tracks[0].clips[1].effects = [
            Effect.make("color.contrast", ["amount": 1.8]),
            Effect.make("blur.gaussian", ["radius": 4]),
        ]

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ]) as? [String: Any]
        let presetId = try #require(saved?["presetId"] as? String)
        _ = try await h.runOK("manage_presets", args: [
            "action": "apply", "presetId": presetId, "clipIds": ["target-clip"],
        ])
        let viaPreset = try #require(h.editor.clipFor(id: "target-clip")?.effects)

        let reference = harness()
        defer { reference.removePresetLibrary() }
        gradeSource(reference)
        reference.editor.timeline.tracks[0].clips[1].effects = [
            Effect.make("color.contrast", ["amount": 1.8]),
            Effect.make("blur.gaussian", ["radius": 4]),
        ]
        _ = try await reference.runOK("copy_attributes", args: [
            "fromClipId": "source-clip", "toClipIds": ["target-clip"], "attributes": ["color"],
        ])
        let viaCopy = try #require(reference.editor.clipFor(id: "target-clip")?.effects)

        #expect(viaPreset.map(\.type) == viaCopy.map(\.type))
        #expect(viaPreset.map(\.params) == viaCopy.map(\.params))
        #expect(viaPreset.map(\.type) == ["color.exposure", "color.saturation", "blur.gaussian"])
    }

    @Test func appliedEffectStackReplacesTheNonColorStackLikeCopyAttributes() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)
        h.editor.timeline.tracks[0].clips[1].effects = [
            Effect.make("color.contrast", ["amount": 1.8]),
            Effect.make("blur.gaussian", ["radius": 4]),
        ]

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "effects", "sourceClipId": "source-clip",
        ]) as? [String: Any]
        let presetId = try #require(saved?["presetId"] as? String)
        _ = try await h.runOK("manage_presets", args: [
            "action": "apply", "presetId": presetId, "clipIds": ["target-clip"],
        ])
        let viaPreset = try #require(h.editor.clipFor(id: "target-clip")?.effects)

        let reference = harness()
        defer { reference.removePresetLibrary() }
        gradeSource(reference)
        reference.editor.timeline.tracks[0].clips[1].effects = [
            Effect.make("color.contrast", ["amount": 1.8]),
            Effect.make("blur.gaussian", ["radius": 4]),
        ]
        _ = try await reference.runOK("copy_attributes", args: [
            "fromClipId": "source-clip", "toClipIds": ["target-clip"], "attributes": ["effects"],
        ])
        let viaCopy = try #require(reference.editor.clipFor(id: "target-clip")?.effects)

        #expect(viaPreset.map(\.type) == viaCopy.map(\.type))
        #expect(viaPreset.map(\.type) == ["color.contrast", "stylize.grain"])
    }

    @Test func applyingALookIsOneUndoEntry() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)
        h.editor.timeline.tracks[0].clips[1].effects = [Effect.make("color.contrast", ["amount": 1.8])]

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ]) as? [String: Any]
        let presetId = try #require(saved?["presetId"] as? String)

        let manager = UndoManager()
        h.editor.undo.attach(manager)
        _ = try await h.runOK("manage_presets", args: [
            "action": "apply", "presetId": presetId, "clipIds": ["source-clip", "target-clip", "text-clip"],
        ])
        #expect(manager.canUndo)
        #expect(manager.undoActionName.contains("Warm"))

        manager.undo()
        #expect(h.editor.clipFor(id: "target-clip")?.effects?.map(\.type) == ["color.contrast"])
        #expect(h.editor.clipFor(id: "text-clip")?.effects == nil)
        #expect(!manager.canUndo)
    }

    @Test func appliesABuiltInLookByItsStableId() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }

        _ = try await h.runOK("manage_presets", args: [
            "action": "apply", "presetId": LookPreset.moody.preset.id, "clipIds": ["target-clip"],
        ])
        let types = try #require(h.editor.clipFor(id: "target-clip")?.effects?.map(\.type))
        #expect(Set(types) == Set(LookPreset.moody.adjustments.map(\.type)))
    }

    @Test func renamesAndDeletesSavedPresets() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ]) as? [String: Any]
        let presetId = try #require(saved?["presetId"] as? String)

        let renamed = try await h.runOK("manage_presets", args: [
            "action": "rename", "presetId": presetId, "name": "Sunset",
        ]) as? [String: Any]
        #expect(renamed?["name"] as? String == "Sunset")

        let deleted = try await h.runOK("manage_presets", args: ["action": "delete", "presetId": presetId]) as? [String: Any]
        #expect((deleted?["deleted"] as? [String: Any])?["name"] as? String == "Sunset")

        let remaining = presets(try await h.runOK("manage_presets", args: ["action": "list", "kind": "look"]))
        #expect(remaining.allSatisfy { $0["builtIn"] as? Bool == true })
    }

    @Test func suffixesDuplicateNamesAndSaysSo() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)

        _ = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ])
        let second = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ]) as? [String: Any]
        #expect(second?["name"] as? String == "Warm 2")
        #expect((second?["notes"] as? [String])?.isEmpty == false)
    }

    @Test func savesAndAppliesATextStyleOnlyToTextClips() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        var style = TextStyle()
        style.fontSize = 140
        style.alignment = .left
        h.editor.timeline.tracks[0].clips[2].textStyle = style
        h.editor.timeline.tracks[0].clips[2].textContent = "Headline"

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "textStyle", "sourceClipId": "text-clip",
        ]) as? [String: Any]
        #expect(saved?["name"] as? String == "Headline")
        let payload = try #require(saved?["textStyle"] as? [String: Any])
        #expect((payload["fontSize"] as? NSNumber)?.doubleValue == 140)
        #expect(payload["alignment"] as? String == "left")

        let presetId = try #require(saved?["presetId"] as? String)
        let rejected = await h.runRaw("manage_presets", args: [
            "action": "apply", "presetId": presetId, "clipIds": ["target-clip"],
        ])
        #expect(rejected.isError)
        #expect(ToolHarness.textOf(rejected).contains("text clip"))
        #expect(h.editor.clipFor(id: "target-clip")?.textStyle == nil)
    }

    @Test func rejectsUnknownKindsMissingPresetsAndEmptySources() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }

        let unknownKind = await h.runRaw("manage_presets", args: [
            "action": "save", "kind": "grade", "sourceClipId": "source-clip",
        ])
        #expect(ToolHarness.textOf(unknownKind).contains("unknown kind"))

        let unknownAction = await h.runRaw("manage_presets", args: ["action": "duplicate"])
        #expect(ToolHarness.textOf(unknownAction).contains("unknown action"))

        let missing = await h.runRaw("manage_presets", args: [
            "action": "apply", "presetId": "look.nope", "clipIds": ["target-clip"],
        ])
        #expect(ToolHarness.textOf(missing).contains("Preset not found"))

        let ungraded = await h.runRaw("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip",
        ])
        #expect(ToolHarness.textOf(ungraded).contains("carries no look"))

        let audioSource = await h.runRaw("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "audio-clip",
        ])
        #expect(ToolHarness.textOf(audioSource).contains("audio"))

        let builtInDelete = await h.runRaw("manage_presets", args: [
            "action": "delete", "presetId": LookPreset.vintage.preset.id,
        ])
        #expect(ToolHarness.textOf(builtInDelete).contains("built-in"))

        let unknownField = await h.runRaw("manage_presets", args: ["action": "list", "colour": "look"])
        #expect(ToolHarness.textOf(unknownField).contains("unknown field"))
    }

    @Test func presetIdsAreShortenedOnOutputAndAcceptedBackAsPrefixes() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ]) as? [String: Any]
        let shortId = try #require(saved?["presetId"] as? String)
        #expect(shortId.count < 36)

        let receipt = try await h.runOK("manage_presets", args: [
            "action": "apply", "presetId": shortId, "clipIds": ["target-clip"],
        ]) as? [String: Any]
        #expect((receipt?["preset"] as? [String: Any])?["name"] as? String == "Warm")
        #expect(h.editor.clipFor(id: "target-clip")?.effects?.map(\.type) == ["color.exposure", "color.saturation"])
    }

    @Test func renamingABuiltInLookIsRefused() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }

        let refused = await h.runRaw("manage_presets", args: [
            "action": "rename", "presetId": LookPreset.cinematic.preset.id, "name": "Mine",
        ])
        #expect(refused.isError)
        #expect(ToolHarness.textOf(refused).contains("built-in"))
    }

    @Test func applyingToAnAudioClipIsRefusedBeforeAnyMutation() async throws {
        let h = harness()
        defer { h.removePresetLibrary() }
        gradeSource(h)

        let saved = try await h.runOK("manage_presets", args: [
            "action": "save", "kind": "look", "sourceClipId": "source-clip", "name": "Warm",
        ]) as? [String: Any]
        let presetId = try #require(saved?["presetId"] as? String)

        let manager = UndoManager()
        h.editor.undo.attach(manager)
        let refused = await h.runRaw("manage_presets", args: [
            "action": "apply", "presetId": presetId, "clipIds": ["target-clip", "audio-clip"],
        ])
        #expect(refused.isError)
        #expect(h.editor.clipFor(id: "target-clip")?.effects == nil)
        #expect(!manager.canUndo)
    }
}
