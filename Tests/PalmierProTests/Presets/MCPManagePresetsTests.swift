import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP manage_presets", .serialized)
@MainActor
struct MCPManagePresetsTests {

    @Test func savesAppliesAndDeletesALookThroughTheMCPBoundary() async throws {
        let harness = ToolHarness()
        defer { harness.removePresetLibrary() }
        _ = harness.editor.insertTrack(at: 0, type: .video)
        let asset = harness.addAsset(type: .video, duration: 10)
        let sourceId = try #require(harness.editor.placeClip(
            asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60
        ).first)
        let targetId = try #require(harness.editor.placeClip(
            asset: asset, trackIndex: 0, startFrame: 60, durationFrames: 60
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
        let client = Client(name: "manage-presets-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)

            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "manage_presets" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            for key in ["action", "kind", "presetId", "name", "sourceClipId", "clipIds"] {
                #expect(properties[key] != nil, "missing property \(key)")
            }

            let graded = try await client.callTool(name: "apply_color", arguments: [
                "clipIds": .array([.string(sourceId)]),
                "exposure": .double(0.5),
                "saturation": .double(1.4),
            ])
            try expectOK(graded)

            let saved = try await client.callTool(name: "manage_presets", arguments: [
                "action": .string("save"),
                "kind": .string("look"),
                "sourceClipId": .string(sourceId),
                "name": .string("Warm"),
            ])
            try expectOK(saved)
            let presetId = try #require(try json(text(saved.content))["presetId"] as? String)

            let listed = try json(text((try await client.callTool(name: "manage_presets", arguments: [
                "action": .string("list"), "kind": .string("look"),
            ])).content))
            let entries = try #require(listed["presets"] as? [[String: Any]])
            #expect(entries.contains { $0["presetId"] as? String == presetId })
            #expect(entries.filter { $0["builtIn"] as? Bool == true }.count == LookPreset.allCases.count)

            let applied = try await client.callTool(name: "manage_presets", arguments: [
                "action": .string("apply"),
                "presetId": .string(presetId),
                "clipIds": .array([.string(targetId)]),
            ])
            try expectOK(applied)

            let timeline = try json(text((try await client.callTool(name: "get_timeline")).content))
            let target = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
                .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
                .first { targetId.hasPrefix(($0["id"] as? String) ?? "\u{0}") })
            let color = try #require(target["color"] as? [String: Any])
            #expect((color["exposure"] as? NSNumber)?.doubleValue == 0.5)
            #expect((color["saturation"] as? NSNumber)?.doubleValue == 1.4)

            let undone = try await client.callTool(name: "undo")
            try expectOK(undone)
            #expect(harness.editor.clipFor(id: targetId)?.effects == nil)

            let deleted = try await client.callTool(name: "manage_presets", arguments: [
                "action": .string("delete"), "presetId": .string(presetId),
            ])
            try expectOK(deleted)

            let remaining = try json(text((try await client.callTool(name: "manage_presets", arguments: [
                "action": .string("list"), "kind": .string("look"),
            ])).content))
            let after = try #require(remaining["presets"] as? [[String: Any]])
            #expect(after.allSatisfy { $0["builtIn"] as? Bool == true })

            let missing = try await client.callTool(name: "manage_presets", arguments: [
                "action": .string("apply"),
                "presetId": .string(presetId),
                "clipIds": .array([.string(targetId)]),
            ])
            #expect(missing.isError == true)
            let missingText = try text(missing.content)
            #expect(missingText.contains("Preset not found"))
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func expectOK(_ result: (content: [Tool.Content], isError: Bool?), sourceLocation: SourceLocation = #_sourceLocation) throws {
        let detail = try text(result.content)
        #expect(result.isError != true, "\(detail)", sourceLocation: sourceLocation)
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
}
