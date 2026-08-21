import AVFoundation
import Testing
@testable import PalmierPro

@Suite("Proxy natural size normalization")
struct ProxyNaturalSizeTests {
    private let renderSize = CGSize(width: 1920, height: 1080)

    private func placedRect(_ transform: Transform, natSize: CGSize) -> CGRect {
        CGRect(origin: .zero, size: natSize).applying(
            CompositionBuilder.affineTransform(for: transform, natSize: natSize, renderSize: renderSize)
        )
    }

    @Test(arguments: [
        Transform(),
        Transform(width: 0.5, height: 0.5),
        Transform(centerX: 0.25, centerY: 0.75, width: 0.4, height: 0.4),
        Transform(centerX: 0.5, centerY: 0.5, width: 1, height: 1, rotation: 33),
        Transform(centerX: 0.3, centerY: 0.6, width: 0.8, height: 0.8, flipHorizontal: true),
    ])
    func proxySizeRendersIdenticalPlacement(transform: Transform) {
        let source = CGSize(width: 3840, height: 2160)
        let proxy = ProxyPlan.targetSize(displaySize: source)!
        let full = placedRect(transform, natSize: source)
        let proxied = placedRect(transform, natSize: proxy)
        #expect(abs(full.minX - proxied.minX) < 0.001)
        #expect(abs(full.minY - proxied.minY) < 0.001)
        #expect(abs(full.width - proxied.width) < 0.001)
        #expect(abs(full.height - proxied.height) < 0.001)
    }

    @Test func portraitProxyKeepsAspectRatio() throws {
        let source = CGSize(width: 1080, height: 1920)
        let proxy = try #require(ProxyPlan.targetSize(displaySize: source))
        let sourceAspect = source.width / source.height
        let proxyAspect = proxy.width / proxy.height
        #expect(abs(sourceAspect - proxyAspect) < 0.01)
    }
}

@Suite("Proxy composition build")
struct ProxyCompositionTests {
    @Test func videoLaneUsesTheProxyWhileAudioStaysOnTheOriginal() async throws {
        let originalSize = CGSize(width: 320, height: 180)
        let proxySize = CGSize(width: 160, height: 90)
        let originalPNG = try CompositorFixtures.patternPNG(size: originalSize)
        let proxyPNG = try CompositorFixtures.patternPNG(size: proxySize)
        let original = try await ImageVideoGenerator.stillVideo(
            for: originalPNG, mediaRef: "proxy-original", size: originalSize
        )
        let proxy = try await ImageVideoGenerator.stillVideo(
            for: proxyPNG, mediaRef: "proxy-half", size: proxySize
        )

        var clip = Fixtures.clip(id: "c1", mediaRef: "src", start: 0, duration: 30)
        clip.mediaType = .video
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        let proxied = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "src" ? original : nil },
            resolveVideoURL: { $0 == "src" ? proxy : nil },
            renderSize: originalSize
        )
        #expect(proxied.clipNaturalSizes["c1"] == proxySize)

        let full = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "src" ? original : nil },
            renderSize: originalSize
        )
        #expect(full.clipNaturalSizes["c1"] == originalSize)
        #expect(proxied.mediaFingerprints["src"] != full.mediaFingerprints["src"])
    }
}
