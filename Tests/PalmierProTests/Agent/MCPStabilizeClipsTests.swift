import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP stabilize_clips")
@MainActor
struct MCPStabilizeClipsTests {

    private static func harness(_ extraClips: [Clip] = []) -> ToolHarness {
        let video = Fixtures.clip(id: "video", start: 0, duration: 90)
        return ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video] + extraClips),
        ]))
    }

    private static func reports(_ json: Any?) -> [[String: Any]] {
        ((json as? [String: Any])?["stabilize"] as? [[String: Any]]) ?? []
    }

    @Test func toolIsDiscoverableWithABoundedSmoothingContract() async throws {
        let harness = Self.harness()
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "stabilize-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let stabilize = try #require(tools.first { $0.name == "stabilize_clips" })
            let properties = try #require(stabilize.inputSchema.objectValue?["properties"]?.objectValue)

            #expect(properties["clipIds"] != nil)
            #expect(properties["smoothing"] != nil)
            #expect(properties["remove"] != nil)
            #expect(stabilize.description?.contains("crop") == true)

            let result = try await client.callTool(
                name: "stabilize_clips", arguments: ["clipIds": ["video"], "smoothing": 0.7]
            )
            #expect(result.isError != true)
        }
        await client.disconnect()
        await server.stop()
    }

    @Test func requestingStabilizationRecordsTheStrengthAndStartsOneJob() async throws {
        let harness = Self.harness()
        let json = try await harness.runOK(
            "stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.8]
        ) as? [String: Any]

        let report = try #require(Self.reports(json).first)
        #expect(report["clipId"] as? String == "video")
        #expect(report["status"] as? String == "analyzing")
        #expect(report["jobId"] is String)
        #expect((report["smoothing"] as? NSNumber)?.doubleValue == 0.8)
        #expect(harness.editor.clipFor(id: "video")?.stabilization?.smoothing == 0.8)
        #expect(harness.editor.clipFor(id: "video")?.stabilization?.isAnalyzed == false)
    }

    @Test func pollingARunningJobReportsItRatherThanRestartingIt() async throws {
        let harness = Self.harness()
        let parked = Self.parkAnalyzingJob(harness, smoothing: 0.5)
        defer { harness.editor.stabilizationJobs.forget(clipId: "video") }

        let json = try await harness.runOK(
            "stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.5]
        ) as? [String: Any]

        let report = try #require(Self.reports(json).first)
        #expect(report["jobId"] as? String == parked)
        #expect(report["status"] as? String == "analyzing")
        #expect(report["retriedAfterFailure"] == nil)
        #expect(((json?["notes"] as? [String]) ?? []).contains { $0.contains("already carry") })
    }

    @Test func pollingARunningJobWritesNothingAndAddsNoUndoStep() async throws {
        let harness = Self.harness()
        Self.parkAnalyzingJob(harness, smoothing: 0.5)
        defer { harness.editor.stabilizationJobs.forget(clipId: "video") }
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        _ = try await harness.runOK("stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.5])

        #expect(!undoManager.canUndo)
        #expect(harness.editor.clipFor(id: "video")?.stabilization?.smoothing == 0.5)
    }

    @Test func retryingAFailedAnalysisReportsTheFailureItIsRetrying() async throws {
        let harness = Self.harness()
        Self.parkAnalyzingJob(harness, smoothing: 0.5)
        harness.editor.stabilizationJobs.fail(clipId: "video", reason: "media offline")

        let json = try await harness.runOK(
            "stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.5]
        ) as? [String: Any]

        let report = try #require(Self.reports(json).first)
        #expect(report["retriedAfterFailure"] as? String == "media offline")
        #expect(((json?["notes"] as? [String]) ?? []).contains { $0.contains("media offline") })
    }

    @discardableResult
    private static func parkAnalyzingJob(_ harness: ToolHarness, smoothing: Double) -> String {
        harness.editor.timeline.tracks[0].clips[0].stabilization = .requested(smoothing: smoothing)
        let clip = harness.editor.timeline.tracks[0].clips[0]
        let job = harness.editor.stabilizationJobs.begin(
            clipId: clip.id,
            mediaRef: clip.mediaRef,
            smoothing: smoothing,
            signature: clip.stabilizationSignature(fps: harness.editor.timeline.fps)
        )
        harness.editor.stabilizationJobs.track(
            Task { try? await Task.sleep(for: .seconds(600)) }, forClip: clip.id
        )
        return job.id
    }

    @Test func changingTheStrengthReplacesTheJobAndTheRequest() async throws {
        let harness = Self.harness()
        _ = try await harness.runOK("stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.2])
        let firstJob = try #require(harness.editor.stabilizationJobs.job(forClip: "video")?.id)

        _ = try await harness.runOK("stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.9])

        #expect(harness.editor.stabilizationJobs.job(forClip: "video")?.id != firstJob)
        #expect(harness.editor.clipFor(id: "video")?.stabilization?.smoothing == 0.9)
    }

    @Test func oneRequestIsOneUndoStepAndUndoRemovesTheRequestAndItsJob() async throws {
        let harness = Self.harness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        _ = try await harness.runOK("stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.6])
        #expect(harness.editor.stabilizationJobs.job(forClip: "video") != nil)

        undoManager.undo()

        #expect(harness.editor.clipFor(id: "video")?.stabilization == nil)
        #expect(harness.editor.stabilizationJobs.job(forClip: "video") == nil)
        #expect(!undoManager.canUndo)
    }

    @Test func removingStabilizationIsUndoableAndDropsTheJob() async throws {
        let harness = Self.harness()
        let undoManager = UndoManager()
        _ = try await harness.runOK("stabilize_clips", args: ["clipIds": ["video"]])
        harness.editor.undo.attach(undoManager)

        let json = try await harness.runOK(
            "stabilize_clips", args: ["clipIds": ["video"], "remove": true]
        ) as? [String: Any]

        #expect(Self.reports(json).first?["status"] as? String == "removed")
        #expect(harness.editor.clipFor(id: "video")?.stabilization == nil)
        #expect(harness.editor.stabilizationJobs.job(forClip: "video") == nil)

        undoManager.undo()
        #expect(harness.editor.clipFor(id: "video")?.stabilization?.smoothing == ClipStabilization.defaultSmoothing)
    }

    @Test func removingFromAnUnstabilizedClipReportsANoOpWithoutAnUndoStep() async throws {
        let harness = Self.harness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let json = try await harness.runOK(
            "stabilize_clips", args: ["clipIds": ["video"], "remove": true]
        ) as? [String: Any]

        #expect(json?["status"] as? String == "noop")
        #expect(!undoManager.canUndo)
    }

    @Test(arguments: [ClipType.image, .text, .audio, .adjustment])
    func nonVideoClipsAreRefusedBeforeAnythingIsWritten(_ type: ClipType) async {
        let harness = Self.harness([Fixtures.clip(id: "other", mediaType: type, start: 120, duration: 30)])
        let result = await harness.runRaw("stabilize_clips", args: ["clipIds": ["video", "other"]])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("unsupported_media"))
        #expect(harness.editor.clipFor(id: "video")?.stabilization == nil)
        #expect(harness.editor.stabilizationJobs.job(forClip: "video") == nil)
    }

    @Test func multicamMembersAreRefused() async {
        var member = Fixtures.clip(id: "angle", start: 120, duration: 30)
        member.multicamGroupId = "group-1"
        let harness = Self.harness([member])

        let result = await harness.runRaw("stabilize_clips", args: ["clipIds": ["angle"]])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("multicam_member"))
    }

    @Test func nestedTimelineClipsAreRefused() async {
        var nest = Fixtures.clip(id: "nest", start: 120, duration: 30)
        nest.sourceClipType = .sequence
        let harness = Self.harness([nest])

        let result = await harness.runRaw("stabilize_clips", args: ["clipIds": ["nest"]])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("unsupported_media"))
    }

    @Test(arguments: [-0.5, 1.5])
    func smoothingOutsideZeroToOneIsRefused(_ smoothing: Double) async {
        let harness = Self.harness()
        let result = await harness.runRaw(
            "stabilize_clips", args: ["clipIds": ["video"], "smoothing": smoothing]
        )

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("smoothing_out_of_range"))
        #expect(harness.editor.clipFor(id: "video")?.stabilization == nil)
    }

    @Test func unknownClipsAndEmptyRequestsAreRefused() async {
        let harness = Self.harness()

        #expect(await harness.runRaw("stabilize_clips", args: ["clipIds": []]).isError)
        #expect(await harness.runRaw("stabilize_clips", args: ["clipIds": ["nope"]]).isError)
        #expect(
            await harness.runRaw(
                "stabilize_clips", args: ["clipIds": ["video"], "remove": true, "smoothing": 0.5]
            ).isError
        )
    }

    @Test func getTimelineReportsTheStateWithoutTheBakedSamplePayload() async throws {
        let harness = Self.harness()
        _ = try await harness.runOK("stabilize_clips", args: ["clipIds": ["video"], "smoothing": 0.4])
        harness.editor.timeline.tracks[0].clips[0].stabilization = ClipStabilization(
            smoothing: 0.4, startSourceSeconds: 0, endSourceSeconds: 3, sampleRate: 30,
            cropScale: 1.25,
            samples: [StabilizationSample](repeating: StabilizationSample(dx: 0.01, dy: 0, rotation: 0), count: 90)
        )

        let json = try await harness.runOK("get_timeline") as? [String: Any]
        let tracks = try #require(json?["tracks"] as? [[String: Any]])
        let clip = try #require((tracks[0]["clips"] as? [[String: Any]])?.first)
        let stabilize = try #require(clip["stabilize"] as? [String: Any])

        #expect(clip["stabilization"] == nil)
        #expect(stabilize["state"] as? String == "ready")
        #expect(abs(((stabilize["cropPercent"] as? NSNumber)?.doubleValue ?? 0) - 20) < 0.01)
        #expect((stabilize["smoothing"] as? NSNumber)?.doubleValue == 0.4)
    }
}

@Suite("Stabilization — editor lifecycle")
@MainActor
struct StabilizationEditorTests {

    private static func editor() -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "video", start: 0, duration: 90)]),
        ])
        return editor
    }

    @Test func aBakedClipThatStillCoversItsSourceRangeIsNotAWriteTarget() {
        let editor = Self.editor()
        editor.timeline.tracks[0].clips[0].stabilization = ClipStabilization(
            smoothing: 0.5, startSourceSeconds: 0, endSourceSeconds: 3, sampleRate: 30,
            cropScale: 1.1,
            samples: [StabilizationSample](repeating: .identity, count: 90)
        )

        #expect(editor.stabilizationWriteTargets(clipIds: ["video"], enabled: true, smoothing: 0.5).isEmpty)
        #expect(!editor.stabilizationWriteTargets(clipIds: ["video"], enabled: true, smoothing: 0.9).isEmpty)
        #expect(!editor.stabilizationWriteTargets(clipIds: ["video"], enabled: false).isEmpty)
    }

    @Test func strippingStabilizationMidAnalysisLeavesNoPartialBake() {
        let editor = Self.editor()
        editor.setStabilization(clipIds: ["video"], enabled: true, actionName: "Stabilize Clip")
        #expect(editor.stabilizationJobs.job(forClip: "video")?.state == .analyzing)

        editor.setStabilization(clipIds: ["video"], enabled: false, actionName: "Remove Stabilization")

        #expect(editor.clipFor(id: "video")?.stabilization == nil)
        #expect(editor.stabilizationJobs.job(forClip: "video") == nil)
        #expect(!editor.stabilizationJobs.hasTask(forClip: "video"))
    }

    @Test func deletingAStabilizedClipRetiresItsJob() {
        let editor = Self.editor()
        editor.setStabilization(clipIds: ["video"], enabled: true, actionName: "Stabilize Clip")
        #expect(editor.stabilizationJobs.job(forClip: "video") != nil)

        editor.timeline.tracks[0].clips.removeAll()
        editor.resumePendingStabilizations()

        #expect(editor.stabilizationJobs.job(forClip: "video") == nil)
    }

    @Test func aFailedAnalysisIsNotRetriedUntilTheRequestChanges() {
        let editor = Self.editor()
        editor.setStabilization(clipIds: ["video"], enabled: true, actionName: "Stabilize Clip")
        editor.stabilizationJobs.fail(clipId: "video", reason: "offline")

        editor.resumePendingStabilizations()
        #expect(editor.stabilizationJobs.job(forClip: "video")?.state == .failed)
        #expect(editor.stabilizationRetryTargets(clipIds: ["video"]) == ["video"])

        editor.setStabilization(clipIds: ["video"], enabled: true, smoothing: 0.5, actionName: "Retry")
        #expect(editor.stabilizationJobs.job(forClip: "video")?.state == .analyzing)
    }

    @Test func swappingTheClipsMediaDropsTheBakeItWasMeasuredOn() {
        let editor = Self.editor()
        editor.timeline.tracks[0].clips[0].stabilization = ClipStabilization(
            smoothing: 0.5, startSourceSeconds: 0, endSourceSeconds: 3, sampleRate: 30,
            cropScale: 1.1, samples: [StabilizationSample](repeating: .identity, count: 90)
        )

        editor.replaceClipMediaRef(clipId: "video", newAssetId: "other-media")

        #expect(editor.clipFor(id: "video")?.stabilization == nil)
    }
}
