import CoreGraphics

/// Bendable placement warp: the clip's frame is mapped onto a 3×3 grid of canvas points
/// through a biquadratic surface, so moving the edge midpoints or the center bends and
/// distorts the layer instead of keeping it a flat perspective plane. Points are
/// normalized canvas coordinates with a top-left origin, the same space as Corner Pin.
enum MeshWarp {
    static let effectType = "distort.meshWarp"
    static let range = CornerPin.range

    enum Point: String, CaseIterable, Sendable {
        case topLeft, topCenter, topRight
        case midLeft, center, midRight
        case bottomLeft, bottomCenter, bottomRight

        var xKey: String { "\(rawValue)X" }
        var yKey: String { "\(rawValue)Y" }

        var index: Int { Self.allCases.firstIndex(of: self)! }

        var displayName: String {
            switch self {
            case .topLeft:      "Top Left"
            case .topCenter:    "Top Center"
            case .topRight:     "Top Right"
            case .midLeft:      "Middle Left"
            case .center:       "Center"
            case .midRight:     "Middle Right"
            case .bottomLeft:   "Bottom Left"
            case .bottomCenter: "Bottom Center"
            case .bottomRight:  "Bottom Right"
            }
        }

        var defaultPoint: CGPoint {
            CGPoint(x: CGFloat(index % 3) / 2, y: CGFloat(index / 3) / 2)
        }
    }

    struct Grid: Equatable, Sendable {
        var points: [CGPoint]

        static let canvas = Grid(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

        init(points: [CGPoint]) {
            self.points = points
        }

        init(rect: CGRect) {
            points = Point.allCases.map {
                CGPoint(
                    x: rect.minX + $0.defaultPoint.x * rect.width,
                    y: rect.minY + $0.defaultPoint.y * rect.height
                )
            }
        }

        subscript(point: Point) -> CGPoint {
            get { points[point.index] }
            set { points[point.index] = newValue }
        }

        /// Quadratic Lagrange weights for nodes 0, ½, 1 — the surface passes through all nine points.
        static func basis(_ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            (2 * t * t - 3 * t + 1, 4 * t - 4 * t * t, 2 * t * t - t)
        }

        /// The warped position of normalized source point (u, v); identity on the default grid.
        func surfacePoint(u: CGFloat, v: CGFloat) -> CGPoint {
            let bu = Self.basis(u), bv = Self.basis(v)
            let wu = [bu.0, bu.1, bu.2], wv = [bv.0, bv.1, bv.2]
            var x: CGFloat = 0, y: CGFloat = 0
            for r in 0..<3 {
                for c in 0..<3 {
                    let w = wv[r] * wu[c]
                    let p = points[r * 3 + c]
                    x += w * p.x
                    y += w * p.y
                }
            }
            return CGPoint(x: x, y: y)
        }

        /// The warped outline sampled clockwise from the top left.
        func boundary(samplesPerEdge n: Int = 8) -> [CGPoint] {
            var outline: [CGPoint] = []
            for i in 0..<n { outline.append(surfacePoint(u: CGFloat(i) / CGFloat(n), v: 0)) }
            for i in 0..<n { outline.append(surfacePoint(u: 1, v: CGFloat(i) / CGFloat(n))) }
            for i in 0..<n { outline.append(surfacePoint(u: 1 - CGFloat(i) / CGFloat(n), v: 1)) }
            for i in 0..<n { outline.append(surfacePoint(u: 0, v: 1 - CGFloat(i) / CGFloat(n))) }
            return outline
        }

        func isRenderable(in size: CGSize) -> Bool {
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            let outline = boundary().map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            return abs(PolygonMath.area(outline)) >= 1
        }

        func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
            let outline = boundary().map {
                CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
            }
            return PolygonMath.contains(point, in: outline)
        }
    }
}

extension Clip {
    var meshWarpEffect: Effect? { effects?.first { $0.type == MeshWarp.effectType } }

    var isMeshWarpAnimated: Bool {
        meshWarpEffect?.params.values.contains { $0.track?.isActive == true } ?? false
    }

    /// The warp grid at a timeline frame, or nil when the clip isn't mesh warped.
    func meshWarpGrid(at frame: Int) -> MeshWarp.Grid? {
        guard let effect = meshWarpEffect, effect.enabled else { return nil }
        let offset = frame - startFrame
        var grid = MeshWarp.Grid.canvas
        for point in MeshWarp.Point.allCases {
            let fallback = point.defaultPoint
            grid[point] = CGPoint(
                x: effect.params[point.xKey]?.resolved(at: offset, default: fallback.x) ?? fallback.x,
                y: effect.params[point.yKey]?.resolved(at: offset, default: fallback.y) ?? fallback.y
            )
        }
        return grid
    }
}
