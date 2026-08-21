import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP speed ramping", .serialized)
@MainActor
struct MCPSpeedRampTests {

    private func harnessWithClip(trimEnd: Int) -> (harness: ToolHarness, clipId: String, undo: UndoManager) {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "v1", clips: [
                Fixtures.clip(id: "ramp-clip", start: 0, duration: 60, trimStart: 0, trimEnd: trimEnd),
            ]),
        ]))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        return (harness, "ramp-clip", undo)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func withClient(
        _ harness: ToolHarness, _ body: (Client) async throws -> Void
    ) async throws {
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "speed-ramp-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await body(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func theSpeedPropertyIsDiscoverableAndWritesACurveThatUndoesInOneStep() async throws {
        let (harness, clipId, undo) = harnessWithClip(trimEnd: 300)
        _ = undo

        try await withClient(harness) { client in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "set_keyframes" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let propertyValues = try #require(properties["property"]?.objectValue?["enum"]?.arrayValue)
            #expect(propertyValues.contains(.string("speed")))
            #expect(tool.description?.contains("SPEED RAMPING") == true)

            let result = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "property": .string("speed"),
                "keyframes": .array([
                    .array([.int(0), .double(1.0), .string("linear")]),
                    .array([.int(20), .double(0.3), .string("linear")]),
                    .array([.int(40), .double(0.3), .string("linear")]),
                    .array([.int(60), .double(1.0), .string("linear")]),
                ]),
            ])
            #expect(result.isError != true)

            let stored = try #require(harness.editor.clipFor(id: clipId))
            let ramp = try #require(stored.speedRamp)
            #expect(stored.durationFrames == 60)
            #expect(ramp.sourceFramesConsumed == 32)
            #expect(ramp.segments.count <= SpeedRamp.maxSegments)

            let timelineResult = try await client.callTool(name: "get_timeline")
            let timeline = try json(text(timelineResult.content))
            let clip = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
                .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
                .first { ($0["id"] as? String).map { clipId.hasPrefix($0) } == true })
            let rows = try #require((clip["keyframes"] as? [String: Any])?["speed"] as? [[Any]])
            #expect(rows.count == 4)
            #expect(((rows[1][1] as? NSNumber)?.doubleValue ?? 0) == 0.3)

            let undoResult = try await client.callTool(name: "undo")
            #expect(undoResult.isError != true)
            #expect(harness.editor.clipFor(id: clipId)?.speedTrack == nil)
        }
    }

    @Test func aCurveThatOutrunsTheMediaIsRefusedAndNothingIsWritten() async throws {
        let (harness, clipId, undo) = harnessWithClip(trimEnd: 10)
        _ = undo

        let result = await harness.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "speed",
            "keyframes": [[0, 2.0, "linear"], [60, 2.0, "linear"]],
        ])
        #expect(result.isError)
        let message = ToolHarness.textOf(result)
        #expect(message.contains("120 source frames"))
        #expect(message.contains("50 frames short"))
        #expect(harness.editor.clipFor(id: clipId)?.speedTrack == nil)
        #expect(harness.editor.undo.undoLatest() == nil)
    }

    @Test func multiplierBoundsAreEnforcedBeforeAnythingMutates() async throws {
        let (harness, clipId, _) = harnessWithClip(trimEnd: 3000)
        for bad in [0.05, 10.5] {
            let result = await harness.runRaw("set_keyframes", args: [
                "clipId": clipId,
                "property": "speed",
                "keyframes": [[0, bad]],
            ])
            #expect(result.isError)
            #expect(ToolHarness.textOf(result).contains("multiplier"))
        }
        #expect(harness.editor.clipFor(id: clipId)?.speedTrack == nil)
    }

    @Test func theReceiptReportsTheConsumedSourceFramesAndTheSpareHeadroom() async throws {
        let (harness, clipId, _) = harnessWithClip(trimEnd: 300)
        let payload = try await harness.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "speed",
            "keyframes": [[0, 0.5, "linear"], [60, 0.5, "linear"]],
        ]) as? [String: Any]
        let notes = try #require(payload?["notes"] as? [String])
        #expect(notes.contains { $0.contains("30 source frames") && $0.contains("constant-rate segments") })
    }

    @Test func clearingTheCurveIsReportedAndRestoresConstantSpeed() async throws {
        let (harness, clipId, _) = harnessWithClip(trimEnd: 300)
        _ = try await harness.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "speed",
            "keyframes": [[0, 0.5, "linear"], [60, 0.5, "linear"]],
        ])
        let payload = try await harness.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "speed",
            "keyframes": [Any](),
        ]) as? [String: Any]
        let notes = try #require(payload?["notes"] as? [String])
        #expect(notes.contains { $0.contains("speed curve cleared") })
        #expect(harness.editor.clipFor(id: clipId)?.speedTrack == nil)
    }

    @Test func setClipPropertiesRefusesAConstantSpeedWhileACurveIsAuthored() async throws {
        let (harness, clipId, _) = harnessWithClip(trimEnd: 300)
        _ = try await harness.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "speed",
            "keyframes": [[0, 0.5, "linear"], [60, 0.5, "linear"]],
        ])
        let payload = try await harness.runOK("set_clip_properties", args: [
            "clipIds": [clipId], "speed": 2.0,
        ]) as? [String: Any]
        let encoded = try JSONSerialization.data(withJSONObject: payload ?? [:])
        #expect(String(decoding: encoded, as: UTF8.self).contains("speed skipped"))
        #expect(harness.editor.clipFor(id: clipId)?.speed == 1.0)
        #expect(harness.editor.clipFor(id: clipId)?.durationFrames == 60)
    }

    @Test func aSpeedCurveIsRefusedOnAClipThatCarriesATransition() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "v1", clips: [
                Fixtures.clip(id: "a", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
                Fixtures.clip(id: "b", start: 30, duration: 30, trimStart: 30, trimEnd: 30),
            ]),
        ]))
        _ = try await harness.runOK("add_transition", args: [
            "fromClipId": "a", "toClipId": "b", "style": "crossDissolve", "durationFrames": 10,
        ])
        let result = await harness.runRaw("set_keyframes", args: [
            "clipId": "a",
            "property": "speed",
            "keyframes": [[0, 1.0, "linear"], [30, 0.8, "linear"]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("remove the transition"))
        #expect(harness.editor.clipFor(id: "a")?.speedTrack == nil)
    }

    @Test func aSpeedCurveIsRefusedOnMulticamClips() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "v1", clips: [{
                var clip = Fixtures.clip(id: "mc", start: 0, duration: 60, trimEnd: 300)
                clip.multicamGroupId = "group"
                return clip
            }()]),
        ]))
        let result = await harness.runRaw("set_keyframes", args: [
            "clipId": "mc",
            "property": "speed",
            "keyframes": [[0, 0.5, "linear"], [60, 0.5, "linear"]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("multicam"))
    }
}
