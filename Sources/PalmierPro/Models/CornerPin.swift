import CoreGraphics

/// After-Effects-style corner pin: the clip's frame is warped onto four canvas points
/// instead of being placed by its transform, so a layer can sit on a screen, sign, or
/// wall in the shot. Points are normalized canvas coordinates with a top-left origin,
/// the same space as `Transform.topLeft`.
enum CornerPin {
    static let effectType = "distort.cornerPin"
    static let range: ClosedRange<Double> = -2...3

    enum Corner: String, CaseIterable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft

        var xKey: String { "\(rawValue)X" }
        var yKey: String { "\(rawValue)Y" }

        var displayName: String {
            switch self {
            case .topLeft:     "Top Left"
            case .topRight:    "Top Right"
            case .bottomRight: "Bottom Right"
            case .bottomLeft:  "Bottom Left"
            }
        }

        var defaultPoint: CGPoint {
            switch self {
            case .topLeft:     CGPoint(x: 0, y: 0)
            case .topRight:    CGPoint(x: 1, y: 0)
            case .bottomRight: CGPoint(x: 1, y: 1)
            case .bottomLeft:  CGPoint(x: 0, y: 1)
            }
        }
    }

    struct Quad: Equatable, Sendable {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomRight: CGPoint
        var bottomLeft: CGPoint

        static let canvas = Quad(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

        init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
            self.topLeft = topLeft
            self.topRight = topRight
            self.bottomRight = bottomRight
            self.bottomLeft = bottomLeft
        }

        init(rect: CGRect) {
            self.init(
                topLeft: CGPoint(x: rect.minX, y: rect.minY),
                topRight: CGPoint(x: rect.maxX, y: rect.minY),
                bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
                bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            )
        }

        subscript(corner: Corner) -> CGPoint {
            get {
                switch corner {
                case .topLeft:     topLeft
                case .topRight:    topRight
                case .bottomRight: bottomRight
                case .bottomLeft:  bottomLeft
                }
            }
            set {
                switch corner {
                case .topLeft:     topLeft = newValue
                case .topRight:    topRight = newValue
                case .bottomRight: bottomRight = newValue
                case .bottomLeft:  bottomLeft = newValue
                }
            }
        }

        /// Clockwise from the top left, the order CIPerspectiveTransform and hit testing walk.
        var clockwise: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

        /// Normalized points mapped into a view- or canvas-space rect.
        func points(in rect: CGRect) -> [CGPoint] {
            clockwise.map {
                CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
            }
        }

        /// Shoelace area in `size` pixels. Zero for a collapsed quad, negative when mirrored.
        func area(in size: CGSize) -> Double {
            let p = points(in: CGRect(origin: .zero, size: size))
            var sum = 0.0
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                sum += Double(a.x * b.y - b.x * a.y)
            }
            return sum / 2
        }

        /// False when the quad collapsed to a line/point or carries non-finite values —
        /// warping onto it produces nothing renderable.
        func isRenderable(in size: CGSize) -> Bool {
            guard clockwise.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            return abs(area(in: size)) >= 1
        }

        /// Crossing-number test in the same view space `points(in:)` maps to.
        func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
            let p = points(in: rect)
            var inside = false
            var j = p.count - 1
            for i in p.indices {
                if (p[i].y > point.y) != (p[j].y > point.y) {
                    let t = (point.y - p[i].y) / (p[j].y - p[i].y)
                    if point.x < p[i].x + t * (p[j].x - p[i].x) { inside.toggle() }
                }
                j = i
            }
            return inside
        }
    }
}

extension Clip {
    var cornerPinEffect: Effect? { effects?.first { $0.type == CornerPin.effectType } }

    var isCornerPinAnimated: Bool {
        cornerPinEffect?.params.values.contains { $0.track?.isActive == true } ?? false
    }

    /// The pin quad at a timeline frame, or nil when the clip isn't pinned.
    func cornerPinQuad(at frame: Int) -> CornerPin.Quad? {
        guard let effect = cornerPinEffect, effect.enabled else { return nil }
        let offset = frame - startFrame
        var quad = CornerPin.Quad.canvas
        for corner in CornerPin.Corner.allCases {
            let fallback = corner.defaultPoint
            quad[corner] = CGPoint(
                x: effect.params[corner.xKey]?.resolved(at: offset, default: fallback.x) ?? fallback.x,
                y: effect.params[corner.yKey]?.resolved(at: offset, default: fallback.y) ?? fallback.y
            )
        }
        return quad
    }
}
