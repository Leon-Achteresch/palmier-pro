import AVFoundation
import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP proxy workflow", .serialized)
@MainActor
struct MCPProxyWorkflowTests {
    @Test func proxiesGenerateEnableAndRemoveThroughMCP() async throws {
        let harness = ToolHarness()
        let projectURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-proxy-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        harness.editor.projectURL = projectURL

        let sourceSize = CGSize(width: 640, height: 360)
        let source = try await ImageVideoGenerator.stillVideo(
            for: try CompositorFixtures.patternPNG(size: sourceSize),
            mediaRef: "mcp-proxy-source",
            size: sourceSize
        )
        let asset = harness.makeAsset(name: "A-roll")
        asset.url = source
        harness.editor.mediaManifest.entries[0].source = .external(absolutePath: source.path)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "proxy-workflow-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "manage_proxies" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["action"] != nil)
            #expect(properties["assetIds"] != nil)
            #expect(properties["regenerate"] != nil)

            let bad = try await client.callTool(name: "manage_proxies", arguments: ["action": .string("enable"), "assetIds": .array([])])
            #expect(bad.isError == true)

            let generate = try await client.callTool(name: "manage_proxies", arguments: ["action": .string("generate")])
            let generateText = try text(generate.content)
            #expect(generate.isError != true, "\(generateText)")
            #expect((try json(generateText)["queuedAssetIds"] as? [String])?.count == 1)

            while harness.editor.proxyService.pendingCount > 0 { await Task.yield() }

            let status = try json(text((try await client.callTool(
                name: "manage_proxies", arguments: ["action": .string("status")]
            )).content))
            let rows = try #require(status["proxies"] as? [[String: Any]])
            #expect(rows.first?["status"] as? String == "ready")

            let proxyURL = ProxyPlan.url(assetId: asset.id, projectURL: projectURL)
            let proxyTrack = try #require(
                try await AVURLAsset(url: proxyURL).loadTracks(withMediaType: .video).first
            )
            #expect(try await proxyTrack.load(.naturalSize) == CGSize(width: 320, height: 180))

            _ = try await client.callTool(name: "manage_proxies", arguments: ["action": .string("enable")])
            #expect(harness.editor.useProxies)
            #expect(harness.editor.mediaURLMap(quality: .playback)[asset.id] == proxyURL)
            #expect(harness.editor.mediaURLMap(quality: .full)[asset.id] == source)

            let remove = try json(text((try await client.callTool(
                name: "manage_proxies", arguments: ["action": .string("remove")]
            )).content))
            #expect((remove["removedAssetIds"] as? [String])?.count == 1)
            #expect(!FileManager.default.fileExists(atPath: proxyURL.path))
            #expect(harness.editor.mediaURLMap(quality: .playback)[asset.id] == source)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
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
