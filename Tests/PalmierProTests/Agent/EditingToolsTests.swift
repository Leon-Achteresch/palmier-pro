import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func harness(clipDuration: Int = 60, trimStart: Int = 30, trimEnd: Int = 30) -> (ToolHarness, String) {
    let clip = Fixtures.clip(id: "clip-a", start: 0, duration: clipDuration, trimStart: trimStart, trimEnd: trimEnd)
    let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
    h.addAsset(id: "media-1", duration: 10)
    return (h, clip.id)
}

/// Tool receipts report ids as unique prefixes; resolve one back to the live clip.
@MainActor
private func clip(forShortId shortId: String, in editor: EditorViewModel) -> Clip? {
    editor.timeline.tracks.flatMap(\.clips).first { $0.id.hasPrefix(shortId) }
}

@Suite("set_keyframes — multi-property")
@MainActor
struct SetKeyframesMultiTrackTests {

    @Test func tracksSetsEveryPropertyInOneUndoStep() async throws {
        let (h, clipId) = harness()
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)

        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "tracks": [
                "opacity": [[0, 0.0, "linear"], [30, 1.0]],
                "scale": [[0, 0.6, 0.6], [30, 1.0, 1.0]],
            ],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let clip = try #require(h.editor.clipFor(id: clipId))
        #expect(clip.opacityTrack?.keyframes.count == 2)
        #expect(clip.scaleTrack?.keyframes.count == 2)
        #expect(clip.opacityTrack?.keyframes.first?.interpolationOut == .linear)

        undoManager.undo()
        let restored = try #require(h.editor.clipFor(id: clipId))
        #expect(restored.opacityTrack == nil)
        #expect(restored.scaleTrack == nil)
    }

    @Test func clipIdsAppliesTheSameAnimationToEveryClip() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let b = Fixtures.clip(id: "clip-b", start: 30, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))

        let result = await h.runRaw("set_keyframes", args: [
            "clipIds": ["clip-a", "clip-b"],
            "property": "opacity",
            "keyframes": [[0, 0.0], [10, 1.0]],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.clipFor(id: "clip-a")?.opacityTrack?.keyframes.count == 2)
        #expect(h.editor.clipFor(id: "clip-b")?.opacityTrack?.keyframes.count == 2)
    }

    @Test func tracksRejectsMixingWithSingleTrackForm() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 1.0]],
            "tracks": ["scale": [[0, 1.0, 1.0]]],
        ])
        #expect(result.isError)
    }

    @Test func tracksRejectsUnknownPropertyBeforeMutating() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "tracks": ["opacity": [[0, 1.0]], "wobble": [[0, 1.0]]],
        ])
        #expect(result.isError)
        #expect(h.editor.clipFor(id: clipId)?.opacityTrack == nil)
    }

    @Test(arguments: ["easeIn", "easeOut", "backOut", "elasticOut", "bounceOut"])
    func acceptsNamedEasings(_ name: String) async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0, name], [30, 1.0]],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        let clip = try #require(h.editor.clipFor(id: clipId))
        #expect(clip.opacityTrack?.keyframes.first?.interpolationOut == Interpolation(rawValue: name))
    }

    @Test func staggerOffsetsKeyframesPerClipInOrder() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let b = Fixtures.clip(id: "clip-b", start: 30, duration: 30)
        let c = Fixtures.clip(id: "clip-c", start: 60, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b, c])]))

        let result = await h.runRaw("set_keyframes", args: [
            "clipIds": ["clip-a", "clip-b", "clip-c"],
            "property": "opacity",
            "keyframes": [[0, 0.0], [10, 1.0]],
            "stagger": 4,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.clipFor(id: "clip-a")?.opacityTrack?.keyframes.map(\.frame) == [0, 10])
        #expect(h.editor.clipFor(id: "clip-b")?.opacityTrack?.keyframes.map(\.frame) == [4, 14])
        #expect(h.editor.clipFor(id: "clip-c")?.opacityTrack?.keyframes.map(\.frame) == [8, 18])
    }

    @Test func staggerRequiresMultipleClips() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0], [10, 1.0]],
            "stagger": 4,
        ])
        #expect(result.isError)
    }

    @Test func mergeUpsertsIntoExistingTrack() async throws {
        let (h, clipId) = harness()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0], [10, 1.0], [30, 1.0]],
        ])
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[10, 0.5, "easeOut"], [20, 0.8]],
            "mode": "merge",
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        let track = try #require(h.editor.clipFor(id: clipId)?.opacityTrack)
        #expect(track.keyframes.map(\.frame) == [0, 10, 20, 30])
        #expect(track.keyframes[1].value == 0.5)
        #expect(track.keyframes[1].interpolationOut == .easeOut)
    }

    @Test func mergeRejectsEmptyRows() async throws {
        let (h, clipId) = harness()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0], [10, 1.0]],
        ])
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [],
            "mode": "merge",
        ])
        #expect(result.isError)
        #expect(h.editor.clipFor(id: clipId)?.opacityTrack?.keyframes.count == 2)
    }
}

@Suite("apply_effect — animated params")
@MainActor
struct ApplyEffectKeyframeTests {

    @Test func keyframeRowsBuildAnAnimatedParamTrack() async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId],
            "effects": [["type": "blur.gaussian", "params": ["radius": [[0, 0.0, "linear"], [30, 1.0]]]]],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let effect = try #require(h.editor.clipFor(id: clipId)?.effects?.first { $0.type == "blur.gaussian" })
        let track = try #require(effect.params["radius"]?.track)
        #expect(track.keyframes.map(\.frame) == [0, 30])
        #expect(track.keyframes.first?.interpolationOut == .linear)
        #expect(effect.params["radius"]?.resolved(at: 30, default: 0) == 1.0)
    }

    @Test func emptyRowsClearAnimationAndKeepStaticValue() async throws {
        let (h, clipId) = harness()
        _ = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId],
            "effects": [["type": "stylize.vignette", "params": ["amount": 0.5]]],
        ])
        _ = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId],
            "effects": [["type": "stylize.vignette", "params": ["amount": [[0, 0.1], [20, 0.9]]]]],
        ])
        let result = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId],
            "effects": [["type": "stylize.vignette", "params": ["amount": []]]],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let effect = try #require(h.editor.clipFor(id: clipId)?.effects?.first { $0.type == "stylize.vignette" })
        #expect(effect.params["amount"]?.track == nil)
        #expect(effect.params["amount"]?.value == 0.5)
    }

    @Test func staticParamsStillWork() async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId],
            "effects": [["type": "blur.gaussian", "params": ["radius": 0.4]]],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        let effect = try #require(h.editor.clipFor(id: clipId)?.effects?.first)
        #expect(effect.params["radius"]?.value == 0.4)
        #expect(effect.params["radius"]?.track == nil)
    }

    @Test func rejectsUnknownParamShape() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId],
            "effects": [["type": "blur.gaussian", "params": ["radius": "lots"]]],
        ])
        #expect(result.isError)
        #expect(h.editor.clipFor(id: clipId)?.effects == nil)
    }
}

@Suite("trim_clips")
@MainActor
struct TrimClipsTests {

    @Test func rippleTrimClosesTheGapForFollowingClips() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 60, trimStart: 0, trimEnd: 30)
        let b = Fixtures.clip(id: "clip-b", start: 60, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))
        h.addAsset(id: "media-1", duration: 10)

        let result = await h.runRaw("trim_clips", args: [
            "clipId": "clip-a", "mode": "ripple", "edge": "right", "deltaFrames": -20,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.clipFor(id: "clip-a")?.durationFrames == 40)
        #expect(h.editor.clipFor(id: "clip-b")?.startFrame == 40)
    }

    @Test func normalTrimLeavesFollowingClipsInPlace() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 60, trimStart: 0, trimEnd: 30)
        let b = Fixtures.clip(id: "clip-b", start: 60, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))
        h.addAsset(id: "media-1", duration: 10)

        let result = await h.runRaw("trim_clips", args: [
            "clipId": "clip-a", "edge": "right", "deltaFrames": -20,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.clipFor(id: "clip-a")?.durationFrames == 40)
        #expect(h.editor.clipFor(id: "clip-b")?.startFrame == 60)
    }

    @Test func slipMovesTheSourceRangeWithoutMovingTheClip() async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("trim_clips", args: [
            "clipId": clipId, "mode": "slip", "deltaFrames": 10,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let clip = try #require(h.editor.clipFor(id: clipId))
        #expect(clip.startFrame == 0)
        #expect(clip.durationFrames == 60)
        #expect(clip.trimStartFrame == 20)
        #expect(clip.trimEndFrame == 40)
    }

    @Test func slipRejectsAnEdgeArgument() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("trim_clips", args: [
            "clipId": clipId, "mode": "slip", "edge": "left", "deltaFrames": 5,
        ])
        #expect(result.isError)
    }

    @Test func refusesATrimThatWouldEmptyTheClip() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("trim_clips", args: [
            "clipId": clipId, "edge": "right", "deltaFrames": -60,
        ])
        #expect(result.isError)
        #expect(h.editor.clipFor(id: clipId)?.durationFrames == 60)
    }

    @Test func reportsNoopWhenThereIsNoMaterialLeft() async throws {
        let (h, clipId) = harness(trimStart: 0, trimEnd: 0)
        let result = await h.runRaw("trim_clips", args: [
            "clipId": clipId, "mode": "slip", "deltaFrames": 10,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(ToolHarness.textOf(result).contains("noop"))
    }
}

@Suite("duplicate_clips")
@MainActor
struct DuplicateClipsTests {

    @Test func copyKeepsLookAndKeyframesAndGetsANewId() async throws {
        let (h, clipId) = harness()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "opacity", "keyframes": [[0, 0.0], [20, 1.0]],
        ])
        _ = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId], "effects": [["type": "stylize.grain", "params": ["amount": 0.3]]],
        ])

        let json = try await h.runOK("duplicate_clips", args: [
            "placements": [["clipId": clipId, "toFrame": 120]],
        ]) as? [String: Any]
        let newIds = try #require(json?["newClipIds"] as? [String])
        #expect(newIds.count == 1)

        let copy = try #require(clip(forShortId: newIds[0], in: h.editor))
        #expect(copy.id != clipId)
        #expect(copy.startFrame == 120)
        #expect(copy.opacityTrack?.keyframes.count == 2)
        #expect(copy.effects?.contains { $0.type == "stylize.grain" } == true)
    }

    @Test func rejectsAnIncompatibleDestinationTrack() async {
        let clip = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]), Fixtures.audioTrack(),
        ]))
        let result = await h.runRaw("duplicate_clips", args: [
            "placements": [["clipId": "clip-a", "toFrame": 60, "toTrack": 1]],
        ])
        #expect(result.isError)
        #expect(h.editor.timeline.tracks[1].clips.isEmpty)
    }

    @Test func rejectsNegativeTargetFrame() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("duplicate_clips", args: [
            "placements": [["clipId": clipId, "toFrame": -1]],
        ])
        #expect(result.isError)
    }
}

@Suite("copy_attributes")
@MainActor
struct CopyAttributesTests {

    @Test func copiesOnlyTheRequestedGroups() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let b = Fixtures.clip(id: "clip-b", start: 30, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))
        _ = await h.runRaw("set_clip_properties", args: ["clipIds": ["clip-a"], "opacity": 0.4, "edgeRounding": 0.5])

        let result = await h.runRaw("copy_attributes", args: [
            "fromClipId": "clip-a", "toClipIds": ["clip-b"], "attributes": ["opacity"],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.clipFor(id: "clip-b")?.opacity == 0.4)
        #expect(h.editor.clipFor(id: "clip-b")?.edgeRounding == 0)
    }

    @Test func keyframesAreTrimmedToAShorterTarget() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 60)
        let b = Fixtures.clip(id: "clip-b", start: 60, duration: 20)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": "clip-a", "property": "opacity", "keyframes": [[0, 0.0], [50, 1.0]],
        ])

        let result = await h.runRaw("copy_attributes", args: [
            "fromClipId": "clip-a", "toClipIds": ["clip-b"], "attributes": ["keyframes"],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        let target = try #require(h.editor.clipFor(id: "clip-b"))
        #expect(target.opacityTrack?.keyframes.map(\.frame) == [0])
    }

    @Test func effectsAndColorAreIndependentGroups() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let b = Fixtures.clip(id: "clip-b", start: 30, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))
        h.addAsset(id: "media-1", duration: 10)
        _ = await h.runRaw("apply_effect", args: [
            "clipIds": ["clip-a"], "effects": [["type": "stylize.glow", "params": ["intensity": 0.5]]],
        ])
        _ = await h.runRaw("apply_color", args: ["clipIds": ["clip-a"], "color": ["saturation": 0.5]])

        let result = await h.runRaw("copy_attributes", args: [
            "fromClipId": "clip-a", "toClipIds": ["clip-b"], "attributes": ["effects"],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        let target = try #require(h.editor.clipFor(id: "clip-b"))
        #expect(target.effects?.contains { $0.type == "stylize.glow" } == true)
        #expect(target.effects?.contains { $0.type.hasPrefix("color.") } != true)
    }

    @Test func sourceClipInTargetsIsSkipped() async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("copy_attributes", args: [
            "fromClipId": clipId, "toClipIds": [clipId],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(ToolHarness.textOf(result).contains("noop"))
    }

    @Test func rejectsUnknownAttributeGroup() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("copy_attributes", args: [
            "fromClipId": clipId, "toClipIds": [clipId], "attributes": ["vibes"],
        ])
        #expect(result.isError)
    }
}

@Suite("link_clips")
@MainActor
struct LinkClipsToolTests {

    @Test func linkThenUnlinkRoundTrips() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let b = Fixtures.clip(id: "clip-b", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [a]), Fixtures.audioTrack(clips: [b]),
        ]))

        _ = try await h.runOK("link_clips", args: ["clipIds": ["clip-a", "clip-b"], "action": "link"])
        let group = try #require(h.editor.clipFor(id: "clip-a")?.linkGroupId)
        #expect(h.editor.clipFor(id: "clip-b")?.linkGroupId == group)

        _ = try await h.runOK("link_clips", args: ["clipIds": ["clip-a"], "action": "unlink"])
        #expect(h.editor.clipFor(id: "clip-a")?.linkGroupId == nil)
        #expect(h.editor.clipFor(id: "clip-b")?.linkGroupId == nil)
    }

    @Test func unlinkingUnlinkedClipsIsANoop() async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("link_clips", args: ["clipIds": [clipId], "action": "unlink"])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(ToolHarness.textOf(result).contains("noop"))
    }

    @Test func linkNeedsTwoClips() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("link_clips", args: ["clipIds": [clipId], "action": "link"])
        #expect(result.isError)
    }
}

@Suite("manage_nest")
@MainActor
struct ManageNestTests {

    @Test func nestingMovesClipsIntoAChildTimelineAndLeavesACarrier() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let b = Fixtures.clip(id: "clip-b", start: 30, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))
        h.addAsset(id: "media-1", duration: 10)

        let json = try await h.runOK("manage_nest", args: ["clipIds": ["clip-a", "clip-b"]]) as? [String: Any]
        let timelineId = try #require(json?["timelineId"] as? String)
        let child = try #require(h.editor.timelines.first { $0.id.hasPrefix(timelineId) })
        #expect(child.tracks.flatMap(\.clips).count == 2)
        #expect(h.editor.clipFor(id: "clip-a") == nil)

        let carriers = try #require(json?["carrierClipIds"] as? [String])
        let carrier = try #require(clip(forShortId: carriers[0], in: h.editor))
        #expect(carrier.sourceClipType == .sequence)
        #expect(carrier.startFrame == 0)
        #expect(carrier.durationFrames == 60)
    }

    @Test func decomposePutsTheChildClipsBack() async throws {
        let a = Fixtures.clip(id: "clip-a", start: 0, duration: 30)
        let b = Fixtures.clip(id: "clip-b", start: 30, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))
        h.addAsset(id: "media-1", duration: 10)

        let nested = try await h.runOK("manage_nest", args: ["clipIds": ["clip-a", "clip-b"]]) as? [String: Any]
        let carrier = try #require((nested?["carrierClipIds"] as? [String])?.first)

        let result = await h.runRaw("manage_nest", args: ["decompose": carrier])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(clip(forShortId: carrier, in: h.editor) == nil)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 2)
    }

    @Test func decomposeRefusesAPlainClip() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("manage_nest", args: ["decompose": clipId])
        #expect(result.isError)
    }

    @Test func refusesBothModesAtOnce() async {
        let (h, clipId) = harness()
        let result = await h.runRaw("manage_nest", args: ["clipIds": [clipId], "decompose": clipId])
        #expect(result.isError)
    }
}

@Suite("swap_clip_media")
@MainActor
struct SwapClipMediaTests {

    @Test func swapKeepsEditsAndRepointsTheSource() async throws {
        let (h, clipId) = harness()
        let replacement = h.addAsset(duration: 10)
        _ = await h.runRaw("set_clip_properties", args: ["clipIds": [clipId], "opacity": 0.5])

        let result = await h.runRaw("swap_clip_media", args: [
            "clipIds": [clipId], "mediaRef": replacement.id,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let clip = try #require(h.editor.clipFor(id: clipId))
        #expect(clip.mediaRef == replacement.id)
        #expect(clip.opacity == 0.5)
        #expect(clip.durationFrames == 60)
        #expect(clip.trimStartFrame == 30)
    }

    @Test func resetTrimStartsAtTheNewSourceHead() async throws {
        let (h, clipId) = harness()
        let replacement = h.addAsset(duration: 10)
        let result = await h.runRaw("swap_clip_media", args: [
            "clipIds": [clipId], "mediaRef": replacement.id, "resetTrim": true,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.clipFor(id: clipId)?.trimStartFrame == 0)
    }

    @Test func refusesAMediaKindMismatch() async {
        let (h, clipId) = harness()
        let audio = h.addAsset(type: .audio, duration: 10)
        let result = await h.runRaw("swap_clip_media", args: ["clipIds": [clipId], "mediaRef": audio.id])
        #expect(result.isError)
        #expect(h.editor.clipFor(id: clipId)?.mediaRef == "media-1")
    }

    @Test func swappingToTheSameMediaIsANoop() async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("swap_clip_media", args: ["clipIds": [clipId], "mediaRef": "media-1"])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(ToolHarness.textOf(result).contains("noop"))
    }
}
