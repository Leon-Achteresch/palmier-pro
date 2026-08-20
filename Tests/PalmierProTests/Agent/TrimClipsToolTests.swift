import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("trim_clips Agent tool", .serialized)
@MainActor
struct TrimClipsToolTests {

    @Test func scopedTrimRollsOneLaneKeepsLinkAndUndoesAsOneAction() async throws {
        let undoManager = UndoManager()
        let editor = linkedPairEditor(undoManager: undoManager)
        let harness = try await MCPHarness(editor: editor, name: "trim-clips-scope")
        defer { Task { await harness.shutdown() } }

        let (tools, _) = try await harness.client.listTools()
        let tool = try #require(tools.first { $0.name == "trim_clips" })
        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(properties["scope"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue)
            == ["both", "videoOnly", "audioOnly"])
        #expect(properties["edge"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) == ["left", "right"])

        let result = try await harness.call("trim_clips", [
            "clipId": .string("v"),
            "edge": .string("right"),
            "deltaFrames": .int(12),
            "scope": .string("audioOnly"),
        ])
        #expect(result.isError != true)
        let receipt = try json(text(result.content))
        let note = try #require((receipt["notes"] as? [String])?.first)
        #expect(note.contains("audio"))

        #expect(editor.clipFor(id: "a")?.durationFrames == 72)
        #expect(editor.clipFor(id: "a")?.trimEndFrame == 8)
        #expect(editor.clipFor(id: "v")?.durationFrames == 60)
        #expect(editor.clipFor(id: "v")?.linkGroupId == "g")
        #expect(editor.clipFor(id: "a")?.linkGroupId == "g")

        let undo = try await harness.call("undo", [:])
        #expect(undo.isError != true)
        #expect(editor.clipFor(id: "a")?.durationFrames == 60)
        #expect(editor.clipFor(id: "a")?.trimEndFrame == 20)
        #expect(editor.clipFor(id: "v")?.durationFrames == 60)
        #expect(editor.undo.undoLatest() == nil)
    }

    @Test func defaultScopeTrimsBothLanesTogether() async throws {
        let undoManager = UndoManager()
        let editor = linkedPairEditor(undoManager: undoManager)
        let harness = try await MCPHarness(editor: editor, name: "trim-clips-both")
        defer { Task { await harness.shutdown() } }

        let result = try await harness.call("trim_clips", [
            "clipId": .string("v"),
            "edge": .string("left"),
            "deltaFrames": .int(10),
        ])
        #expect(result.isError != true)

        #expect(editor.clipFor(id: "v")?.startFrame == 110)
        #expect(editor.clipFor(id: "v")?.trimStartFrame == 30)
        #expect(editor.clipFor(id: "a")?.startFrame == 110)
        #expect(editor.clipFor(id: "a")?.trimStartFrame == 30)
    }

    @Test(arguments: [
        (["clipId": Value.string("v"), "edge": .string("right"), "deltaFrames": .int(25), "scope": .string("audioOnly")], "Not enough source media"),
        (["clipId": Value.string("v"), "edge": .string("right"), "deltaFrames": .int(-60), "scope": .string("audioOnly")], "at least 1 frame"),
        (["clipId": Value.string("solo"), "edge": .string("right"), "deltaFrames": .int(5), "scope": .string("audioOnly")], "No audio clip is linked"),
        (["clipId": Value.string("v"), "edge": .string("right"), "deltaFrames": .int(5), "mode": .string("ripple"), "scope": .string("audioOnly")], "applies only to a normal trim"),
        (["clipId": Value.string("v"), "edge": .string("middle"), "deltaFrames": .int(5)], "edge must be 'left' or 'right'"),
        (["clipId": Value.string("v"), "edge": .string("right"), "deltaFrames": .int(5), "scope": .string("audio")], "scope must be 'both', 'videoOnly', or 'audioOnly'"),
        (["clipId": Value.string("nope"), "edge": .string("right"), "deltaFrames": .int(5)], "Clip not found"),
        (["clipId": Value.string("v"), "edge": .string("right"), "deltaFrames": .int(0)], "deltaFrames must not be 0"),
    ])
    func invalidRequestsAreRefusedWithoutMutating(arguments: [String: Value], reason: String) async throws {
        let undoManager = UndoManager()
        let editor = linkedPairEditor(undoManager: undoManager)
        let harness = try await MCPHarness(editor: editor, name: "trim-clips-refusal")
        defer { Task { await harness.shutdown() } }

        let before = editor.timeline
        let result = try await harness.call("trim_clips", arguments)
        #expect(result.isError == true)
        #expect(try text(result.content).contains(reason))
        #expect(editor.timeline == before)
        #expect(editor.undo.undoLatest() == nil)
    }

    private func linkedPairEditor(undoManager: UndoManager) -> EditorViewModel {
        var video = Fixtures.clip(id: "v", start: 100, duration: 60, trimStart: 20, trimEnd: 20)
        video.linkGroupId = "g"
        var audio = Fixtures.clip(id: "a", mediaType: .audio, start: 100, duration: 60, trimStart: 20, trimEnd: 20)
        audio.linkGroupId = "g"
        let solo = Fixtures.clip(id: "solo", start: 400, duration: 30, trimStart: 10, trimEnd: 10)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video, solo]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        undoManager.groupsByEvent = false
        editor.undo.attach(undoManager)
        return editor
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

@MainActor
private struct MCPHarness {
    let server: Server
    let client: Client

    init(editor: EditorViewModel, name: String) async throws {
        server = Server(name: name, version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: editor))
        let transports = await InMemoryTransport.createConnectedPair()
        client = Client(name: name, version: "1.0.0")
        try await server.start(transport: transports.server)
        _ = try await client.connect(transport: transports.client)
    }

    func call(_ name: String, _ arguments: [String: Value]) async throws -> (content: [Tool.Content], isError: Bool?) {
        let result = try await client.callTool(name: name, arguments: arguments)
        return (result.content, result.isError)
    }

    func shutdown() async {
        await server.stop()
        await client.disconnect()
    }
}
