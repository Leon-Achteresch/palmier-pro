import Foundation
import Testing
@testable import PalmierPro

@Suite("Proxy resolution")
struct ProxyResolutionTests {
    private let original = URL(fileURLWithPath: "/tmp/original.mov")
    private let proxyURL = URL(fileURLWithPath: "/tmp/proxies/asset.mov")

    private func reference(_ status: ProxyStatus) -> ProxyReference {
        ProxyReference(url: proxyURL, status: status)
    }

    @Test(arguments: [ProxyStatus.none, .queued, .generating, .failed("boom")])
    func unfinishedProxyKeepsOriginal(status: ProxyStatus) {
        let resolved = ProxyResolution.url(
            original: original, proxy: reference(status), useProxies: true, quality: .playback
        )
        #expect(resolved == original)
    }

    @Test func readyProxyPlaysWhenEnabled() {
        let resolved = ProxyResolution.url(
            original: original, proxy: reference(.ready), useProxies: true, quality: .playback
        )
        #expect(resolved == proxyURL)
    }

    @Test func disabledProxiesKeepOriginal() {
        let resolved = ProxyResolution.url(
            original: original, proxy: reference(.ready), useProxies: false, quality: .playback
        )
        #expect(resolved == original)
    }

    @Test func fullQualityNeverUsesProxy() {
        let resolved = ProxyResolution.url(
            original: original, proxy: reference(.ready), useProxies: true, quality: .full
        )
        #expect(resolved == original)
    }

    @Test func missingOriginalStaysOffline() {
        let resolved = ProxyResolution.url(
            original: nil, proxy: reference(.ready), useProxies: true, quality: .playback
        )
        #expect(resolved == nil)
    }

    @Test func mapSubstitutesOnlyReadyEntries() {
        let originals = [
            "ready": original,
            "pending": URL(fileURLWithPath: "/tmp/pending.mov"),
            "plain": URL(fileURLWithPath: "/tmp/plain.mov"),
        ]
        let proxies = [
            "ready": reference(.ready),
            "pending": reference(.generating),
        ]
        let resolved = ProxyResolution.urlMap(
            originals: originals, proxies: proxies, useProxies: true, quality: .playback
        )
        #expect(resolved["ready"] == proxyURL)
        #expect(resolved["pending"] == originals["pending"])
        #expect(resolved["plain"] == originals["plain"])
    }

    @Test func mapIsUnchangedForFullQuality() {
        let originals = ["ready": original]
        let resolved = ProxyResolution.urlMap(
            originals: originals, proxies: ["ready": reference(.ready)], useProxies: true, quality: .full
        )
        #expect(resolved == originals)
    }
}

@Suite("Proxy plan")
struct ProxyPlanTests {
    @Test(arguments: [
        (CGSize(width: 1920, height: 1080), CGSize(width: 960, height: 540)),
        (CGSize(width: 3840, height: 2160), CGSize(width: 960, height: 540)),
        (CGSize(width: 1280, height: 720), CGSize(width: 640, height: 360)),
        (CGSize(width: 1080, height: 1920), CGSize(width: 540, height: 960)),
        (CGSize(width: 2160, height: 3840), CGSize(width: 960, height: 1706)),
        (CGSize(width: 1279, height: 721), CGSize(width: 640, height: 360)),
        (CGSize(width: 20, height: 12), CGSize(width: 16, height: 16)),
    ])
    func targetSizeHalvesAndCapsToEvenEdges(source: CGSize, expected: CGSize) throws {
        let target = try #require(ProxyPlan.targetSize(displaySize: source))
        #expect(target == expected)
        #expect(target.width.truncatingRemainder(dividingBy: 2) == 0)
        #expect(target.height.truncatingRemainder(dividingBy: 2) == 0)
    }

    @Test(arguments: [
        CGSize(width: 0, height: 1080),
        CGSize(width: 1920, height: 0),
        CGSize(width: CGFloat.nan, height: 1080),
        CGSize(width: CGFloat.infinity, height: 1080),
        CGSize(width: 0.4, height: 0.4),
    ])
    func unusableSizesAreRejected(source: CGSize) {
        #expect(ProxyPlan.targetSize(displaySize: source) == nil)
    }

    @Test func onlyVideoIsEligible() {
        #expect(ProxyPlan.isEligible(type: .video))
        for type in [ClipType.audio, .image, .text, .lottie, .motion, .sequence, .adjustment] {
            #expect(!ProxyPlan.isEligible(type: type))
        }
    }

    @Test func proxyPathLivesInThePackageProxyDirectory() {
        let projectURL = URL(fileURLWithPath: "/tmp/Demo.palmier")
        #expect(ProxyPlan.relativePath(assetId: "abc") == "proxies/abc.mov")
        #expect(ProxyPlan.url(assetId: "abc", projectURL: projectURL).path == "/tmp/Demo.palmier/proxies/abc.mov")
    }
}

@Suite("Proxy status persistence")
@MainActor
struct ProxyStatusPersistenceTests {
    private func roundTrip(_ status: ProxyStatus) -> ProxyStatus {
        let asset = MediaAsset(id: "a", url: URL(fileURLWithPath: "/tmp/a.mov"), type: .video, name: "A")
        asset.proxyStatus = status
        let entry = asset.toManifestEntry(projectURL: nil)
        return MediaAsset(entry: entry, resolvedURL: asset.url).proxyStatus
    }

    @Test func readyAndFailureSurviveASaveCycle() {
        #expect(roundTrip(.ready) == .ready)
        #expect(roundTrip(.failed("encoder said no")) == .failed("encoder said no"))
    }

    @Test(arguments: [ProxyStatus.queued, .generating])
    func inFlightWorkRestoresAsNone(status: ProxyStatus) {
        #expect(roundTrip(status) == .none)
    }

    @Test func manifestOmitsStatusForAssetsWithoutProxies() {
        let asset = MediaAsset(id: "a", url: URL(fileURLWithPath: "/tmp/a.mov"), type: .video, name: "A")
        #expect(asset.toManifestEntry(projectURL: nil).proxyStatus == nil)
    }

    @Test func legacyManifestEntriesDecodeAsNone() throws {
        let json = #"{"id":"a","name":"A","type":"video","source":{"external":{"absolutePath":"/tmp/a.mov"}},"duration":1}"#
        let entry = try JSONDecoder().decode(MediaManifestEntry.self, from: Data(json.utf8))
        #expect(MediaAsset(entry: entry, resolvedURL: URL(fileURLWithPath: "/tmp/a.mov")).proxyStatus == .none)
    }
}
