import CoreImage

/// Tilts the image plane in 3D around its center and reprojects it with a
/// pinhole camera, so a flat layer can read as lying on the ground or a wall.
enum PerspectiveProjection {

    static func apply(
        _ image: CIImage,
        extent: CGRect,
        tiltX: Double,
        tiltY: Double,
        distance: Double
    ) -> CIImage {
        guard abs(tiltX) > 0.01 || abs(tiltY) > 0.01 else { return image }
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite, !extent.isNull else { return image }

        let ax = tiltX * .pi / 180
        let ay = tiltY * .pi / 180
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let d = max(0.5, distance) * Double(max(extent.width, extent.height))

        func project(_ corner: CGPoint) -> CGPoint {
            let x0 = Double(corner.x - center.x)
            let y0 = Double(corner.y - center.y)
            let y1 = y0 * cos(ax)
            let z1 = -y0 * sin(ax)
            let x2 = x0 * cos(ay) + z1 * sin(ay)
            let z2 = -x0 * sin(ay) + z1 * cos(ay)
            let s = d / max(d - z2, d * 0.01)
            return CGPoint(x: center.x + x2 * s, y: center.y + y1 * s)
        }

        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: project(CGPoint(x: extent.minX, y: extent.maxY))),
            "inputTopRight": CIVector(cgPoint: project(CGPoint(x: extent.maxX, y: extent.maxY))),
            "inputBottomLeft": CIVector(cgPoint: project(CGPoint(x: extent.minX, y: extent.minY))),
            "inputBottomRight": CIVector(cgPoint: project(CGPoint(x: extent.maxX, y: extent.minY))),
        ])
    }
}
