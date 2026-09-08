import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("Backdrop effect")
struct BackdropEffectTests {

    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let extent = CGRect(x: 0, y: 0, width: 64, height: 64)

    private func render(_ image: CIImage, at point: CGPoint) -> [Double] {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 16,
                   bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                   format: .RGBAf, colorSpace: nil)
        return px.map(Double.init)
    }

    private func apply(padding: Double, background: Double = 11, shadow: Double = 0) -> CIImage {
        let source = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let params = ResolvedEffectParams(
            values: ["padding": padding, "cornerRadius": 0, "shadow": shadow, "background": background],
            strings: [:]
        )
        return BackdropEffect.apply(source, params: params, extent: extent)
    }

    @Test func paddedContentSitsOnGradientAndKeepsExtent() {
        let out = apply(padding: 20)
        #expect(out.extent == extent)
        let center = render(out, at: CGPoint(x: 32, y: 32))
        #expect(center[1] > 0.9, "center still shows the clip")
        let corner = render(out, at: CGPoint(x: 1, y: 62))
        #expect(corner[1] < 0.5, "corner shows the backdrop, not the clip")
        #expect(corner[3] > 0.99, "backdrop is opaque")
    }

    @Test func zeroPaddingCoversTheBackdrop() {
        let center = render(apply(padding: 0), at: CGPoint(x: 32, y: 32))
        let edge = render(apply(padding: 0), at: CGPoint(x: 1, y: 1))
        #expect(center[1] > 0.9)
        #expect(edge[1] > 0.9)
    }

    @Test func backgroundIndexIsClampedToCatalog() {
        let out = apply(padding: 20, background: 999)
        #expect(out.extent == extent)
    }

    @Test func registryExposesBackdrop() {
        let descriptor = EffectRegistry.descriptor(id: "stylize.backdrop")
        #expect(descriptor != nil)
        #expect(descriptor?.params.map(\.key).sorted() == ["background", "cornerRadius", "padding", "shadow"])
        #expect(EffectRegistry.canonicalOrder.contains("stylize.backdrop"))
    }
}
