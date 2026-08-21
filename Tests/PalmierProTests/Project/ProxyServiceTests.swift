import AVFoundation
import Testing
@testable import PalmierPro

@MainActor
private struct ProxyFixture {
    let editor = EditorViewModel()
    let projectURL: URL

    init() throws {
        projectURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        editor.projectURL = projectURL
    }

    @discardableResult
    func asset(_ id: String, type: ClipType = .video) -> MediaAsset {
        let url = projectURL.appendingPathComponent("media/\(id).mov", isDirectory: false)
        let asset = MediaAsset(id: id, url: url, type: type, name: id, duration: 1)
        editor.mediaAssets.append(asset)
        editor.updateManifestMetadata(for: [asset])
        return asset
    }

    func proxyURL(_ assetId: String) -> URL {
        ProxyPlan.url(assetId: assetId, projectURL: projectURL)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func settle() async throws {
        var spins = 0
        while editor.proxyService.pendingCount > 0 {
            await Task.yield()
            spins += 1
            if spins > 200_000 { throw SettleTimeout() }
        }
        await editor.pendingManifestMetadataFlushTask?.value
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: projectURL)
    }
}

private struct SettleTimeout: Error {}

@MainActor
private final class TranscodeProbe {
    private(set) var stagedPaths: [String] = []
    private(set) var peakConcurrency = 0
    private var active = 0
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(parks: Bool = false) {
        isOpen = !parks
    }

    func begin(_ output: URL) {
        stagedPaths.append(output.path)
        active += 1
        peakConcurrency = max(peakConcurrency, active)
    }

    func end() {
        active -= 1
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private func stubTranscode(_ probe: TranscodeProbe) -> @Sendable (URL, URL) async throws -> CGSize {
    { _, output in
        await probe.begin(output)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x1]).write(to: output)
        await probe.wait()
        await probe.end()
        try Task.checkCancellation()
        return CGSize(width: 960, height: 540)
    }
}

@Suite("Proxy generation queue", .serialized)
@MainActor
struct ProxyServiceTests {
    @Test func readyProxyIsStagedOutsideThePackageAndInstalledInside() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let probe = TranscodeProbe()
        fixture.editor.proxyService.transcode = stubTranscode(probe)
        let asset = fixture.asset("clip-a")

        #expect(fixture.editor.proxyService.enqueue(asset) == nil)
        try await fixture.settle()

        #expect(asset.proxyStatus == .ready)
        #expect(fixture.exists(fixture.proxyURL("clip-a")))
        let staged = try #require(probe.stagedPaths.first)
        #expect(!staged.hasPrefix(fixture.projectURL.path))
        #expect(fixture.editor.mediaManifest.entries.first?.proxyStatus == "ready")
    }

    @Test func failureReportsTheReasonAndLeavesNoFile() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        fixture.editor.proxyService.transcode = { _, _ in throw ProxyTranscodeError.noVideoTrack }
        let asset = fixture.asset("clip-b")

        fixture.editor.proxyService.enqueue(asset)
        try await fixture.settle()

        #expect(asset.proxyStatus.failureMessage == ProxyTranscodeError.noVideoTrack.errorDescription)
        #expect(!fixture.exists(fixture.proxyURL("clip-b")))
        #expect(fixture.editor.mediaManifest.entries.first?.proxyStatus?.hasPrefix("failed: ") == true)
    }

    @Test func cancelDropsInFlightWorkWithoutInstalling() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let probe = TranscodeProbe(parks: true)
        fixture.editor.proxyService.transcode = stubTranscode(probe)
        let asset = fixture.asset("clip-c")

        fixture.editor.proxyService.enqueue(asset)
        while asset.proxyStatus != .generating { await Task.yield() }
        #expect(fixture.editor.proxyService.cancel(assetId: asset.id))
        #expect(asset.proxyStatus == .none)
        probe.release()
        try await fixture.settle()

        #expect(asset.proxyStatus == .none)
        #expect(!fixture.exists(fixture.proxyURL("clip-c")))
    }

    @Test func requeueingACancelledAssetIsNotClobberedByTheSupersededRun() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let probe = TranscodeProbe(parks: true)
        fixture.editor.proxyService.transcode = stubTranscode(probe)
        let asset = fixture.asset("clip-requeue")

        fixture.editor.proxyService.enqueue(asset)
        while asset.proxyStatus != .generating { await Task.yield() }
        #expect(fixture.editor.proxyService.cancel(assetId: asset.id))
        #expect(fixture.editor.proxyService.enqueue(asset) == nil)
        while asset.proxyStatus != .generating { await Task.yield() }
        probe.release()
        try await fixture.settle()

        #expect(asset.proxyStatus == .ready)
        #expect(fixture.exists(fixture.proxyURL("clip-requeue")))
        #expect(fixture.editor.proxyService.pendingCount == 0)
    }

    @Test func atMostTwoAssetsTranscodeAtOnce() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let probe = TranscodeProbe(parks: true)
        fixture.editor.proxyService.transcode = stubTranscode(probe)
        let assets = (0..<5).map { fixture.asset("clip-\($0)") }

        for asset in assets { fixture.editor.proxyService.enqueue(asset) }
        while fixture.editor.proxyService.generatingIds.count < ProxyService.maxConcurrent {
            await Task.yield()
        }
        #expect(fixture.editor.proxyService.generatingIds.count == ProxyService.maxConcurrent)
        #expect(fixture.editor.proxyService.waitingIds.count == 3)
        probe.release()
        try await fixture.settle()

        #expect(probe.peakConcurrency <= ProxyService.maxConcurrent)
        #expect(assets.allSatisfy { $0.proxyStatus == .ready })
    }

    @Test func aRelinkedSourceDiscardsTheFinishedTranscode() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let probe = TranscodeProbe(parks: true)
        fixture.editor.proxyService.transcode = stubTranscode(probe)
        let asset = fixture.asset("clip-d")

        fixture.editor.proxyService.enqueue(asset)
        while asset.proxyStatus != .generating { await Task.yield() }
        asset.url = URL(fileURLWithPath: "/tmp/relinked-\(UUID().uuidString).mov")
        probe.release()
        try await fixture.settle()

        #expect(asset.proxyStatus == .none)
        #expect(!fixture.exists(fixture.proxyURL("clip-d")))
    }

    @Test func removeDeletesTheInstalledProxyAndRepeatsAsNoOp() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        fixture.editor.proxyService.transcode = stubTranscode(TranscodeProbe())
        let asset = fixture.asset("clip-e")
        fixture.editor.proxyService.enqueue(asset)
        try await fixture.settle()

        #expect(try await fixture.editor.proxyService.removeProxy(for: asset))
        #expect(asset.proxyStatus == .none)
        #expect(!fixture.exists(fixture.proxyURL("clip-e")))
        #expect(!(try await fixture.editor.proxyService.removeProxy(for: asset)))
    }

    @Test func refusalsAreReportedInsteadOfQueueing() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let probe = TranscodeProbe(parks: true)
        fixture.editor.proxyService.transcode = stubTranscode(probe)

        #expect(fixture.editor.proxyService.enqueue(fixture.asset("audio", type: .audio)) == .notVideo)

        let unsaved = EditorViewModel()
        let orphan = MediaAsset(id: "x", url: URL(fileURLWithPath: "/tmp/x.mov"), type: .video, name: "x")
        unsaved.mediaAssets = [orphan]
        #expect(unsaved.proxyService.enqueue(orphan) == .projectNotSaved)

        let video = fixture.asset("clip-f")
        video.proxyStatus = .ready
        #expect(fixture.editor.proxyService.enqueue(video) == .alreadyReady)
        #expect(fixture.editor.proxyService.enqueue(video, regenerate: true) == nil)
        #expect(fixture.editor.proxyService.enqueue(video, regenerate: true) == .alreadyPending)
        probe.release()
        try await fixture.settle()
    }

    @Test func restoreDropsReadyStatusWhenTheProxyFileIsGone() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let asset = fixture.asset("clip-g")
        asset.proxyStatus = .ready
        fixture.editor.updateManifestMetadata(for: [asset])

        fixture.editor.verifyRestoredProxies()
        while asset.proxyStatus == .ready { await Task.yield() }
        #expect(asset.proxyStatus == .none)
    }

    @Test func playbackMapSwapsOnlyReadyProxiesAndNeverForExport() async throws {
        let fixture = try ProxyFixture()
        defer { fixture.cleanUp() }
        let ready = fixture.asset("ready")
        ready.proxyStatus = .ready
        let pending = fixture.asset("pending")
        pending.proxyStatus = .generating

        fixture.editor.useProxies = true
        let playback = fixture.editor.mediaURLMap(quality: .playback)
        #expect(playback["ready"] == fixture.proxyURL("ready"))
        #expect(playback["pending"] == pending.url)
        #expect(fixture.editor.mediaURLMap(quality: .full)["ready"] == ready.url)

        fixture.editor.useProxies = false
        #expect(fixture.editor.mediaURLMap(quality: .playback)["ready"] == ready.url)
    }
}
