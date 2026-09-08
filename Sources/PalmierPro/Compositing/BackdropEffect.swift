import CoreGraphics
import CoreImage
import Foundation

enum BackdropEffect {
    static let gradients: [(name: String, hexStops: [String])] = [
        ("aurora",   ["#2B0F54", "#7F00FF", "#E100FF", "#FF8C94", "#FFE0B2"]),
        ("midnight", ["#0D0B2E", "#1A1B63", "#2E5BFF", "#00D4FF", "#E0FFFF"]),
        ("sunset",   ["#ff7e5f", "#feb47b"]),
        ("candy",    ["#F093FB", "#F5576C", "#F6D365", "#FDA085"]),
        ("ocean",    ["#36D1DC", "#5B86E5"]),
        ("emerald",  ["#11998e", "#38ef7d"]),
        ("dusk",     ["#2b5876", "#4e4376"]),
        ("flame",    ["#f12711", "#f5af19"]),
        ("slate",    ["#0f172a", "#1e293b", "#334155", "#475569", "#64748b"]),
        ("lavender", ["#e0c3fc", "#8ec5fc"]),
        ("cream",    ["#f8fafc", "#e2e8f0", "#cbd5e1"]),
        ("noir",     ["#232526", "#414345"]),
    ]

    // NSCache is documented thread-safe; CIImage is immutable.
    nonisolated(unsafe) private static let backgroundCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 12
        return cache
    }()
    private static let tileSize = 256.0

    static func apply(_ image: CIImage, params p: ResolvedEffectParams, extent: CGRect) -> CIImage {
        guard extent.width > 0, extent.height > 0 else { return image }
        let padding = min(max(p.value("padding"), 0), 40) / 100
        let rounding = min(max(p.value("cornerRadius"), 0), 20) / 20
        let shadow = min(max(p.value("shadow"), 0), 1)
        let index = min(max(Int(p.value("background").rounded()), 0), gradients.count - 1)

        var content = image.cropped(to: extent)
        content = EdgeRoundingKernel.apply(content, edgeRounding: rounding, edgeSoftness: 0)
        let scale = max(1 - 2 * padding, 0.2)
        let fit = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -extent.midX, y: -extent.midY)
        content = content.transformed(by: fit)

        var out = background(index: index, extent: extent)
        if shadow > 0 {
            let drop = min(extent.width, extent.height)
            let silhouette = content.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55 * shadow),
            ])
            let blurred = silhouette
                .transformed(by: CGAffineTransform(translationX: 0, y: -drop * 0.02 * shadow))
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: drop * 0.025 * shadow])
            out = blurred.composited(over: out).cropped(to: extent)
        }
        return content.composited(over: out).cropped(to: extent)
    }

    private static func background(index: Int, extent: CGRect) -> CIImage {
        let key = "backdrop-\(index)" as NSString
        let tile: CIImage
        if let cached = backgroundCache.object(forKey: key) {
            tile = cached
        } else {
            tile = renderTile(index: index)
            backgroundCache.setObject(tile, forKey: key)
        }
        let fill = CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y)
            .scaledBy(x: extent.width / tileSize, y: extent.height / tileSize)
        return tile.transformed(by: fill).cropped(to: extent)
    }

    private static func renderTile(index: Int) -> CIImage {
        let size = Int(tileSize)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage(color: .black) }
        let colors = gradients[index].hexStops.map { cgColor(hex: $0, space: space) }
        let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) }
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: tileSize),
                end: CGPoint(x: tileSize, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        guard let cg = ctx.makeImage() else { return CIImage(color: .black) }
        return CIImage(cgImage: cg)
    }

    private static func cgColor(hex: String, space: CGColorSpace) -> CGColor {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CGColor(colorSpace: space, components: [r, g, b, 1]) ?? CGColor(gray: 0, alpha: 1)
    }
}
