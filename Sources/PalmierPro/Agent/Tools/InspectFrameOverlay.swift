import CoreGraphics
import CoreText
import Foundation

enum InspectFrameOverlay: Sendable {
    static let metadataNote = "0-1, origin top-left"

    nonisolated static func apply(
        _ image: CGImage, caption: String? = nil, sketches: [TimelineMarker] = []
    ) -> CGImage {
        overlay(on: image, caption: caption, sketches: sketches) ?? image
    }

    nonisolated static func encode(_ image: CGImage, caption: String? = nil) -> (data: Data, mime: String)? {
        let overlaid = apply(image, caption: caption)
        guard let output = ImageEncoder.encodeWithinBudget(overlaid, preferPNG: hasAlpha(image)) else { return nil }
        return (output.data, output.mime)
    }

    nonisolated static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private nonisolated static func overlay(
        on image: CGImage, caption: String?, sketches: [TimelineMarker]
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        drawGrid(in: ctx, width: w, height: h)
        for marker in sketches { drawSketch(marker, in: ctx, width: w, height: h) }
        if let caption { drawCaption(caption, in: ctx, imageHeight: h) }
        return ctx.makeImage()
    }

    /// Sketch coordinates are top-left normalized, so the path is drawn through a flip.
    private nonisolated static func drawSketch(
        _ marker: TimelineMarker, in ctx: CGContext, width w: CGFloat, height h: CGFloat
    ) {
        guard !marker.sketch.isEmpty else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let size = CGSize(width: w, height: h)
        for stroke in marker.sketch {
            let path = stroke.cgPath(in: size)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
            ctx.setLineWidth(max(3, min(w, h) * 0.009))
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setStrokeColor(marker.color.cgColor)
            ctx.setLineWidth(max(2, min(w, h) * 0.006))
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
        guard let anchor = marker.sketch.first?.points.first else { return }
        drawLabel(marker.name, in: ctx, x: anchor.x * w, y: (1 - anchor.y) * h)
    }

    private nonisolated static func drawLabel(
        _ text: String, in ctx: CGContext, x: CGFloat, y: CGFloat
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica-Bold" as CFString, 11, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        fillChip(in: ctx, x: x, y: y + 4, width: textWidth + 6, height: 15)
        ctx.textPosition = CGPoint(x: x + 3, y: y + 8)
        CTLineDraw(line, ctx)
    }

    private nonisolated static func drawGrid(in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        let ticks = (0...20).map { Double($0) / 20 }
        func stroke(_ width: CGFloat, gray: CGFloat, alpha: CGFloat, major: Bool) {
            ctx.setLineWidth(width)
            ctx.setStrokeColor(CGColor(gray: gray, alpha: alpha))
            for (i, t) in ticks.enumerated() {
                if (i.isMultiple(of: 10)) != major { continue }
                let x = min(max(0.5, t * w), w - 0.5)
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: h))
                let y = min(max(0.5, (1 - t) * h), h - 0.5)
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: w, y: y))
            }
            ctx.strokePath()
        }
        stroke(2, gray: 0, alpha: 0.55, major: false)
        stroke(1, gray: 1, alpha: 0.75, major: false)
        stroke(2.5, gray: 0, alpha: 0.65, major: true)
        stroke(1.5, gray: 1, alpha: 0.95, major: true)
        drawTickLabels((0...10).map { Double($0) / 10 }, in: ctx, width: w, height: h)
    }

    private nonisolated static func drawTickLabels(
        _ ticks: [Double], in ctx: CGContext, width w: CGFloat, height h: CGFloat
    ) {
        let fontSize: CGFloat = min(11, max(8, min(w, h) / 42))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        for t in ticks {
            let label = t == 0 || t == 1 ? String(Int(t)) : String(format: "%.1f", t)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
            let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = t * w
            let y = (1 - t) * h
            if t != 1 {
                fillChip(in: ctx, x: min(max(0, x - textW / 2), w - textW - 2), y: 2, width: textW + 4, height: fontSize + 3)
                ctx.textPosition = CGPoint(x: min(max(2, x - textW / 2), w - textW - 2) + 2, y: 4)
                CTLineDraw(line, ctx)
            }
            fillChip(in: ctx, x: w - textW - 6, y: min(max(2, y - fontSize / 2), h - fontSize - 4), width: textW + 4, height: fontSize + 3)
            ctx.textPosition = CGPoint(x: w - textW - 4, y: min(max(4, y - fontSize / 2 + 2), h - fontSize - 2))
            CTLineDraw(line, ctx)
        }
    }

    private nonisolated static func drawCaption(_ text: String, in ctx: CGContext, imageHeight: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let chipHeight: CGFloat = 16
        fillChip(in: ctx, x: 0, y: imageHeight - chipHeight, width: textWidth + 10, height: chipHeight)
        ctx.textPosition = CGPoint(x: 5, y: imageHeight - chipHeight + 4)
        CTLineDraw(line, ctx)
    }

    private nonisolated static func fillChip(
        in ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    ) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
        ctx.fill(CGRect(x: x, y: y, width: width, height: height))
    }
}
