import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP adjustment layers", .serialized)
@MainActor
struct MCPAdjustmentLayerTests {

    private func harnessWithFootage() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "shot1", start: 0, duration: 120)]),
        ]))
    }

    @Test func discoveryExposesTheSpanSchema() async throws {
        try await withClient(harness: harnessWithFootage(), name: "adjustment-discovery-test") { client in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "add_adjustment_layers" })
            let entries = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["entries"]?.objectValue)
            let item = try #require(entries["items"]?.objectValue)
            let properties = try #require(item["properties"]?.objectValue)
            #expect(properties["startFrame"]?.objectValue?["type"]?.stringValue == "integer")
            #expect(properties["endFrame"]?.objectValue?["type"]?.stringValue == "integer")
            #expect(properties["trackIndex"]?.objectValue?["type"]?.stringValue == "integer")
            #expect(item["required"]?.arrayValue?.compactMap(\.stringValue) == ["startFrame", "endFrame"])
        }
    }

    @Test func addsGradesReadsBackAndUndoesThroughMCP() async throws {
        let harness = harnessWithFootage()
        let manager = UndoManager()
        harness.editor.undo.attach(manager)

        try await withClient(harness: harness, name: "adjustment-roundtrip-test") { client in
            let added = try await client.callTool(name: "add_adjustment_layers", arguments: [
                "entries": .array([.object(["startFrame": .int(24), "endFrame": .int(96)])]),
            ])
            #expect(added.isError != true)

            let layer = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.isAdjustmentLayer })
            #expect(layer.startFrame == 24)
            #expect(layer.durationFrames == 72)
            #expect(harness.editor.timeline.tracks.count == 2)
            #expect(harness.editor.timeline.tracks[0].clips.map(\.id) == [layer.id])

            let graded = try await client.callTool(name: "apply_color", arguments: [
                "clipIds": .array([.string(layer.id)]),
                "exposure": .double(1.5),
            ])
            #expect(graded.isError != true)

            let clip = try await readClip(id: layer.id, client: client)
            #expect(clip["mediaType"] as? String == "adjustment")
            #expect(clip["frames"] as? [Int] == [24, 96])
            #expect(clip["trimStartFrame"] == nil)
            #expect(clip["trimEndFrame"] == nil)
            let color = try #require(clip["color"] as? [String: Any])
            #expect((color["exposure"] as? NSNumber)?.doubleValue == 1.5)
            #expect(harness.editor.clipFor(id: layer.id)?.effects?.contains { $0.type == "color.exposure" } == true)

            manager.undo()
            #expect(harness.editor.clipFor(id: layer.id)?.effects?.isEmpty != false)
            manager.undo()
            #expect(!harness.editor.timeline.tracks.contains { $0.clips.contains(where: \.isAdjustmentLayer) })
            #expect(harness.editor.timeline.tracks.count == 1)
        }
    }

    @Test func placesOnAnExistingTrackSoOnlyLowerTracksAreAffected() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "top", start: 0, duration: 120)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "bottom", start: 0, duration: 120)]),
        ]))
        let manager = UndoManager()
        harness.editor.undo.attach(manager)
        try await withClient(harness: harness, name: "adjustment-track-test") { client in
            let result = try await client.callTool(name: "add_adjustment_layers", arguments: [
                "entries": .array([.object([
                    "trackIndex": .int(1), "startFrame": .int(0), "endFrame": .int(60),
                ])]),
            ])
            #expect(result.isError != true)
            #expect(harness.editor.timeline.tracks.count == 2)
            let layer = try #require(harness.editor.timeline.tracks[1].clips.first { $0.isAdjustmentLayer })
            #expect(layer.startFrame == 0)
            #expect(harness.editor.clipFor(id: "bottom")?.startFrame == 60)
            #expect(harness.editor.clipFor(id: "top")?.startFrame == 0)

            manager.undo()
            #expect(harness.editor.clipFor(id: layer.id) == nil)
            #expect(harness.editor.clipFor(id: "bottom")?.startFrame == 0)
            #expect(harness.editor.clipFor(id: "bottom")?.durationFrames == 120)
        }
    }

    @Test(arguments: [
        ("endFrame not after startFrame", [["startFrame": 30, "endFrame": 30]]),
        ("negative startFrame", [["startFrame": -5, "endFrame": 30]]),
        ("track out of range", [["trackIndex": 9, "startFrame": 0, "endFrame": 30]]),
        ("mixed trackIndex", [["trackIndex": 0, "startFrame": 0, "endFrame": 30], ["startFrame": 40, "endFrame": 60]]),
        ("entries overlap each other", [["startFrame": 0, "endFrame": 60], ["startFrame": 30, "endFrame": 90]]),
        ("unknown key", [["startFrame": 0, "endFrame": 30, "opacity": 1]]),
    ])
    func rejectsInvalidRequestsWithoutMutating(_ testCase: (name: String, entries: [[String: Int]])) async throws {
        let harness = harnessWithFootage()
        try await withClient(harness: harness, name: "adjustment-validation-test") { client in
            let entries = testCase.entries.map { entry in
                Value.object(entry.mapValues { Value.int($0) })
            }
            let result = try await client.callTool(name: "add_adjustment_layers", arguments: [
                "entries": .array(entries),
            ])
            #expect(result.isError == true, "\(testCase.name) should be rejected")
            #expect(!harness.editor.timeline.tracks.contains { $0.clips.contains(where: \.isAdjustmentLayer) })
            #expect(harness.editor.timeline.tracks.count == 1)
        }
    }

    @Test func rejectsAudioTracksAndSourceOnlyProperties() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "shot1", start: 0, duration: 120)]),
            Fixtures.audioTrack(),
        ]))
        try await withClient(harness: harness, name: "adjustment-refusal-test") { client in
            let onAudio = try await client.callTool(name: "add_adjustment_layers", arguments: [
                "entries": .array([.object([
                    "trackIndex": .int(1), "startFrame": .int(0), "endFrame": .int(30),
                ])]),
            ])
            #expect(onAudio.isError == true)

            _ = try await client.callTool(name: "add_adjustment_layers", arguments: [
                "entries": .array([.object(["startFrame": .int(0), "endFrame": .int(60)])]),
            ])
            let layer = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.isAdjustmentLayer })

            for property in ["speed", "trimStartFrame", "trimEndFrame"] {
                let result = try await client.callTool(name: "set_clip_properties", arguments: [
                    "clipIds": .array([.string(layer.id)]),
                    Value.Key(stringLiteral: property): property == "speed" ? .double(2) : .int(5),
                ])
                #expect(result.isError == true, "\(property) should be refused on an adjustment layer")
            }
            let unchanged = try #require(harness.editor.clipFor(id: layer.id))
            #expect(unchanged.speed == 1)
            #expect(unchanged.trimStartFrame == 0)
            #expect(unchanged.durationFrames == 60)
        }
    }

    @Test func splitAndTrimKeepTheLayerEditableThroughMCP() async throws {
        let harness = harnessWithFootage()
        try await withClient(harness: harness, name: "adjustment-editing-test") { client in
            _ = try await client.callTool(name: "add_adjustment_layers", arguments: [
                "entries": .array([.object(["startFrame": .int(0), "endFrame": .int(60)])]),
            ])
            let layer = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.isAdjustmentLayer })

            let split = try await client.callTool(name: "split_clips", arguments: [
                "splits": .array([.object(["clipId": .string(layer.id), "atFrame": .int(30)])]),
            ])
            #expect(split.isError != true)
            let halves = harness.editor.timeline.tracks[0].clips.filter(\.isAdjustmentLayer)
            #expect(halves.count == 2)

            let trimmed = try await client.callTool(name: "trim_clips", arguments: [
                "clipId": .string(layer.id),
                "edge": .string("right"),
                "deltaFrames": .int(-10),
            ])
            #expect(trimmed.isError != true)
            #expect(harness.editor.clipFor(id: layer.id)?.durationFrames == 20)

            let slipped = try await client.callTool(name: "trim_clips", arguments: [
                "clipId": .string(layer.id),
                "mode": .string("slip"),
                "deltaFrames": .int(5),
            ])
            #expect(slipped.isError == true, "an adjustment layer has no source range to slip")
        }
    }

    private func withClient(
        harness: ToolHarness,
        name: String,
        operation: (Client) async throws -> Void
    ) async throws {
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: name, version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await operation(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func readClip(id: String, client: Client) async throws -> [String: Any] {
        let result = try await client.callTool(name: "get_timeline")
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(try text(result.content).utf8)) as? [String: Any]
        )
        return try #require(((payload["tracks"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
            .first { ($0["id"] as? String).map { id.hasPrefix($0) || $0.hasPrefix(id) } == true })
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let value, _, _) = item { return value }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
