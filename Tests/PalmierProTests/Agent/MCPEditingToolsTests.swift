import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP editing tools", .serialized)
@MainActor
struct MCPEditingToolsTests {

    @Test func newEditingToolsAreDiscoverableAndRunEndToEnd() async throws {
        let harness = ToolHarness()
        _ = harness.editor.insertTrack(at: 0, type: .video)
        let asset = harness.addAsset(type: .video, duration: 10)
        let clipId = try #require(harness.editor.placeClip(
            asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60
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
        let client = Client(name: "editing-tools-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let names = Set(tools.map(\.name))
            for expected in ["trim_clips", "duplicate_clips", "copy_attributes", "link_clips", "manage_nest", "swap_clip_media", "relink_media", "read_skill"] {
                #expect(names.contains(expected), "missing tool \(expected)")
            }

            let keyframeTool = try #require(tools.first { $0.name == "set_keyframes" })
            let keyframeProperties = try #require(keyframeTool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(keyframeProperties["tracks"] != nil)
            #expect(keyframeProperties["clipIds"] != nil)
            #expect(keyframeProperties["mode"] != nil)
            #expect(keyframeProperties["stagger"] != nil)

            let skillList = try await client.callTool(name: "read_skill", arguments: [:])
            let skillListText = try text(skillList.content)
            #expect(skillList.isError != true, "\(skillListText)")

            // One animation, several properties, one call.
            let animate = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "tracks": .object([
                    "opacity": .array([.array([.int(0), .double(0)]), .array([.int(20), .double(1), .string("linear")])]),
                    "scale": .array([.array([.int(0), .double(0.5), .double(0.5)]), .array([.int(20), .double(1), .double(1)])]),
                ]),
            ])
            let animateText = try text(animate.content)
            #expect(animate.isError != true, "\(animateText)")

            // Merge an eased keyframe into the existing opacity track.
            let merge = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "property": .string("opacity"),
                "keyframes": .array([.array([.int(10), .double(0.5), .string("backOut")])]),
                "mode": .string("merge"),
            ])
            let mergeText = try text(merge.content)
            #expect(merge.isError != true, "\(mergeText)")
            let opacityTrack = try #require(harness.editor.clipFor(id: clipId)?.opacityTrack)
            #expect(opacityTrack.keyframes.map(\.frame) == [0, 10, 20])
            #expect(opacityTrack.keyframes[1].interpolationOut == .backOut)

            // Animated effect param on the same clip.
            let effect = try await client.callTool(name: "apply_effect", arguments: [
                "clipIds": .array([.string(clipId)]),
                "effects": .array([.object([
                    "type": .string("blur.gaussian"),
                    "params": .object(["radius": .array([
                        .array([.int(0), .double(1)]),
                        .array([.int(20), .double(0), .string("linear")]),
                    ])]),
                ])]),
            ])
            let effectText = try text(effect.content)
            #expect(effect.isError != true, "\(effectText)")

            // Duplicate it and confirm the animation and the effect came along.
            let duplicate = try await client.callTool(name: "duplicate_clips", arguments: [
                "placements": .array([.object(["clipId": .string(clipId), "toFrame": .int(120)])]),
            ])
            let duplicateText = try text(duplicate.content)
            #expect(duplicate.isError != true, "\(duplicateText)")
            let receipt = try json(duplicateText)
            let newId = try #require((receipt["newClipIds"] as? [String])?.first)

            let timeline = try json(text((try await client.callTool(name: "get_timeline")).content))
            let copy = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
                .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
                .first { ($0["id"] as? String) == newId })
            #expect((copy["frames"] as? [Int])?.first == 120)
            let keyframes = try #require(copy["keyframes"] as? [String: Any])
            #expect(keyframes["opacity"] != nil)
            #expect(keyframes["scale"] != nil)
            let effects = try #require(copy["effects"] as? [[String: Any]])
            #expect(effects.contains { $0["type"] as? String == "blur.gaussian" })

            // Ripple-trim the original and verify the copy slid left by the same amount.
            let trim = try await client.callTool(name: "trim_clips", arguments: [
                "clipId": .string(clipId),
                "mode": .string("ripple"),
                "edge": .string("right"),
                "deltaFrames": .int(-20),
            ])
            let trimText = try text(trim.content)
            #expect(trim.isError != true, "\(trimText)")
            let live = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id.hasPrefix(newId) })
            #expect(live.startFrame == 100)
            #expect(harness.editor.clipFor(id: clipId)?.durationFrames == 40)

            // Undo restores the ripple through the same shared history.
            let undoResult = try await client.callTool(name: "undo")
            #expect(undoResult.isError != true)
            #expect(harness.editor.clipFor(id: clipId)?.durationFrames == 60)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func cutoutSubjectComposesAndAnimatesThroughMCP() async throws {
        let harness = ToolHarness()
        _ = harness.editor.insertTrack(at: 0, type: .video)
        let asset = harness.addAsset(type: .video, duration: 10)
        let plate = harness.addAsset(type: .image, duration: 5)
        let clipId = try #require(harness.editor.placeClip(
            asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 90
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
        let client = Client(name: "cutout-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let cutout = try #require(tools.first { $0.name == "cutout_subject" })
            #expect(cutout.description?.contains("transparent") == true)
            let effectTool = try #require(tools.first { $0.name == "apply_effect" })
            #expect(effectTool.description?.contains("key.subject") == true)

            // Cut the subject out and drop a background behind it in one call.
            let result = try await client.callTool(name: "cutout_subject", arguments: [
                "clipIds": .array([.string(clipId)]),
                "quality": .string("fast"),
                "feather": .double(0.3),
                "background": .object(["mediaRef": .string(plate.id)]),
            ])
            let resultText = try text(result.content)
            #expect(result.isError != true, "\(resultText)")
            let backgroundId = try #require((try json(resultText)["backgroundClipIds"] as? [String])?.first)

            let subjectTrack = try #require(harness.editor.findClip(id: clipId)?.trackIndex)
            let backgroundClip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id.hasPrefix(backgroundId) })
            let backgroundTrack = try #require(harness.editor.findClip(id: backgroundClip.id)).trackIndex
            #expect(backgroundTrack > subjectTrack)
            #expect(backgroundClip.durationFrames == 90)

            // Animate the cut-out layer: a slow push-in over the new background.
            let animate = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "tracks": .object([
                    "scale": .array([.array([.int(0), .double(1), .double(1)]), .array([.int(89), .double(1.2), .double(1.2)])]),
                ]),
            ])
            let animateText = try text(animate.content)
            #expect(animate.isError != true, "\(animateText)")

            // Rack-focus the background, not the subject.
            let blur = try await client.callTool(name: "apply_effect", arguments: [
                "clipIds": .array([.string(backgroundId)]),
                "effects": .array([.object([
                    "type": .string("blur.gaussian"),
                    "params": .object(["radius": .array([
                        .array([.int(0), .double(0)]),
                        .array([.int(89), .double(0.6), .string("linear")]),
                    ])]),
                ])]),
            ])
            let blurText = try text(blur.content)
            #expect(blur.isError != true, "\(blurText)")

            let live = try #require(harness.editor.clipFor(id: clipId))
            #expect(live.effects?.contains { $0.type == "key.subject" && $0.enabled } == true)
            #expect(live.scaleTrack?.keyframes.count == 2)
            let liveBackground = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id.hasPrefix(backgroundId) })
            #expect(liveBackground.effects?.first { $0.type == "blur.gaussian" }?.params["radius"]?.track?.keyframes.count == 2)

            // The whole compositing setup is one undo step per tool call.
            let undoResult = try await client.callTool(name: "undo")
            #expect(undoResult.isError != true)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.id.hasPrefix(backgroundId) }?.effects == nil)
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
