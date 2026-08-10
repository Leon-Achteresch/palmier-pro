import CoreImage
import Foundation

enum MeshWarpKernel {
    private static let kernel = CIKernelLoader.kernel("MeshWarp", "meshWarp")

    /// Warps the layer onto its grid in canvas space, replacing the affine placement.
    /// Nil when the grid collapsed — nothing visible to composite.
    static func place(_ image: CIImage, grid: MeshWarp.Grid, renderSize: CGSize) -> CIImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite, !extent.isNull,
              grid.isRenderable(in: renderSize), let kernel else { return nil }

        func pixelPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * renderSize.width, y: (1 - p.y) * renderSize.height)
        }

        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        let steps = 12
        for r in 0...steps {
            for c in 0...steps {
                let p = pixelPoint(grid.surfacePoint(u: CGFloat(c) / CGFloat(steps), v: CGFloat(r) / CGFloat(steps)))
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        let dest = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -2, dy: -2).integral
        guard dest.width >= 1, dest.height >= 1 else { return nil }

        let rect = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
        var arguments: [Any] = [image, rect]
        arguments += MeshWarp.Point.allCases.map { point in
            let p = pixelPoint(grid[point])
            return CIVector(x: p.x, y: p.y)
        }
        return kernel.apply(extent: dest, roiCallback: { _, _ in extent }, arguments: arguments)
    }
}
