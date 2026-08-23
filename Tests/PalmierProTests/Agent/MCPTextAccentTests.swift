import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP — text accent")
@MainActor
struct MCPTextAccentTests {

    @Test func accentResolvesWordsReadsBackAndSurvivesUndo() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: []),
        ]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        try await withClient(harness) { client in
            let added = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "trackIndex": .int(0),
                    "startFrame": .int(0),
                    "endFrame": .int(60),
                    "content": .string("Take the biggest risks."),
                    "accent": .object([
                        "color": .string("#00FF00"),
                        "words": .array([.string("BIGGEST"), .string("risks")]),
                    ]),
                ])]),
            ])
            #expect(added.isError != true)

            let accent = try #require(await self.accent(client: client))
            #expect(accent["words"] as? [Int] == [2, 3], "matching must ignore case and punctuation")
            let colour = try #require(accent["color"] as? [String: Any])
            #expect((colour["g"] as? NSNumber)?.doubleValue == 1)
            #expect((colour["r"] as? NSNumber)?.doubleValue == 0)

            let undo = try await client.callTool(name: "undo")
            #expect(undo.isError != true)
            #expect(await self.accent(client: client) == nil, "undo must take the text clip with it")
        }
    }

    @Test func aWordThatIsNotInTheTextIsRefusedWithoutMutating() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: []),
        ]))

        try await withClient(harness) { client in
            let result = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "trackIndex": .int(0),
                    "startFrame": .int(0),
                    "endFrame": .int(60),
                    "content": .string("Take the biggest risks."),
                    "accent": .object([
                        "color": .string("#00FF00"),
                        "words": .array([.string("smallest")]),
                    ]),
                ])]),
            ])
            #expect(result.isError == true)
            #expect(harness.editor.timeline.tracks[0].clips.isEmpty, "a refused call must add nothing")
        }
    }

    @Test func changingContentClearsAStaleAccentAndSaysSo() async throws {
        var clip = Fixtures.clip(id: "t1", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.textContent = "Take the biggest risks."
        clip.textStyle = TextStyle()
        clip.textAccent = TextAccent(color: TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1), words: [2])
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))

        try await withClient(harness) { client in
            let result = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string("t1")]),
                "content": .string("Remember you have time."),
            ])
            #expect(result.isError != true)
            #expect(harness.editor.clipFor(id: "t1")?.textAccent == nil)
            #expect(
                try self.text(result.content).localizedCaseInsensitiveContains("accent"),
                "the receipt must report the cleared accent, not drop it silently"
            )
        }
    }

    @Test func accentSurvivesAContentChangeWhenItIsResent() async throws {
        var clip = Fixtures.clip(id: "t1", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.textContent = "Take the biggest risks."
        clip.textStyle = TextStyle()
        clip.textAccent = TextAccent(color: TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1), words: [2])
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))

        try await withClient(harness) { client in
            let result = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string("t1")]),
                "content": .string("Remember you have time."),
                "accent": .object([
                    "color": .string("#FFB300"),
                    "words": .array([.string("time")]),
                ]),
            ])
            #expect(result.isError != true)
            #expect(harness.editor.clipFor(id: "t1")?.textAccent?.words == [3],
                    "the accent must resolve against the new content")
        }
    }

    @Test func clearingTheAccentIsExplicit() async throws {
        var clip = Fixtures.clip(id: "t1", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.textContent = "Take the biggest risks."
        clip.textStyle = TextStyle()
        clip.textAccent = TextAccent(color: TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1), words: [2])
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))

        try await withClient(harness) { client in
            let result = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string("t1")]),
                "accent": .null,
            ])
            #expect(result.isError != true)
            #expect(harness.editor.clipFor(id: "t1")?.textAccent == nil)
        }
    }

    // MARK: - Harness

    private func withClient(_ harness: ToolHarness, _ body: (Client) async throws -> Void) async throws {
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "text-accent-test", version: "1.0.0")
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

    private func accent(client: Client) async -> [String: Any]? {
        guard let result = try? await client.callTool(name: "get_timeline"),
              let raw = try? text(result.content),
              let payload = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let tracks = payload["tracks"] as? [[String: Any]] else { return nil }
        let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
        return clips.compactMap { $0["textAccent"] as? [String: Any] }.first
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
