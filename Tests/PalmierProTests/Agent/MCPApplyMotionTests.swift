import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP apply_motion", .serialized)
@MainActor
struct MCPApplyMotionTests {
    @Test func motionPresetAppliesStaggersAndUndoesThroughMCP() async throws {
        let harness = ToolHarness()
        _ = harness.editor.insertTrack(at: 0, type: .video)
        let asset = harness.addAsset(type: .video)
        let clipA = try #require(harness.editor.placeClip(
            asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 120
        ).first)
        let clipB = try #require(harness.editor.placeClip(
            asset: asset, trackIndex: 0, startFrame: 120, durationFrames: 120
        ).first)
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "apply-motion-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "apply_motion" })
            let presets = try #require(
                tool.inputSchema.objectValue?["properties"]?.objectValue?["preset"]?
                    .objectValue?["enum"]?.arrayValue
            )
            #expect(presets.contains(.string("punch-in")))
            #expect(presets.count == MotionPreset.allCases.count)

            let popResult = try await client.callTool(name: "apply_motion", arguments: [
                "clipIds": .array([.string(clipA), .string(clipB)]),
                "preset": .string("pop-in"),
                "durationSeconds": .double(1),
                "stagger": .int(12),
            ])
            #expect(popResult.isError != true)

            let fps = harness.editor.timeline.fps
            let storedA = try #require(harness.editor.clipFor(id: clipA)?.scaleTrack)
            let storedB = try #require(harness.editor.clipFor(id: clipB)?.scaleTrack)
            #expect(storedA.keyframes.map(\.frame) == [0, fps])
            #expect(storedB.keyframes.map(\.frame) == [12, 12 + fps])
            #expect(storedA.keyframes.first?.interpolationOut == .backOut)
            #expect(harness.editor.clipFor(id: clipA)?.opacityTrack?.keyframes.first?.value == 0)

            let punchResult = try await client.callTool(name: "apply_motion", arguments: [
                "clipId": .string(clipA),
                "preset": .string("punch-in"),
                "intensity": .double(100),
                "focusX": .double(0.2),
                "focusY": .double(0.8),
            ])
            #expect(punchResult.isError != true)
            let zoomed = try #require(harness.editor.clipFor(id: clipA)?.scaleTrack?.keyframes[1])
            #expect(zoomed.value.a == 2.0)
            let sampled = try #require(harness.editor.clipFor(id: clipA)).sizeAt(frame: zoomed.frame)
            #expect(abs(sampled.width - 2.0) < 0.0001)

            _ = try await client.callTool(name: "undo")
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.clipFor(id: clipA)?.scaleTrack == nil)
            #expect(harness.editor.clipFor(id: clipB)?.scaleTrack == nil)

            let badPreset = try await client.callTool(name: "apply_motion", arguments: [
                "clipId": .string(clipA),
                "preset": .string("does-not-exist"),
            ])
            #expect(badPreset.isError == true)

            let focusOnFade = try await client.callTool(name: "apply_motion", arguments: [
                "clipId": .string(clipA),
                "preset": .string("fade-down"),
                "focusX": .double(0.5),
            ])
            #expect(focusOnFade.isError == true)

            let staggerSingle = try await client.callTool(name: "apply_motion", arguments: [
                "clipId": .string(clipA),
                "preset": .string("pop-in"),
                "stagger": .int(10),
            ])
            #expect(staggerSingle.isError == true)
            #expect(harness.editor.clipFor(id: clipA)?.scaleTrack == nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
