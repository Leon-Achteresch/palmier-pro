import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP structured motion scenes", .serialized)
@MainActor
struct MCPMotionSceneTests {
    @Test func importsComposesAnimatesAndUndoesThroughMCP() async throws {
        let package = try await MotionTestPackage.make()
        let registration = try await makeComponent(in: package.url)
        let harness = ToolHarness()
        defer { harness.removePresetLibrary() }
        harness.editor.projectURL = package.url
        let undo = UndoManager()
        undo.groupsByEvent = false
        harness.editor.undo.attach(undo)
        let server = Server(name: "motion-test", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "motion-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let invalidScene = package.url.appendingPathComponent("invalid.motion")
            let invalidImport = try await client.callTool(name: "import_media", arguments: ["source": .object(["path": .string(invalidScene.path)])])
            #expect(invalidImport.isError == true)
            guard case .text(let importError, _, _) = invalidImport.content.first else { throw ToolError("Expected import error") }
            #expect(importError.contains("unsupported scene version 1"))
            #expect(harness.editor.mediaAssetsById.isEmpty)
            #expect(!undo.canUndo)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "manage_motion_scene" })
            #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?["source"] == nil)
            #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?["expectedRevision"] != nil)
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            for (key, schema) in properties { #expect(schema.objectValue?["description"]?.stringValue?.isEmpty == false, "\(key) requires a description") }
            #expect(try await client.callTool(name: "manage_motion_scene", arguments: ["action": .string("create"), "name": .string("")]).isError == true)
            let created = try await call(client, ["action": .string("create"), "name": .string("Pricing"), "width": .int(320),
                "height": .int(180), "durationInFrames": .int(90), "requestId": .string("create-pricing")])
            let ref = try #require(created["mediaRef"] as? String)
            #expect(UUID(uuidString: ref) != nil)
            let imported = try await call(client, ["action": .string("import"), "mediaRef": .string(ref),
                "expectedRevision": .string(try #require(created["revision"] as? String)), "path": .string(registration.path), "requestId": .string("import-pricing")])
            let schema = try await call(client, ["action": .string("components"), "mediaRef": .string(ref), "componentId": .string("pricing-card")])
            #expect((schema["props"] as? [[String: Any]])?.first?["id"] as? String == "price")
            #expect(schema["source"] as? String == "")
            let composed = try await call(client, ["action": .string("compose"), "mediaRef": .string(ref),
                "expectedRevision": .string(try #require(imported["revision"] as? String)), "requestId": .string("compose-pricing"),
                "layers": .array([.object(["id": .string("card"), "kind": .string("component"), "componentId": .string("pricing-card"), "name": .string("Pricing Card")])])])
            let animated = try await call(client, ["action": .string("animate"), "mediaRef": .string(ref),
                "expectedRevision": .string(try #require(composed["revision"] as? String)), "targets": .array([.string("card")]),
                "recipe": .string("slide-up-fade"), "durationFrames": .int(18), "requestId": .string("animate-card")])
            let editArguments: [String: Value] = ["action": .string("content"), "mediaRef": .string(ref),
                "expectedRevision": .string(try #require(animated["revision"] as? String)), "targets": .array([.string("card")]),
                "values": .object(["props.price": .double(49)]), "requestId": .string("price-49")]
            let edited = try await call(client, editArguments)
            let replay = try await call(client, editArguments)
            #expect(replay["replayed"] as? Bool == true)
            #expect(replay["revision"] as? String == edited["revision"] as? String)
            let asset = try #require(harness.editor.mediaAssetsById[ref])
            let persisted = try await MotionVideoGenerator.loadScene(at: asset.url)
            #expect(persisted.nodes[0].props["price"] == .number(49))
            #expect(persisted.nodes[0].recipes[0].kind == .slideUp)
            #expect(persisted.components[0].stylesheet.contains("#112233"))
            let read = try await call(client, ["action": .string("read"), "mediaRef": .string(ref), "targets": .array([.string("card")])])
            #expect((read["nodes"] as? [[String: Any]])?.first?["id"] as? String == "card")
            var stale = editArguments
            stale["requestId"] = .string("stale-price")
            stale["values"] = .object(["props.price": .double(50)])
            #expect(try await client.callTool(name: "manage_motion_scene", arguments: stale).isError == true)
            var invalid = editArguments
            invalid["expectedRevision"] = .string(try #require(edited["revision"] as? String))
            invalid["requestId"] = .string("bad-price")
            invalid["values"] = .object(["props.price": .string("49")])
            #expect(try await client.callTool(name: "manage_motion_scene", arguments: invalid).isError == true)
            let unchanged = try await call(client, ["action": .string("content"), "mediaRef": .string(ref),
                "expectedRevision": .string(try #require(edited["revision"] as? String)), "targets": .array([.string("card")]), "values": .object(["props.price": .double(49)])])
            #expect(unchanged["unchanged"] as? Bool == true)
            let beforeUI = try await harness.editor.motionScenes.load(mediaRef: ref, editor: harness.editor)
            _ = try await harness.editor.motionScenes.apply([.values(ids: ["card"], values: ["x": .number(17.5)], frame: nil)], mediaRef: ref,
                expectedRevision: beforeUI.revision, actionName: "Move Layer", editor: harness.editor)
            _ = try await client.callTool(name: "undo")
            #expect(try await MotionVideoGenerator.loadScene(at: asset.url).nodes[0].value(.x) == .number(0))
            _ = try await client.callTool(name: "undo")
            #expect(try await MotionVideoGenerator.loadScene(at: asset.url).nodes[0].props["price"] == nil)
            _ = try await client.callTool(name: "undo")
            #expect(try await MotionVideoGenerator.loadScene(at: asset.url).nodes[0].recipes.isEmpty)
            await client.disconnect()
            await server.stop()
            undo.removeAllActions()
            try await package.remove()
        } catch {
            await client.disconnect()
            await server.stop()
            try await package.remove()
            throw error
        }
    }

    private func call(_ client: Client, _ arguments: [String: Value]) async throws -> [String: Any] {
        let result = try await client.callTool(name: "manage_motion_scene", arguments: arguments)
        #expect(result.isError != true)
        guard case .text(let text, _, _) = result.content.first else { throw ToolError("Expected MCP text result") }
        if result.isError == true { throw ToolError(text) }
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @concurrent private func makeComponent(in directory: URL) async throws -> URL {
        try "{\"version\":1}".write(to: directory.appendingPathComponent("invalid.motion"), atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("Card.tsx")
        try """
        import React from 'react';
        import './Card.css';
        export function PricingCard({price}) { return <div className="product-card">${price}</div>; }
        """.write(to: source, atomically: true, encoding: .utf8)
        try ".product-card { background: #112233; color: white; padding: 20px; }".write(to: directory.appendingPathComponent("Card.css"), atomically: true, encoding: .utf8)
        let registration = MotionComponentRegistration(id: "pricing-card", name: "Pricing Card", entry: "Card.tsx", exportName: "PricingCard", runtime: .web,
            props: [MotionPropSchema(id: "price", label: "Price", kind: .number, defaultValue: .number(19))], fixtures: ["pro": ["price": .number(49)]], slots: [])
        let url = directory.appendingPathComponent("card.motion-component.json")
        try JSONEncoder().encode(registration).write(to: url)
        return url
    }
}
