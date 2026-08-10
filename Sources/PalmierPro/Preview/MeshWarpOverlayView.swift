import SwiftUI

/// Drag the nine mesh points straight on the canvas: corners place, edge midpoints and
/// the center bend. While the warp is animated every drag writes a keyframe at the playhead.
struct MeshWarpOverlayView: View {
    @Environment(EditorViewModel.self) var editor

    private let handleSize: CGFloat = AppTheme.Spacing.md
    private let lineColor = AppTheme.Accent.timecodeColor
    private let curveSamples = 16

    @State private var dragStart: MeshWarp.Grid?

    var body: some View {
        GeometryReader { geo in
            let videoRect = PreviewHitTester.videoContentRect(in: geo.size, timeline: editor.timeline)

            if let clip = editor.meshWarpedClip,
               let grid = clip.meshWarpGrid(at: editor.activeFrame) {

                gridPath(grid, in: videoRect)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: [4, 3]))
                    .allowsHitTesting(false)

                if editor.canEditMeshWarp {
                    ForEach(MeshWarp.Point.allCases, id: \.self) { point in
                        Circle()
                            .fill(lineColor)
                            .overlay(Circle().stroke(.white, lineWidth: AppTheme.BorderWidth.thin))
                            .frame(width: handleSize, height: handleSize)
                            .position(mapped(grid[point], in: videoRect))
                            .gesture(dragGesture(clip: clip, point: point, videoRect: videoRect))
                    }
                }
            }
        }
        .allowsHitTesting(editor.canEditMeshWarp)
    }

    private func gridPath(_ grid: MeshWarp.Grid, in videoRect: CGRect) -> Path {
        Path { path in
            for line in [CGFloat(0), 0.5, 1] {
                addCurve(to: &path, grid: grid, in: videoRect) { grid.surfacePoint(u: $0, v: line) }
                addCurve(to: &path, grid: grid, in: videoRect) { grid.surfacePoint(u: line, v: $0) }
            }
        }
    }

    private func addCurve(
        to path: inout Path,
        grid: MeshWarp.Grid,
        in videoRect: CGRect,
        point: (CGFloat) -> CGPoint
    ) {
        let samples = (0...curveSamples).map {
            mapped(point(CGFloat($0) / CGFloat(curveSamples)), in: videoRect)
        }
        path.move(to: samples[0])
        for sample in samples.dropFirst() { path.addLine(to: sample) }
    }

    private func mapped(_ p: CGPoint, in videoRect: CGRect) -> CGPoint {
        CGPoint(x: videoRect.minX + p.x * videoRect.width, y: videoRect.minY + p.y * videoRect.height)
    }

    private func dragGesture(clip: Clip, point: MeshWarp.Point, videoRect: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = clip.meshWarpGrid(at: editor.activeFrame) }
                guard let start = dragStart else { return }
                editor.applyMeshWarp(
                    clipId: clip.id,
                    grid: moved(start, point: point, by: value.translation, videoRect: videoRect)
                )
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                let grid = moved(start, point: point, by: value.translation, videoRect: videoRect)
                dragStart = nil
                editor.commitMeshWarp(clipId: clip.id, grid: grid)
            }
    }

    private func moved(
        _ grid: MeshWarp.Grid,
        point: MeshWarp.Point,
        by translation: CGSize,
        videoRect: CGRect
    ) -> MeshWarp.Grid {
        guard videoRect.width > 0, videoRect.height > 0 else { return grid }
        var moved = grid
        moved[point] = CGPoint(
            x: clamped(grid[point].x + translation.width / videoRect.width),
            y: clamped(grid[point].y + translation.height / videoRect.height)
        )
        return moved
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(CGFloat(MeshWarp.range.upperBound), max(CGFloat(MeshWarp.range.lowerBound), value))
    }
}
