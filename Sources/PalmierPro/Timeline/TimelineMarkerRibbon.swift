import AppKit

/// Marker tags drawn in the timeline ruler. Owns the tag geometry used by both drawing and hit testing.
enum TimelineMarkerRibbon {

    /// Tag rect for a marker frame, in the same coordinate space as `rulerRect`.
    static func tagRect(
        frame: Int,
        in rulerRect: NSRect,
        pixelsPerFrame: Double,
        scrollOffsetX: CGFloat
    ) -> NSRect {
        let centerX = rulerRect.minX + (Double(frame) * pixelsPerFrame - Double(scrollOffsetX))
        return NSRect(
            x: centerX - AppTheme.Marker.tagWidth / 2,
            y: rulerRect.maxY - AppTheme.Marker.tagHeight,
            width: AppTheme.Marker.tagWidth,
            height: AppTheme.Marker.tagHeight
        )
    }

    /// Index range of markers whose tags can touch `rulerRect`. Markers are frame-sorted, so this
    /// is a binary search — the draw path never scans or allocates per marker off screen.
    static func visibleRange(
        _ markers: [TimelineMarker],
        in rulerRect: NSRect,
        pixelsPerFrame: Double,
        scrollOffsetX: CGFloat
    ) -> Range<Int> {
        guard !markers.isEmpty, pixelsPerFrame > 0, pixelsPerFrame.isFinite else { return 0..<0 }
        let slack = Double(AppTheme.Marker.tagWidth / 2 + AppTheme.Marker.hitPadding)
        let firstX = Double(scrollOffsetX) - slack
        let lastX = Double(scrollOffsetX) + Double(rulerRect.width) + slack
        let lower = clampedFrame(firstX / pixelsPerFrame)
        let upper = clampedFrame(lastX / pixelsPerFrame)
        let start = markers.partitioningIndex { $0.frame >= lower }
        let end = markers.partitioningIndex { $0.frame > upper }
        return start..<end
    }

    @MainActor
    private static let tagColors: [MarkerColor: CGColor] = Dictionary(
        uniqueKeysWithValues: MarkerColor.allCases.map { ($0, AppTheme.Marker.nsColor($0).cgColor) }
    )

    @MainActor
    private static let doneTagColors: [MarkerColor: CGColor] = Dictionary(
        uniqueKeysWithValues: MarkerColor.allCases.map {
            ($0, AppTheme.Marker.nsColor($0).withAlphaComponent(AppTheme.Marker.doneOpacity).cgColor)
        }
    )

    @MainActor
    static func draw(
        markers: [TimelineMarker],
        in rulerRect: NSRect,
        pixelsPerFrame: Double,
        scrollOffsetX: CGFloat,
        selectedId: String?,
        context: CGContext
    ) {
        let range = visibleRange(
            markers, in: rulerRect, pixelsPerFrame: pixelsPerFrame, scrollOffsetX: scrollOffsetX
        )
        guard !range.isEmpty else { return }
        let selectedStroke = AppTheme.Text.primary.cgColor
        let stroke = AppTheme.Border.timelineClip.cgColor
        context.saveGState()
        context.setLineWidth(AppTheme.BorderWidth.thin)
        for i in range {
            let marker = markers[i]
            let rect = tagRect(
                frame: marker.frame, in: rulerRect,
                pixelsPerFrame: pixelsPerFrame, scrollOffsetX: scrollOffsetX
            )
            let path = CGMutablePath()
            appendTag(path, kind: marker.kind, in: rect)
            let palette = marker.kind == .todo && marker.done ? doneTagColors : tagColors
            if let fill = palette[marker.color] { context.setFillColor(fill) }
            context.setStrokeColor(marker.id == selectedId ? selectedStroke : stroke)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }
        context.restoreGState()
    }

    /// Marker id under `point`, topmost-last-drawn first. `point` and `rulerRect` share a space.
    static func hitTest(
        markers: [TimelineMarker],
        at point: NSPoint,
        in rulerRect: NSRect,
        pixelsPerFrame: Double,
        scrollOffsetX: CGFloat
    ) -> String? {
        let range = visibleRange(
            markers, in: rulerRect, pixelsPerFrame: pixelsPerFrame, scrollOffsetX: scrollOffsetX
        )
        for i in range.reversed() {
            let rect = tagRect(
                frame: markers[i].frame, in: rulerRect,
                pixelsPerFrame: pixelsPerFrame, scrollOffsetX: scrollOffsetX
            )
            if rect.insetBy(dx: -AppTheme.Marker.hitPadding, dy: -AppTheme.Marker.hitPadding).contains(point) {
                return markers[i].id
            }
        }
        return nil
    }

    /// Chapter markers read as a flag; everything else as a downward-pointing tag.
    private static func appendTag(_ path: CGMutablePath, kind: MarkerKind, in rect: NSRect) {
        guard kind != .chapter else {
            path.addRect(rect)
            return
        }
        let shoulderY = rect.maxY - AppTheme.Marker.tipHeight
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulderY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulderY))
        path.closeSubpath()
    }

    private static func clampedFrame(_ value: Double) -> Int {
        if value.isNaN || value <= 0 { return 0 }
        let ceiling = Double(Int.max / 2)
        return value >= ceiling ? Int.max / 2 : Int(value)
    }
}

private extension Array where Element == TimelineMarker {
    /// First index whose element satisfies `belongsInSecondPartition`, assuming frame order.
    func partitioningIndex(_ belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = low + (high - low) / 2
            if belongsInSecondPartition(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
