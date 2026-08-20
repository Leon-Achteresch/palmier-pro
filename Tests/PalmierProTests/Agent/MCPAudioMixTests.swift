import AVFoundation
import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP audio mix")
@MainActor
struct MCPAudioMixTests {
    @Test func discoveryMutationReadbackValidationAndUndo() async throws {
        let audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 90)
        let video = Fixtures.clip(id: "video", start: 0, duration: 90)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "audio-mix-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)

            let (tools, _) = try await client.listTools()
            let setProperties = try #require(tools.first { $0.name == "set_clip_properties" })
            let properties = try #require(setProperties.inputSchema.objectValue?["properties"]?.objectValue)
            let audioMixSchema = try #require(properties["audioMix"]?.objectValue?["properties"]?.objectValue)
            #expect(Self.number(audioMixSchema["pan"]?.objectValue?["minimum"]) == -1)
            #expect(Self.number(audioMixSchema["pan"]?.objectValue?["maximum"]) == 1)
            #expect(audioMixSchema["eq"]?.objectValue?["properties"]?.objectValue?["midFrequency"] != nil)
            #expect(audioMixSchema["compressor"]?.objectValue?["properties"]?.objectValue?["ratio"] != nil)

            let measure = try #require(tools.first { $0.name == "measure_loudness" })
            let measureProperties = try #require(measure.inputSchema.objectValue?["properties"]?.objectValue)
            let scopes = try #require(measureProperties["scope"]?.objectValue?["enum"]?.arrayValue)
            #expect(scopes.compactMap(\.stringValue) == ["timeline", "clip"])
            let targets = try #require(measureProperties["target"]?.objectValue?["enum"]?.arrayValue)
            #expect(Set(targets.compactMap(\.stringValue)) == ["youtube", "podcast", "broadcast"])

            let applied = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(audio.id)]),
                "audioMix": .object([
                    "pan": .double(-0.5),
                    "eq": .object(["midGainDb": .double(4), "midFrequency": .double(2500)]),
                ]),
            ])
            #expect(applied.isError != true)
            #expect(harness.editor.clipFor(id: audio.id)?.audioMix?.pan == -0.5)
            #expect(harness.editor.clipFor(id: audio.id)?.audioMix?.eq?.midGainDb == 4)

            let readBack = try await timelineClip(client: client, clipId: audio.id)
            let mix = try #require(readBack["audioMix"] as? [String: Any])
            #expect((mix["pan"] as? NSNumber)?.doubleValue == -0.5)
            #expect(((mix["eq"] as? [String: Any])?["midFrequency"] as? NSNumber)?.doubleValue == 2500)

            let merged = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(audio.id)]),
                "audioMix": .object(["compressor": .object(["thresholdDb": .double(-24)])]),
            ])
            #expect(merged.isError != true)
            let afterMerge = try #require(harness.editor.clipFor(id: audio.id)?.audioMix)
            #expect(afterMerge.pan == -0.5)
            #expect(afterMerge.compressor?.thresholdDb == -24)
            #expect(afterMerge.compressor?.ratio == ClipAudioMixLimits.ratioDefault)

            for invalid: Value in [
                .object(["pan": .double(2)]),
                .object(["eq": .object(["lowGainDb": .double(-40)])]),
                .object(["compressor": .object(["ratio": .double(0.5)])]),
                .object(["reset": .bool(true), "pan": .double(0.2)]),
                .object(["compressor": .object(["enabled": .bool(false), "ratio": .double(3)])]),
                .object(["tilt": .double(1)]),
            ] {
                let rejected = try await client.callTool(name: "set_clip_properties", arguments: [
                    "clipIds": .array([.string(audio.id)]),
                    "audioMix": invalid,
                ])
                #expect(rejected.isError == true)
            }
            #expect(harness.editor.clipFor(id: audio.id)?.audioMix == afterMerge)

            let onVideo = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(video.id)]),
                "audioMix": .object(["pan": .double(0.5)]),
            ])
            #expect(onVideo.isError == true)
            #expect(harness.editor.clipFor(id: video.id)?.audioMix == nil)

            #expect((try await client.callTool(name: "undo")).isError != true)
            let afterUndo = try #require(harness.editor.clipFor(id: audio.id)?.audioMix)
            #expect(afterUndo.compressor == nil)
            #expect(afterUndo.pan == -0.5)

            let cleared = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(audio.id)]),
                "audioMix": .object(["reset": .bool(true)]),
            ])
            #expect(cleared.isError != true)
            #expect(harness.editor.clipFor(id: audio.id)?.audioMix == nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func measuresProgramLoudnessAgainstATargetThroughTheServer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-mcp-loudness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let toneURL = directory.appendingPathComponent("tone.caf")
        try Self.writeTone(dbfs: -20, seconds: 4, to: toneURL)

        let clip = Fixtures.clip(id: "audio", mediaRef: "tone", mediaType: .audio, start: 0, duration: 120)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])]))
        let asset = MediaAsset(id: "tone", url: toneURL, type: .audio, name: "tone", duration: 4)
        harness.editor.mediaAssets.append(asset)
        harness.editor.mediaManifest.entries.append(MediaManifestEntry(
            id: asset.id, name: asset.name, type: .audio,
            source: .external(absolutePath: toneURL.path), duration: 4
        ))

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "loudness-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let result = try await client.callTool(name: "measure_loudness", arguments: [
                "target": .string("youtube"),
            ])
            #expect(result.isError != true)
            let payload = try json(text(result.content))
            let integrated = try #require((payload["integratedLufs"] as? NSNumber)?.doubleValue)
            #expect(abs(integrated + 20) < 0.6)
            #expect((payload["truePeakDbtp"] as? NSNumber) != nil)
            let target = try #require(payload["target"] as? [String: Any])
            #expect(target["name"] as? String == "youtube")
            let delta = try #require((target["deltaDb"] as? NSNumber)?.doubleValue)
            #expect(abs(delta - 6) < 0.6)
            #expect(target["truePeakAfterTargetDbtp"] != nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private static func writeTone(dbfs: Double, seconds: Double, to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let amplitude = pow(10, dbfs / 20)
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData)[channel]
            for frame in 0..<Int(frames) {
                samples[frame] = Float(amplitude * sin(2 * .pi * 997 * Double(frame) / 48_000))
            }
        }
        try file.write(from: buffer)
    }

    @Test func measureLoudnessRefusesUnusableRequests() async throws {
        let audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 90)
        let video = Fixtures.clip(id: "video", start: 0, duration: 90)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))

        #expect(await harness.runRaw("measure_loudness", args: ["scope": "clip"]).isError)
        #expect(await harness.runRaw("measure_loudness", args: ["scope": "clip", "clipId": video.id]).isError)
        #expect(await harness.runRaw("measure_loudness", args: ["scope": "clip", "clipId": "missing"]).isError)
        #expect(await harness.runRaw("measure_loudness", args: ["scope": "program"]).isError)
        #expect(await harness.runRaw("measure_loudness", args: ["target": "tiktok"]).isError)
        #expect(await harness.runRaw("measure_loudness", args: ["clipId": audio.id]).isError)
        #expect(await harness.runRaw("measure_loudness", args: ["startFrame": 60, "endFrame": 30]).isError)
        #expect(await harness.runRaw("measure_loudness", args: ["loudness": true]).isError)
    }

    private static func number(_ value: Value?) -> Double? {
        value?.doubleValue ?? value?.intValue.map(Double.init)
    }

    private func timelineClip(client: Client, clipId: String) async throws -> [String: Any] {
        let result = try await client.callTool(name: "get_timeline")
        let payload = try json(text(result.content))
        let tracks = try #require(payload["tracks"] as? [[String: Any]])
        let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
        return try #require(clips.first { $0["id"] as? String == clipId })
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
