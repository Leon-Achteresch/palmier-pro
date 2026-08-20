import Foundation
import Testing
@testable import PalmierPro

@Suite("add_transition tool")
@MainActor
struct AddTransitionToolTests {

    static func harness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "v1", clips: [
                Fixtures.clip(id: "a", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
                Fixtures.clip(id: "b", start: 30, duration: 30, trimStart: 30, trimEnd: 30),
            ])
        ]))
    }

    static let baseArgs: [String: Any] = [
        "fromClipId": "a", "toClipId": "b",
        "style": "crossDissolve", "durationFrames": 10,
    ]

    @Test func returnsAReceiptWithTheCreatedTransitionAndItsSpan() async throws {
        let h = Self.harness()
        let payload = try await h.runOK("add_transition", args: Self.baseArgs) as? [String: Any]
        let transition = try #require(payload?["transition"] as? [String: Any])

        let id = try #require(transition["transitionId"] as? String)
        #expect(!id.isEmpty)
        #expect(transition["style"] as? String == "crossDissolve")
        #expect(transition["alignment"] as? String == "centered")
        #expect(transition["durationFrames"] as? Int == 10)
        #expect(transition["frames"] as? [Int] == [25, 35])
        #expect(transition["cutFrame"] as? Int == 30)
        #expect(transition["fromClipId"] as? String == "a")
        #expect(transition["toClipId"] as? String == "b")
        #expect(transition["track"] as? Int == 0)
        #expect(transition["direction"] == nil)
        #expect(payload?["removedClipIds"] == nil)
    }

    @Test func theTimelineItselfCarriesTheTransitionAfterTheCall() async throws {
        let h = Self.harness()
        _ = try await h.runOK("add_transition", args: Self.baseArgs)
        let stored = try #require(h.editor.timeline.tracks[0].transitions.first)
        #expect(stored.style == .crossDissolve)
        #expect(h.editor.timeline.tracks[0].clips[0].endFrame == 30)
        #expect(h.editor.timeline.tracks[0].clips[1].startFrame == 30)
    }

    @Test func getTimelineReportsTheTransitionOnItsTrack() async throws {
        let h = Self.harness()
        var args = Self.baseArgs
        args["style"] = "wipe"
        args["direction"] = "right"
        _ = try await h.runOK("add_transition", args: args)

        let timeline = try await h.runOK("get_timeline") as? [String: Any]
        let tracks = try #require(timeline?["tracks"] as? [[String: Any]])
        let transitions = try #require(tracks[0]["transitions"] as? [[String: Any]])
        #expect(transitions.count == 1)
        #expect(transitions[0]["style"] as? String == "wipe")
        #expect(transitions[0]["direction"] as? String == "right")
        #expect(transitions[0]["frames"] as? [Int] == [25, 35])
    }

    @Test func getTimelineOmitsTransitionsOnATrackWithNone() async throws {
        let h = Self.harness()
        let timeline = try await h.runOK("get_timeline") as? [String: Any]
        let tracks = try #require(timeline?["tracks"] as? [[String: Any]])
        #expect(tracks[0]["transitions"] == nil)
    }

    @Test func refusesInsufficientHandlesWithTheMissingFrameCount() async throws {
        let h = Self.harness()
        h.editor.timeline.tracks[0].clips[1].trimStartFrame = 0
        let result = await h.runRaw("add_transition", args: Self.baseArgs)
        #expect(result.isError)
        let text = ToolHarness.textOf(result)
        #expect(text.contains("insufficient_handles"))
        #expect(text.contains("5"))
        #expect(h.editor.timeline.tracks[0].transitions.isEmpty)
    }

    @Test func refusesANonAdjacentPairWithoutMutating() async throws {
        let h = Self.harness()
        h.editor.timeline.tracks[0].clips[1].startFrame = 40
        let before = h.editor.timeline
        let result = await h.runRaw("add_transition", args: Self.baseArgs)
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not_adjacent"))
        #expect(h.editor.timeline == before)
    }

    @Test func refusesADirectionalStyleWithoutADirection() async throws {
        let h = Self.harness()
        var args = Self.baseArgs
        args["style"] = "slide"
        let result = await h.runRaw("add_transition", args: args)
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("missing_direction"))
    }

    @Test func refusesADirectionOnCrossDissolve() async throws {
        let h = Self.harness()
        var args = Self.baseArgs
        args["direction"] = "left"
        let result = await h.runRaw("add_transition", args: args)
        #expect(result.isError)
        #expect(h.editor.timeline.tracks[0].transitions.isEmpty)
    }

    @Test func refusesAnUnknownStyle() async throws {
        let h = Self.harness()
        var args = Self.baseArgs
        args["style"] = "starWipe"
        let result = await h.runRaw("add_transition", args: args)
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("style must be one of"))
    }

    @Test func refusesASecondTransitionOnTheSameCut() async throws {
        let h = Self.harness()
        _ = try await h.runOK("add_transition", args: Self.baseArgs)
        let result = await h.runRaw("add_transition", args: Self.baseArgs)
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("cut_already_has_transition"))
        #expect(h.editor.timeline.tracks[0].transitions.count == 1)
    }

    @Test func removeClipsTakesATransitionOffTheCut() async throws {
        let h = Self.harness()
        let payload = try await h.runOK("add_transition", args: Self.baseArgs) as? [String: Any]
        let transition = try #require(payload?["transition"] as? [String: Any])
        let id = try #require(transition["transitionId"] as? String)

        let removal = try await h.runOK("remove_clips", args: ["transitionIds": [id]]) as? [String: Any]
        #expect((removal?["removedTransitionIds"] as? [String])?.count == 1)
        #expect(h.editor.timeline.tracks[0].transitions.isEmpty)
        #expect(h.editor.timeline.tracks[0].clips.count == 2)
    }

    @Test func removeClipsRejectsAnUnknownTransitionId() async throws {
        let h = Self.harness()
        _ = try await h.runOK("add_transition", args: Self.baseArgs)
        let result = await h.runRaw("remove_clips", args: ["transitionIds": ["deadbeef"]])
        #expect(result.isError)
        #expect(h.editor.timeline.tracks[0].transitions.count == 1)
    }

    @Test func removeClipsStillRequiresSomethingToRemove() async throws {
        let h = Self.harness()
        let result = await h.runRaw("remove_clips", args: ["clipIds": [String]()])
        #expect(result.isError)
    }

    @Test func undoingTheToolCallRestoresTheHardCut() async throws {
        let h = Self.harness()
        let manager = UndoManager()
        h.editor.undo.attach(manager)
        _ = try await h.runOK("add_transition", args: Self.baseArgs)
        #expect(h.editor.timeline.tracks[0].transitions.count == 1)

        let undo = await h.runRaw("undo")
        #expect(!undo.isError, "\(ToolHarness.textOf(undo))")
        #expect(h.editor.timeline.tracks[0].transitions.isEmpty)
    }

    @Test func theToolIsAnnouncedWithItsSchema() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .addTransition })
        let schema = tool.inputSchema["properties"] as? [String: Any]
        #expect(schema?["fromClipId"] != nil)
        #expect(schema?["style"] != nil)
        #expect(tool.inputSchema["required"] as? [String] == ["fromClipId", "toClipId", "style", "durationFrames"])
    }
}
