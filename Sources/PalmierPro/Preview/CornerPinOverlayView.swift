import SwiftUI

/// Drag the four pin corners straight on the canvas. While the pin is animated every
/// drag writes a keyframe at the playhead, so scrubbing and re-dragging tracks a
/// moving surface frame by frame.
struct CornerPinOverlayView: View {
    @Environment(EditorViewModel.self) var editor

    private let handleSize: CGFloat = AppTheme.Spacing.md
    private let lineColor = AppTheme.Accent.timecodeColor

    @State private var dragStart: CornerPin.Quad?

    var body: some View {
        GeometryReader { geo in
            let videoRect = PreviewHitTester.videoContentRect(in: geo.size, timeline: editor.timeline)

            if let clip = editor.cornerPinnedClip,
               let quad = clip.cornerPinQuad(at: editor.activeFrame) {
                let points = quad.points(in: videoRect)

                Path { path in
                    path.addLines(points)
                    path.closeSubpath()
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: [4, 3]))
                .allowsHitTesting(false)

                if editor.canEditCornerPin {
                    ForEach(Array(CornerPin.Corner.allCases.enumerated()), id: \.element) { index, corner in
                        Circle()
                            .fill(lineColor)
                            .overlay(Circle().stroke(.white, lineWidth: AppTheme.BorderWidth.thin))
                            .frame(width: handleSize, height: handleSize)
                            .position(points[index])
                            .gesture(dragGesture(clip: clip, corner: corner, videoRect: videoRect))
                    }
                }
            }
        }
        .allowsHitTesting(editor.canEditCornerPin)
    }

    private func dragGesture(clip: Clip, corner: CornerPin.Corner, videoRect: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = clip.cornerPinQuad(at: editor.activeFrame) }
                guard let start = dragStart else { return }
                editor.applyCornerPin(
                    clipId: clip.id,
                    quad: moved(start, corner: corner, by: value.translation, videoRect: videoRect)
                )
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                let quad = moved(start, corner: corner, by: value.translation, videoRect: videoRect)
                dragStart = nil
                editor.commitCornerPin(clipId: clip.id, quad: quad)
            }
    }

    private func moved(
        _ quad: CornerPin.Quad,
        corner: CornerPin.Corner,
        by translation: CGSize,
        videoRect: CGRect
    ) -> CornerPin.Quad {
        guard videoRect.width > 0, videoRect.height > 0 else { return quad }
        var moved = quad
        moved[corner] = CGPoint(
            x: clamped(quad[corner].x + translation.width / videoRect.width),
            y: clamped(quad[corner].y + translation.height / videoRect.height)
        )
        return moved
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(CGFloat(CornerPin.range.upperBound), max(CGFloat(CornerPin.range.lowerBound), value))
    }
}
