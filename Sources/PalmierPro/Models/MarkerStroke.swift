import CoreGraphics
import Foundation

struct MarkerStroke: Codable, Sendable, Equatable, Hashable {
    struct Point: Codable, Sendable, Equatable, Hashable {
        var x: Double
        var y: Double
    }

    static let maximumStrokes = 64
    static let maximumPoints = 512

    var points: [Point]
    var arrow: Bool = false

    var isValid: Bool {
        points.count >= 2 && points.count <= Self.maximumPoints
            && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    /// Top-left origin path in `size`, arrowhead included.
    func cgPath(in size: CGSize) -> CGPath {
        let scaled = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let path = CGMutablePath()
        guard let first = scaled.first else { return path }
        path.move(to: first)
        for point in scaled.dropFirst() { path.addLine(to: point) }
        guard arrow, let tip = scaled.last else { return path }
        let tail = scaled.reversed().first { hypot(tip.x - $0.x, tip.y - $0.y) > 1 } ?? first
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length = max(8, min(size.width, size.height) * 0.03)
        for spread in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            path.move(to: tip)
            path.addLine(to: CGPoint(
                x: tip.x + cos(angle + spread) * length,
                y: tip.y + sin(angle + spread) * length
            ))
        }
        return path
    }
}
