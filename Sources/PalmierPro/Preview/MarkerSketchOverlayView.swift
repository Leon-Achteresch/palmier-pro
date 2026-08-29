import AppKit
import SwiftUI

struct MarkerSketchOverlayView: View {
    @Environment(EditorViewModel.self) private var editor

    @State private var livePoints: [MarkerStroke.Point] = []
    @State private var pushedCursor = false

    private var sketchingMarkerId: String? { editor.sketchingMarkerId }

    var body: some View {
        GeometryReader { geo in
            let markers = editor.sketchedTimelineMarkers(at: editor.activeFrame)
            ZStack {
                Canvas { context, size in
                    for marker in markers {
                        let shading = GraphicsContext.Shading.color(marker.color.swiftUIColor)
                        for stroke in marker.sketch {
                            context.stroke(
                                Path(stroke.cgPath(in: size)),
                                with: shading,
                                style: StrokeStyle(lineWidth: lineWidth(in: size), lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                    if livePoints.count >= 2, let live = liveStroke {
                        context.stroke(
                            Path(live.cgPath(in: size)),
                            with: .color(liveColor(markers: markers)),
                            style: StrokeStyle(lineWidth: lineWidth(in: size), lineCap: .round, lineJoin: .round)
                        )
                    }
                }
                .allowsHitTesting(false)

                if sketchingMarkerId != nil {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            guard hovering != pushedCursor else { return }
                            pushedCursor = hovering
                            if hovering { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        }
                        .onDisappear {
                            if pushedCursor { NSCursor.pop(); pushedCursor = false }
                        }
                        .gesture(drawGesture(size: geo.size))
                }
            }
        }
        .allowsHitTesting(sketchingMarkerId != nil)
    }

    private var liveStroke: MarkerStroke? {
        guard livePoints.count >= 2 else { return nil }
        return MarkerStroke(points: livePoints, arrow: editor.sketchArrowTool)
    }

    private func liveColor(markers: [TimelineMarker]) -> Color {
        guard let id = sketchingMarkerId, let marker = editor.timelineMarker(id: id) else {
            return TimelineMarker.defaultColor.swiftUIColor
        }
        return marker.color.swiftUIColor
    }

    private func lineWidth(in size: CGSize) -> CGFloat {
        max(AppTheme.BorderWidth.medium, min(size.width, size.height) * 0.006)
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = normalized(value.location, in: size)
                guard let last = livePoints.last else { livePoints = [point]; return }
                guard livePoints.count < MarkerStroke.maximumPoints else { return }
                let step = editor.sketchArrowTool ? 0 : 0.004
                if abs(point.x - last.x) > step || abs(point.y - last.y) > step {
                    livePoints.append(point)
                }
            }
            .onEnded { _ in
                defer { livePoints = [] }
                guard let stroke = simplifiedStroke(), let id = sketchingMarkerId else { return }
                editor.changeMarkerSketch(markerId: id, actionName: "Sketch Note") { strokes in
                    guard strokes.count < MarkerStroke.maximumStrokes else { return }
                    strokes.append(stroke)
                }
            }
    }

    /// The arrow tool keeps only the drag's endpoints so the note reads as one clean direction.
    private func simplifiedStroke() -> MarkerStroke? {
        guard let first = livePoints.first, let last = livePoints.last,
              hypot(last.x - first.x, last.y - first.y) > 0.01 else { return nil }
        return editor.sketchArrowTool
            ? MarkerStroke(points: [first, last], arrow: true)
            : MarkerStroke(points: livePoints)
    }

    private func normalized(_ location: CGPoint, in size: CGSize) -> MarkerStroke.Point {
        MarkerStroke.Point(
            x: min(max(0, location.x / max(size.width, 1)), 1),
            y: min(max(0, location.y / max(size.height, 1)), 1)
        )
    }
}

struct MarkerSketchToolbar: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if let id = editor.sketchingMarkerId, let marker = editor.timelineMarker(id: id) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill(marker.color.swiftUIColor)
                    .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                Text(verbatim: marker.name)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                tool(L10n.string("Arrow"), systemImage: "arrow.up.right", active: editor.sketchArrowTool) {
                    editor.sketchArrowTool = true
                }
                tool(L10n.string("Draw"), systemImage: "scribble", active: !editor.sketchArrowTool) {
                    editor.sketchArrowTool = false
                }
                Button(L10n.string("Undo Stroke")) {
                    editor.changeMarkerSketch(markerId: id, actionName: "Sketch Note") { $0 = $0.dropLast() }
                }
                .buttonStyle(.capsule(.secondary, size: .small))
                .disabled(marker.sketch.isEmpty)
                Button(L10n.string("Done")) { editor.sketchingMarkerId = nil }
                    .buttonStyle(.capsule(.prominent, size: .small))
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(AppTheme.Background.raisedColor, in: Capsule())
            .shadow(AppTheme.Shadow.md)
            .padding(.top, AppTheme.Spacing.md)
        }
    }

    private func tool(
        _ label: String, systemImage: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.sm))
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.surfaceColor.opacity(active ? AppTheme.Opacity.strong : 0))
        )
        .help(label)
    }
}
