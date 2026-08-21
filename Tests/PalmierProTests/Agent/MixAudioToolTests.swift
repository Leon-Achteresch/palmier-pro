import AVFoundation
import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP mix_audio")
@MainActor
struct MixAudioToolTests {

    struct Setup {
        let harness: ToolHarness
        let undoManager: UndoManager
        let dialogId: String
        let bedId: String
        let directory: URL
    }

    static func makeSetup(bedRole: DuckingRole = .bed) throws -> Setup {
        let directory = try AudioFixtures.temporaryDirectory()
        let dialogURL = directory.appendingPathComponent("dialog.caf")
        let bedURL = directory.appendingPathComponent("bed.caf")
        try AudioFixtures.writeTone(dbfs: -12, seconds: 3, to: dialogURL)
        try AudioFixtures.writeTone(dbfs: -30, seconds: 3, to: bedURL)

        let dialogRef = "dialog-\(UUID().uuidString)"
        let bedRef = "bed-\(UUID().uuidString)"
        var dialog = Fixtures.clip(id: "dlg", mediaRef: dialogRef, mediaType: .audio, start: 0, duration: 90)
        dialog.duckingRole = .dialog
        var bed = Fixtures.clip(id: "bed", mediaRef: bedRef, mediaType: .audio, start: 0, duration: 90)
        bed.duckingRole = bedRole

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [dialog]),
            Fixtures.audioTrack(clips: [bed]),
        ]))
        for (ref, url) in [(dialogRef, dialogURL), (bedRef, bedURL)] {
            let asset = MediaAsset(id: ref, url: url, type: .audio, name: ref, duration: 3)
            harness.editor.mediaAssets.append(asset)
            harness.editor.mediaManifest.entries.append(MediaManifestEntry(
                id: ref, name: ref, type: .audio,
                source: .external(absolutePath: url.path), duration: 3
            ))
        }
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        harness.editor.undo.attach(undoManager)
        return Setup(
            harness: harness, undoManager: undoManager,
            dialogId: dialog.id, bedId: bed.id, directory: directory
        )
    }

    static func rows(_ payload: Any) throws -> [String: [String: Any]] {
        let dict = try #require(payload as? [String: Any])
        let mix = try #require(dict["mix"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: mix.compactMap { row in
            (row["clipId"] as? String).map { ($0, row) }
        })
    }

    static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    @Test func dryRunReportsThePlanAndChangesNothing() async throws {
        let setup = try Self.makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }

        let payload = try await setup.harness.runOK("mix_audio", args: ["dryRun": true])
        let dict = try #require(payload as? [String: Any])
        #expect(dict["dryRun"] as? Bool == true)
        #expect(dict["applied"] as? Bool == false)
        #expect(dict["platform"] as? String == "youtube")
        #expect(Self.number(dict["programTargetLufs"]) == -14)

        let rows = try Self.rows(payload)
        let dialog = try #require(rows[setup.dialogId])
        let bed = try #require(rows[setup.bedId])
        #expect(dialog["role"] as? String == "dialog")
        #expect(dialog["roleSource"] as? String == "explicit")
        #expect(Self.number(dialog["targetLufs"]) == -16)
        #expect(Self.number(bed["targetLufs"]) == -28)
        #expect(abs(try #require(Self.number(dialog["measuredLufs"])) + 12) < 1)
        #expect(abs(try #require(Self.number(bed["measuredLufs"])) + 30) < 1)
        for row in [dialog, bed] {
            let measured = try #require(Self.number(row["measuredLufs"]))
            let target = try #require(Self.number(row["targetLufs"]))
            #expect(abs(try #require(Self.number(row["gainDb"])) - (target - measured)) < 0.02)
            #expect(Self.number(row["newVolumeDb"]) == Self.number(row["gainDb"]))
        }
        #expect(try #require(Self.number(dialog["gainDb"])) < 0)
        #expect(try #require(Self.number(bed["gainDb"])) > 0)
        let ducking = try #require(dict["ducking"] as? [String: Any])
        #expect(ducking["enabled"] as? Bool == true)
        #expect(Self.number(ducking["depthDb"]) == -12)

        #expect(setup.harness.editor.clipFor(id: setup.bedId)?.volume == 1)
        #expect(setup.harness.editor.timeline.ducking.enabled == false)
        #expect(setup.undoManager.canUndo == false)
    }

    @Test func applyingLevelsEveryClipAndEnablesDuckingAsOneUndoStep() async throws {
        let setup = try Self.makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let editor = setup.harness.editor

        let payload = try await setup.harness.runOK("mix_audio", args: [:])
        let dict = try #require(payload as? [String: Any])
        #expect(dict["applied"] as? Bool == true)
        #expect(dict["clipsChanged"] as? Int == 2)
        let lufs = try #require(dict["integratedLufs"] as? [String: Any])
        #expect(Self.number(lufs["before"]) != nil)
        #expect(Self.number(lufs["after"]) != nil)

        let rows = try Self.rows(payload)
        for (clipId, row) in rows {
            let expected = try #require(Self.number(row["newVolumeDb"]))
            let actual = VolumeScale.dbFromLinear(try #require(editor.clipFor(id: clipId)?.volume))
            #expect(abs(actual - expected) < 0.02)
        }
        #expect(VolumeScale.dbFromLinear(try #require(editor.clipFor(id: setup.dialogId)?.volume)) < 0)
        #expect(VolumeScale.dbFromLinear(try #require(editor.clipFor(id: setup.bedId)?.volume)) > 0)
        #expect(editor.timeline.ducking.enabled == true)
        #expect(editor.timeline.ducking.depthDb == -12)

        #expect(setup.undoManager.canUndo == true)
        setup.undoManager.undo()
        #expect(editor.clipFor(id: setup.dialogId)?.volume == 1)
        #expect(editor.clipFor(id: setup.bedId)?.volume == 1)
        #expect(editor.timeline.ducking.enabled == false)
        #expect(setup.undoManager.canUndo == false)
    }

    @Test func filmPresetAimsLowerThanYouTube() async throws {
        let setup = try Self.makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let rows = try Self.rows(
            try await setup.harness.runOK("mix_audio", args: ["platform": "film", "dryRun": true])
        )
        let dialog = try #require(rows[setup.dialogId])
        #expect(Self.number(dialog["targetLufs"]) == -25)
        #expect(Self.number(try #require(rows[setup.bedId])["targetLufs"]) == -37)
        let measured = try #require(Self.number(dialog["measuredLufs"]))
        #expect(abs(try #require(Self.number(dialog["gainDb"])) - (-25 - measured)) < 0.02)
    }

    @Test func exemptClipsAreReportedAsSkippedAndLeftAlone() async throws {
        let setup = try Self.makeSetup(bedRole: .exempt)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let payload = try await setup.harness.runOK("mix_audio", args: ["dryRun": true])
        let bed = try #require(try Self.rows(payload)[setup.bedId])
        #expect(bed["role"] as? String == "exempt")
        #expect(bed["skipped"] as? Bool == true)
        #expect(bed["newVolumeDb"] == nil)
        let warnings = try #require((payload as? [String: Any])?["warnings"] as? [String])
        #expect(warnings.contains { $0.contains(setup.bedId) })
    }

    @Test func keyframedVolumeIsPreservedInsteadOfRelevelled() async throws {
        let setup = try Self.makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 0))
        track.upsert(Keyframe(frame: 60, value: -6))
        setup.harness.editor.timeline.tracks[1].clips[0].volumeTrack = track

        _ = try await setup.harness.runOK("mix_audio", args: [:])
        #expect(setup.harness.editor.clipFor(id: setup.bedId)?.volumeTrack == track)
        #expect(setup.harness.editor.clipFor(id: setup.bedId)?.volume == 1)
    }

    @Test func rejectsInvalidArgumentsWithoutTouchingTheTimeline() async throws {
        let setup = try Self.makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        for args: [String: Any] in [
            ["platform": "vimeo"],
            ["dryRun": "yes"],
            ["duckDepthDb": 12],
            ["duckDepthDb": -6, "ducking": false],
            ["loudness": "max"],
        ] {
            let result = await setup.harness.runRaw("mix_audio", args: args)
            #expect(result.isError == true, "expected \(args) to be rejected")
        }
        #expect(setup.harness.editor.timeline.ducking.enabled == false)
        #expect(setup.undoManager.canUndo == false)
    }

    @Test func refusesATimelineWithoutAudio() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)]),
        ]))
        #expect(await harness.runRaw("mix_audio", args: [:]).isError == true)
    }

    @Test func refusesWhenNoClipCanBeClassified() async throws {
        let setup = try Self.makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        for index in setup.harness.editor.timeline.tracks.indices {
            setup.harness.editor.timeline.tracks[index].clips[0].duckingRole = .auto
        }
        let result = await setup.harness.runRaw("mix_audio", args: [:])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("duckingRole"))
    }

    @Test func serverExposesTheToolAndTheDuckingRoleOverride() async throws {
        let setup = try Self.makeSetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: setup.harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "mix-audio-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let mix = try #require(tools.first { $0.name == "mix_audio" })
            let properties = try #require(mix.inputSchema.objectValue?["properties"]?.objectValue)
            let platforms = try #require(properties["platform"]?.objectValue?["enum"]?.arrayValue)
            #expect(Set(platforms.compactMap(\.stringValue)) == ["youtube", "podcast", "film"])
            #expect(properties["dryRun"] != nil)

            let setProperties = try #require(tools.first { $0.name == "set_clip_properties" })
            let clipProperties = try #require(setProperties.inputSchema.objectValue?["properties"]?.objectValue)
            let roles = try #require(clipProperties["duckingRole"]?.objectValue?["enum"]?.arrayValue)
            #expect(Set(roles.compactMap(\.stringValue)) == ["auto", "dialog", "bed", "exempt"])

            let applied = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(setup.bedId)]),
                "duckingRole": .string("exempt"),
            ])
            #expect(applied.isError != true)
            #expect(setup.harness.editor.clipFor(id: setup.bedId)?.duckingRole == .exempt)

            let rejected = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(setup.bedId)]),
                "duckingRole": .string("music"),
            ])
            #expect(rejected.isError == true)
            #expect(setup.harness.editor.clipFor(id: setup.bedId)?.duckingRole == .exempt)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func duckingRoleIsRefusedOnAVideoClipAndReadsBackFromGetTimeline() async throws {
        let video = Fixtures.clip(id: "v", start: 0, duration: 60)
        var audio = Fixtures.clip(id: "a", mediaType: .audio, start: 0, duration: 60)
        audio.mediaRef = "other"
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        #expect(await harness.runRaw("set_clip_properties", args: [
            "clipIds": [video.id], "duckingRole": "bed",
        ]).isError == true)

        _ = try await harness.runOK("set_clip_properties", args: ["clipIds": [audio.id], "duckingRole": "bed"])
        let timeline = try #require(try await harness.runOK("get_timeline") as? [String: Any])
        #expect(timeline["ducking"] == nil)
        let tracks = try #require(timeline["tracks"] as? [[String: Any]])
        let clips = try #require(tracks[1]["clips"] as? [[String: Any]])
        #expect(clips[0]["duckingRole"] as? String == "bed")
        let videoClips = try #require(tracks[0]["clips"] as? [[String: Any]])
        #expect(videoClips[0]["duckingRole"] == nil)
    }
}
