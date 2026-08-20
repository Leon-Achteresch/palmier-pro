import CoreImage

enum TransitionCompositor {

    static func blend(
        from: CIImage?,
        to: CIImage?,
        style: TransitionStyle,
        direction: TransitionDirection?,
        progress: Double,
        renderRect: CGRect
    ) -> CIImage? {
        guard from != nil || to != nil else { return nil }
        let t = min(1, max(0, progress))
        let a = from ?? clear(renderRect)
        let b = to ?? clear(renderRect)
        switch style {
        case .crossDissolve:
            return dissolve(a, b, t: t, renderRect: renderRect)
        case .dipToBlack:
            return dip(a, b, t: t, color: .black, renderRect: renderRect)
        case .dipToWhite:
            return dip(a, b, t: t, color: .white, renderRect: renderRect)
        case .wipe:
            return wipe(a, b, t: t, direction: direction, renderRect: renderRect)
        case .slide:
            return slide(a, b, t: t, direction: direction, renderRect: renderRect)
        case .push:
            return push(a, b, t: t, direction: direction, renderRect: renderRect)
        }
    }

    private static func clear(_ rect: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: rect)
    }

    private static func dissolve(_ a: CIImage, _ b: CIImage, t: Double, renderRect: CGRect) -> CIImage {
        if t <= 0 { return a.cropped(to: renderRect) }
        if t >= 1 { return b.cropped(to: renderRect) }
        let filter = CIFilter(name: "CIDissolveTransition")
        filter?.setValue(a, forKey: kCIInputImageKey)
        filter?.setValue(b, forKey: "inputTargetImage")
        filter?.setValue(t, forKey: "inputTime")
        return (filter?.outputImage ?? b).cropped(to: renderRect)
    }

    private static func dipRegion(_ a: CIImage, _ b: CIImage, renderRect: CGRect) -> CGRect {
        let union = a.extent.union(b.extent)
        guard !union.isInfinite, !union.isNull, !union.isEmpty else { return renderRect }
        let clipped = union.intersection(renderRect)
        return clipped.isNull || clipped.isEmpty ? renderRect : clipped
    }

    private static func dip(_ a: CIImage, _ b: CIImage, t: Double, color: CIColor, renderRect: CGRect) -> CIImage {
        let field = CIImage(color: color).cropped(to: dipRegion(a, b, renderRect: renderRect))
        if t < 0.5 {
            return dissolve(a, field, t: t * 2, renderRect: renderRect)
        }
        return dissolve(field, b, t: (t - 0.5) * 2, renderRect: renderRect)
    }

    static func wipeRect(direction: TransitionDirection, t: Double, renderRect r: CGRect) -> CGRect {
        let w = r.width * t
        let h = r.height * t
        switch direction {
        case .right: return CGRect(x: r.minX, y: r.minY, width: w, height: r.height)
        case .left:  return CGRect(x: r.maxX - w, y: r.minY, width: w, height: r.height)
        case .up:    return CGRect(x: r.minX, y: r.minY, width: r.width, height: h)
        case .down:  return CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
        }
    }

    static func incomingOffset(direction: TransitionDirection, t: Double, renderRect r: CGRect) -> CGPoint {
        let remaining = 1 - t
        switch direction {
        case .right: return CGPoint(x: -r.width * remaining, y: 0)
        case .left:  return CGPoint(x: r.width * remaining, y: 0)
        case .up:    return CGPoint(x: 0, y: -r.height * remaining)
        case .down:  return CGPoint(x: 0, y: r.height * remaining)
        }
    }

    static func outgoingOffset(direction: TransitionDirection, t: Double, renderRect r: CGRect) -> CGPoint {
        switch direction {
        case .right: return CGPoint(x: r.width * t, y: 0)
        case .left:  return CGPoint(x: -r.width * t, y: 0)
        case .up:    return CGPoint(x: 0, y: r.height * t)
        case .down:  return CGPoint(x: 0, y: -r.height * t)
        }
    }

    private static func wipe(_ a: CIImage, _ b: CIImage, t: Double, direction: TransitionDirection?, renderRect: CGRect) -> CIImage {
        guard let direction else { return dissolve(a, b, t: t, renderRect: renderRect) }
        let revealed = wipeRect(direction: direction, t: t, renderRect: renderRect)
        guard revealed.width > 0, revealed.height > 0 else { return a.cropped(to: renderRect) }
        return b.cropped(to: revealed).composited(over: a).cropped(to: renderRect)
    }

    private static func slide(_ a: CIImage, _ b: CIImage, t: Double, direction: TransitionDirection?, renderRect: CGRect) -> CIImage {
        guard let direction else { return dissolve(a, b, t: t, renderRect: renderRect) }
        let offset = incomingOffset(direction: direction, t: t, renderRect: renderRect)
        return translated(b, by: offset).composited(over: a).cropped(to: renderRect)
    }

    private static func push(_ a: CIImage, _ b: CIImage, t: Double, direction: TransitionDirection?, renderRect: CGRect) -> CIImage {
        guard let direction else { return dissolve(a, b, t: t, renderRect: renderRect) }
        let incoming = translated(b, by: incomingOffset(direction: direction, t: t, renderRect: renderRect))
        let outgoing = translated(a, by: outgoingOffset(direction: direction, t: t, renderRect: renderRect))
        return incoming.composited(over: outgoing).cropped(to: renderRect)
    }

    private static func translated(_ image: CIImage, by offset: CGPoint) -> CIImage {
        guard offset != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
    }
}
