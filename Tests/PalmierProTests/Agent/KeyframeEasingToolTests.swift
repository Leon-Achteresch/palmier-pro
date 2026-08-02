import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("set_keyframes motion easing")
@MainActor
struct KeyframeEasingToolTests {
    private func makeClip(_ h: ToolHarness) throws -> String {
        _ = h.editor.insertTrack(at: 0, type: .video)
        let asset = h.addAsset(type: .video)
        return try #require(h.editor.placeClip(
            asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 200
        ).first)
    }

    private func opacityTrack(_ h: ToolHarness, _ clipId: String) throws -> KeyframeTrack<Double> {
        let loc = try #require(h.editor.findClip(id: clipId))
        return try #require(h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].opacityTrack)
    }

    @Test func bezierArrayAndSpringObjectStoreAndRoundTrip() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [
                [0, 0.0, [0.32, 0.0, 0.67, 0.0]],
                [30, 1.0, ["type": "spring", "bounce": 0.5]],
                [60, 0.0],
            ],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes[0].interpolationOut == .cubicBezier)
        #expect(track.keyframes[0].easingParams == [0.32, 0, 0.67, 0])
        #expect(track.keyframes[1].interpolationOut == .spring)
        #expect(track.keyframes[1].easingParams == [0.5])

        let timeline = try #require(try await h.runOK("get_timeline") as? [String: Any])
        let clip = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
            .first { ($0["id"] as? String).map { clipId.hasPrefix($0) } == true })
        let rows = try #require((clip["keyframes"] as? [String: Any])?["opacity"] as? [[Any]])
        let bezier = try #require(rows[0].last as? [Any]).compactMap { ($0 as? NSNumber)?.doubleValue }
        #expect(bezier == [0.32, 0, 0.67, 0])
        let spring = try #require(rows[1].last as? [String: Any])
        #expect(spring["type"] as? String == "spring")
        #expect((spring["bounce"] as? NSNumber)?.doubleValue == 0.5)
    }

    @Test func springPhysicsParametersMapToBounce() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [
                [0, 0.0, ["type": "spring", "stiffness": 100, "damping": 10, "mass": 1]],
                [30, 1.0],
            ],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes[0].interpolationOut == .spring)
        #expect(track.keyframes[0].easingParams == [0.5])
    }

    @Test func namedMotionEasingsAccepted() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [
                [0, 0.0, "anticipate"],
                [20, 1.0, "circInOut"],
                [40, 0.5, "backInOut"],
                [60, 1.0, "elasticIn"],
            ],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes.map(\.interpolationOut) == [.anticipate, .circInOut, .backInOut, .elasticIn])
    }

    @Test func repeatLoopUnrollsCycles() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0], [30, 1.0, "easeOut"]],
            "repeat": ["count": 3, "type": "loop"],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes.map(\.frame) == [0, 30, 31, 61, 62, 92])
        #expect(track.keyframes.map(\.value) == [0, 1, 0, 1, 0, 1])
    }

    @Test func repeatMirrorPingPongsWithMirroredEasing() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0, "easeOut"], [30, 1.0]],
            "repeat": ["count": 2, "type": "mirror"],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes.map(\.frame) == [0, 30, 60])
        #expect(track.keyframes.map(\.value) == [0, 1, 0])
        #expect(track.keyframes[1].interpolationOut == .easeIn)
    }

    @Test func repeatRejectsInvalidCombinations() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        let merge = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "mode": "merge",
            "property": "opacity",
            "keyframes": [[0, 0.0], [30, 1.0]],
            "repeat": ["count": 2, "type": "loop"],
        ])
        #expect(merge.isError)
        let single = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0]],
            "repeat": ["count": 2, "type": "loop"],
        ])
        #expect(single.isError)
        let badType = await h.runRaw("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [[0, 0.0], [30, 1.0]],
            "repeat": ["count": 2, "type": "yoyo"],
        ])
        #expect(badType.isError)
        let loc = try #require(h.editor.findClip(id: clipId))
        #expect(h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].opacityTrack == nil)
    }

    @Test func easingVocabularyAndRepeatCrossTheMCPBoundary() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: h.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "keyframe-easing-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        defer {
            Task {
                await server.stop()
                await client.disconnect()
            }
        }
        _ = try await client.connect(transport: transports.client)

        let (tools, _) = try await client.listTools()
        let tool = try #require(tools.first { $0.name == "set_keyframes" })
        #expect(tool.description?.contains("spring") == true)
        #expect(tool.description?.contains("cubic bezier") == true)
        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(properties["repeat"] != nil)

        let result = try await client.callTool(name: "set_keyframes", arguments: [
            "clipId": .string(clipId),
            "property": .string("opacity"),
            "keyframes": .array([
                .array([.int(0), .double(0), .array([.double(0.32), .double(0), .double(0.67), .double(0)])]),
                .array([.int(30), .double(1), .object(["type": .string("spring"), "bounce": .double(0.4)])]),
            ]),
            "repeat": .object(["count": .int(2), "type": .string("mirror")]),
        ])
        #expect(result.isError != true)
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes.map(\.frame) == [0, 30, 60])
        #expect(track.keyframes[0].easingParams == [0.32, 0, 0.67, 0])
        #expect(track.keyframes[1].interpolationOut == .cubicBezier)
        let mirroredBezier: [Double] = [1 - 0.67, 1, 1 - 0.32, 1]
        #expect(track.keyframes[1].easingParams == mirroredBezier)
    }

    @Test func sineAndExpoNamedEasingsAccepted() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [
                [0, 0.0, "expoOut"],
                [20, 1.0, "sineInOut"],
                [40, 0.0, "expoInOut"],
                [60, 1.0],
            ],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes.map(\.interpolationOut) == [.expoOut, .sineInOut, .expoInOut, .smooth])
    }

    @Test func parametricBackAndElasticStoreParams() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [
                [0, 0.0, ["type": "back", "overshoot": 3.0]],
                [20, 1.0, ["type": "back", "direction": "inOut"]],
                [40, 0.0, ["type": "elastic", "amplitude": 2.0, "period": 0.5, "direction": "in"]],
                [60, 1.0, ["type": "elastic"]],
                [80, 0.0],
            ],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes[0].interpolationOut == .backOut)
        #expect(track.keyframes[0].easingParams == [3])
        #expect(track.keyframes[1].interpolationOut == .backInOut)
        #expect(track.keyframes[2].interpolationOut == .elasticIn)
        #expect(track.keyframes[2].easingParams == [2, 0.5])
        #expect(track.keyframes[3].interpolationOut == .elasticOut)
        #expect(track.keyframes[3].easingParams == [1])
    }

    @Test func splitEaseStoresAndRoundTrips() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [
                [0, 0.0, ["out": "easeIn", "in": ["type": "back", "overshoot": 2.5]]],
                [30, 1.0, ["in": "expoOut"]],
                [60, 0.0],
            ],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes[0].interpolationOut == .easeIn)
        #expect(track.keyframes[0].interpolationIn == .backOut)
        #expect(track.keyframes[0].easingParamsIn == [2.5])
        #expect(track.keyframes[1].interpolationOut == .smooth)
        #expect(track.keyframes[1].interpolationIn == .expoOut)

        let timeline = try #require(try await h.runOK("get_timeline") as? [String: Any])
        let clip = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
            .first { ($0["id"] as? String).map { clipId.hasPrefix($0) } == true })
        let rows = try #require((clip["keyframes"] as? [String: Any])?["opacity"] as? [[Any]])
        let split = try #require(rows[0].last as? [String: Any])
        #expect(split["out"] as? String == "easeIn")
        let arrival = try #require(split["in"] as? [String: Any])
        #expect(arrival["type"] as? String == "back")
        #expect((arrival["overshoot"] as? NSNumber)?.doubleValue == 2.5)
        #expect(arrival["direction"] as? String == "out")
    }

    @Test func repeatMirrorSwapsSplitEaseSides() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        _ = try await h.runOK("set_keyframes", args: [
            "clipId": clipId,
            "property": "opacity",
            "keyframes": [
                [0, 0.0, ["out": "easeIn", "in": ["type": "back", "overshoot": 2.5]]],
                [30, 1.0],
            ],
            "repeat": ["count": 2, "type": "mirror"],
        ])
        let track = try opacityTrack(h, clipId)
        #expect(track.keyframes.map(\.frame) == [0, 30, 60])
        let mirrored = track.keyframes[1]
        #expect(mirrored.interpolationOut == .backIn)
        #expect(mirrored.easingParams == [2.5])
        #expect(mirrored.interpolationIn == .easeOut)
    }

    @Test func invalidEasingsRejected() async throws {
        let h = ToolHarness()
        let clipId = try makeClip(h)
        for badEase: Any in [
            [0.32, 0.0, 0.67],
            ["type": "wobble"],
            ["type": "spring", "bounce": 2.0],
            ["type": "steps", "count": 0],
            "zoomies",
            ["type": "back", "overshoot": 20.0],
            ["type": "elastic", "amplitude": 0.5],
            ["type": "elastic", "period": 5.0],
            ["type": "back", "direction": "sideways"],
            ["in": "hold"],
            ["out": "easeIn", "in": "expoOut", "wiggle": true],
            [String: Any](),
        ] {
            let result = await h.runRaw("set_keyframes", args: [
                "clipId": clipId,
                "property": "opacity",
                "keyframes": [[0, 0.0, badEase], [30, 1.0]],
            ])
            #expect(result.isError, "expected rejection for easing \(badEase)")
        }
    }
}
