import AVFoundation
import AppKit
import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP — assemble montage")
@MainActor
struct MCPAssembleMontageTests {

    // MARK: - Fixture

    private final class Scratch {
        let directory: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pp-montage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// A silent bed of known length. The beats come from `seed`, not the detector — these tests
    /// prove the montage, and loading the Core ML model here would make them environment-dependent.
    private static func writeBed(to url: URL, duration: Double) throws {
        let sr = 44100.0
        let n = Int(duration * sr)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        buffer.floatChannelData![0].update(repeating: 0, count: n)
        try file.write(from: buffer)
    }

    /// 120 BPM: a beat every half second, a downbeat every four.
    private static func analysis(seconds: Double, bpm: Double = 120) -> BeatAnalysis {
        let interval = 60.0 / bpm
        var beats: [Double] = []
        var t = 0.0
        while t < seconds {
            beats.append(t)
            t += interval
        }
        let downbeats = beats.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        return BeatAnalysis(bpm: bpm, beats: beats, downbeats: downbeats)
    }

    private static func writeStill(to url: URL) throws {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }

    private struct Fixture {
        let harness: ToolHarness
        let scratch: Scratch
        let undoManager: UndoManager
    }

    private static func fixture(stills: Int = 4, musicSeconds: Double = 12) async throws -> Fixture {
        let scratch = try Scratch()
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [])]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let musicURL = scratch.directory.appendingPathComponent("bed.wav")
        try writeBed(to: musicURL, duration: musicSeconds)
        let music = MediaAsset(id: "music", url: musicURL, type: .audio, name: "bed", duration: musicSeconds)
        register(music, on: harness)
        await harness.editor.mediaVisualCache.beats.seed(analysis(seconds: musicSeconds), for: music)
        for index in 0..<stills {
            let url = scratch.directory.appendingPathComponent("still-\(index).png")
            try writeStill(to: url)
            register(
                MediaAsset(id: "shot-\(index)", url: url, type: .image, name: "still \(index)", duration: 0),
                on: harness
            )
        }
        return Fixture(harness: harness, scratch: scratch, undoManager: undoManager)
    }

    /// Receipts carry ids shortened to a unique prefix; the timeline still holds the full ones.
    private static func clip(matching shortId: String, in editor: EditorViewModel) -> Clip? {
        editor.timeline.tracks
            .flatMap(\.clips)
            .first { $0.id.hasPrefix(shortId) }
    }

    private static func register(_ asset: MediaAsset, on harness: ToolHarness) {
        harness.editor.mediaAssets.append(asset)
        harness.editor.mediaManifest.entries.append(MediaManifestEntry(
            id: asset.id, name: asset.name, type: asset.type,
            source: .external(absolutePath: asset.url.path), duration: asset.duration
        ))
    }

    // MARK: - Tests

    @Test func discoverySchemaExposesTheGridAndEnergyVocabulary() async throws {
        let fixture = try await Self.fixture()
        try await withClient(fixture.harness) { client in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "assemble_montage" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let energy = try #require(properties["energy"]?.objectValue?["enum"]?.arrayValue)
            #expect(energy.compactMap(\.stringValue).sorted() == ["build", "buildAndRelease", "flat"])
            let grid = try #require(properties["grid"]?.objectValue?["enum"]?.arrayValue)
            #expect(grid.compactMap(\.stringValue).sorted() == ["beat", "downbeat"])
            let required = try #require(tool.inputSchema.objectValue?["required"]?.arrayValue)
            #expect(Set(required.compactMap(\.stringValue)) == ["mediaRefs", "musicRef"])
        }
    }

    @Test func aFlatMontageCutsOnTheReportedBeatsAndPlacesTheBed() async throws {
        let fixture = try await Self.fixture(stills: 4)
        let editor = fixture.harness.editor

        try await withClient(fixture.harness) { client in
            let result = try await client.callTool(name: "assemble_montage", arguments: [
                "mediaRefs": .array([.string("shot-0"), .string("shot-1"), .string("shot-2"), .string("shot-3")]),
                "musicRef": .string("music"),
            ])
            let body = try self.text(result.content)
            #expect(result.isError != true, "\(body)")
            let payload = try self.json(result.content)

            let bpm = try #require((payload["bpm"] as? NSNumber)?.doubleValue)
            #expect(abs(bpm - 120) < 0.5, "the bed is 120 BPM, got \(bpm)")

            let shots = try #require(payload["shots"] as? [[String: Any]])
            #expect(shots.count == 4)
            let cutFrames = try #require(payload["cutFrames"] as? [Int])
            #expect(cutFrames == shots.map { $0["startFrame"] as? Int ?? -1 })

            // Every reported cut must exist on the timeline exactly where the receipt says.
            for shot in shots {
                let id = try #require(shot["clipId"] as? String)
                let clip = try #require(Self.clip(matching: id, in: editor))
                #expect(clip.startFrame == shot["startFrame"] as? Int)
                #expect(clip.startFrame + clip.durationFrames == shot["endFrame"] as? Int)
            }
            for (a, b) in zip(shots, shots.dropFirst()) {
                #expect(a["endFrame"] as? Int == b["startFrame"] as? Int, "montage cuts must be contiguous")
            }

            let bedId = try #require(payload["musicClipId"] as? String)
            let bed = try #require(Self.clip(matching: bedId, in: editor))
            #expect(bed.mediaRef == "music")
            #expect(bed.startFrame == 0)

            // At 120 BPM on a 30 fps timeline a beat is 15 frames.
            let durations = Set(shots.compactMap { shot -> Int? in
                guard let s = shot["startFrame"] as? Int, let e = shot["endFrame"] as? Int else { return nil }
                return e - s
            })
            #expect(durations.allSatisfy { abs($0 - 15) <= 1 }, "flat energy should cut on every beat: \(durations)")
        }
    }

    @Test func theWholeMontageIsASingleUndoStep() async throws {
        let fixture = try await Self.fixture(stills: 4)
        let editor = fixture.harness.editor
        let tracksBefore = editor.timeline.tracks.count

        try await withClient(fixture.harness) { client in
            let result = try await client.callTool(name: "assemble_montage", arguments: [
                "mediaRefs": .array([.string("shot-0"), .string("shot-1"), .string("shot-2")]),
                "musicRef": .string("music"),
            ])
            #expect(result.isError != true)
            #expect(editor.timeline.tracks.contains { !$0.clips.isEmpty })

            let undo = try await client.callTool(name: "undo")
            #expect(undo.isError != true)
            #expect(editor.timeline.tracks.allSatisfy { $0.clips.isEmpty },
                    "one undo must take every shot and the bed with it")
            #expect(editor.timeline.tracks.count == tracksBefore,
                    "the tracks the montage created must go too")
        }
    }

    @Test func buildEnergyStartsWideAndTightensToOneBeat() async throws {
        let fixture = try await Self.fixture(stills: 4, musicSeconds: 20)

        try await withClient(fixture.harness) { client in
            let result = try await client.callTool(name: "assemble_montage", arguments: [
                "mediaRefs": .array([.string("shot-0"), .string("shot-1"), .string("shot-2"), .string("shot-3")]),
                "musicRef": .string("music"),
                "energy": .string("build"),
            ])
            let body = try self.text(result.content)
            #expect(result.isError != true, "\(body)")
            let shots = try #require(try self.json(result.content)["shots"] as? [[String: Any]])
            let durations = shots.compactMap { shot -> Int? in
                guard let s = shot["startFrame"] as? Int, let e = shot["endFrame"] as? Int else { return nil }
                return e - s
            }
            #expect(durations.count == 4)
            #expect(durations == durations.sorted(by: >), "build must only tighten: \(durations)")
            let widest = try #require(durations.first)
            let tightest = try #require(durations.last)
            #expect(widest > tightest, "build must actually change the cut rate: \(durations)")
        }
    }

    @Test func bookendRepeatsTheOpeningShotAsTheCloser() async throws {
        let fixture = try await Self.fixture(stills: 3, musicSeconds: 20)

        try await withClient(fixture.harness) { client in
            let result = try await client.callTool(name: "assemble_montage", arguments: [
                "mediaRefs": .array([.string("shot-0"), .string("shot-1"), .string("shot-2")]),
                "musicRef": .string("music"),
                "bookend": .bool(true),
            ])
            let body = try self.text(result.content)
            #expect(result.isError != true, "\(body)")
            let shots = try #require(try self.json(result.content)["shots"] as? [[String: Any]])
            #expect(shots.count == 4)
            #expect(shots.first?["mediaRef"] as? String == "shot-0")
            #expect(shots.last?["mediaRef"] as? String == "shot-0")
        }
    }

    @Test(arguments: [
        ["shot-0"],
        ["shot-0", "music"],
    ])
    func refusedRequestsLeaveTheTimelineUntouched(refs: [String]) async throws {
        let fixture = try await Self.fixture()
        let editor = fixture.harness.editor

        try await withClient(fixture.harness) { client in
            let result = try await client.callTool(name: "assemble_montage", arguments: [
                "mediaRefs": .array(refs.map { .string($0) }),
                "musicRef": .string("music"),
            ])
            #expect(result.isError == true, "\(refs) is not a valid montage")
            #expect(editor.timeline.tracks.allSatisfy { $0.clips.isEmpty })
        }
    }

    @Test func anUnknownEnergyIsRefusedBeforeAnythingIsPlaced() async throws {
        let fixture = try await Self.fixture()
        let editor = fixture.harness.editor

        try await withClient(fixture.harness) { client in
            let result = try await client.callTool(name: "assemble_montage", arguments: [
                "mediaRefs": .array([.string("shot-0"), .string("shot-1")]),
                "musicRef": .string("music"),
                "energy": .string("crescendo"),
            ])
            #expect(result.isError == true)
            #expect(editor.timeline.tracks.allSatisfy { $0.clips.isEmpty })
        }
    }

    @Test func aTargetTrackThatIsNotVideoIsRefused() async throws {
        let scratch = try Scratch()
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [])]))
        let musicURL = scratch.directory.appendingPathComponent("bed.wav")
        try Self.writeBed(to: musicURL, duration: 12)
        let music = MediaAsset(id: "music", url: musicURL, type: .audio, name: "bed", duration: 12)
        Self.register(music, on: harness)
        await harness.editor.mediaVisualCache.beats.seed(Self.analysis(seconds: 12), for: music)
        for index in 0..<2 {
            let url = scratch.directory.appendingPathComponent("still-\(index).png")
            try Self.writeStill(to: url)
            Self.register(
                MediaAsset(id: "shot-\(index)", url: url, type: .image, name: "still", duration: 0),
                on: harness
            )
        }

        try await withClient(harness) { client in
            let result = try await client.callTool(name: "assemble_montage", arguments: [
                "mediaRefs": .array([.string("shot-0"), .string("shot-1")]),
                "musicRef": .string("music"),
                "trackIndex": .int(0),
            ])
            #expect(result.isError == true)
            #expect(harness.editor.timeline.tracks.allSatisfy { $0.clips.isEmpty })
        }
        _ = scratch
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
        let client = Client(name: "montage-test", version: "1.0.0")
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

    private func json(_ content: [Tool.Content]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(try text(content).utf8)) as? [String: Any])
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
