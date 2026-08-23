import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("Text accent")
struct TextAccentRenderTests {
    private static let size = CGSize(width: 320, height: 180)
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func clip(content: String, accent: TextAccent?, animation: TextAnimation? = nil) -> Clip {
        var style = TextStyle()
        style.color = TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1)
        style.fontSize = 48
        var c = Clip(mediaRef: "", startFrame: 0, durationFrames: 60)
        c.mediaType = .text
        c.sourceClipType = .text
        c.textContent = content
        c.textStyle = style
        c.textAccent = accent
        c.textAnimation = animation
        c.transform = Transform(topLeft: (0.05, 0.35), width: 0.9, height: 0.3)
        return c
    }

    /// Pixels clearly greener than red — the accent colour, never the base colour.
    private func accentPixelCount(_ clip: Clip, frame: Int = 0) throws -> Int {
        let image = try #require(
            TextFrameRenderer.image(clip: clip, frame: frame, renderSize: Self.size)
        )
        let w = Int(Self.size.width), h = Int(Self.size.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(image.unpremultiplyingAlpha(), toBitmap: &px, rowBytes: w * 4,
                   bounds: CGRect(origin: .zero, size: Self.size), format: .RGBA8, colorSpace: nil)
        var count = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
            if Int(px[i + 1]) > Int(px[i]) + 60 { count += 1 }
        }
        return count
    }

    private static let green = TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1)

    @Test func anAccentedWordRendersInTheAccentColour() throws {
        let plain = try accentPixelCount(clip(content: "alpha beta", accent: nil))
        let accented = try accentPixelCount(
            clip(content: "alpha beta", accent: TextAccent(color: Self.green, words: [1]))
        )
        #expect(plain == 0, "no accent should leave the text in its base colour, got \(plain) green pixels")
        #expect(accented > 50, "the accented word should render green, got \(accented) pixels")
    }

    @Test func theAccentAlsoReachesThePerWordAnimationPath() throws {
        let animation = TextAnimation(preset: .wordReveal, perWordFrames: 1)
        let accented = try accentPixelCount(
            clip(content: "alpha beta", accent: TextAccent(color: Self.green, words: [1]), animation: animation),
            frame: 55
        )
        #expect(accented > 50, "word reveal should keep the accent colour, got \(accented) pixels")
    }

    @Test func anIndexPastTheLastWordIsIgnoredRatherThanCrashing() throws {
        let count = try accentPixelCount(
            clip(content: "alpha beta", accent: TextAccent(color: Self.green, words: [7]))
        )
        #expect(count == 0, "out-of-range accent index must not colour anything, got \(count)")
    }

    @Test func negativeIndicesAreDroppedAndTheRestKeptSorted() {
        let accent = TextAccent(color: Self.green, words: [3, -1, 0])
        #expect(accent.words == [0, 3])
    }

    @Test(arguments: [
        ("Take the biggest risks", "BIGGEST", 2),
        ("Take the biggest risks", "risks.", 3),
    ])
    func matchingIgnoresCaseAndPunctuation(content: String, requested: String, expected: Int) {
        let tokens = TextAccent.tokens(in: content).map { TextAccent.matchKey($0.text) }
        #expect(tokens.firstIndex(of: TextAccent.matchKey(requested)) == expected)
    }
}
