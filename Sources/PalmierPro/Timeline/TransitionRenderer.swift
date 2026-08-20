import AppKit

enum TransitionRenderer {

    static func rect(for resolved: ResolvedTransition, trackIndex: Int, geometry geo: TimelineGeometry) -> NSRect {
        let probe = Clip(
            mediaRef: "",
            startFrame: resolved.window.startFrame,
            durationFrames: resolved.window.durationFrames
        )
        return geo.clipRect(for: probe, trackIndex: trackIndex)
    }

    static func draw(_ resolved: ResolvedTransition, in rect: NSRect, isSelected: Bool, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let body = rect.insetBy(dx: 0, dy: AppTheme.BorderWidth.thin)
        let path = CGPath(
            roundedRect: body,
            cornerWidth: AppTheme.Radius.xs,
            cornerHeight: AppTheme.Radius.xs,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(
            AppTheme.TrackColor.transition
                .withAlphaComponent(isSelected ? AppTheme.Opacity.high : AppTheme.Opacity.medium)
                .cgColor
        )
        context.fillPath()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setStrokeColor(
            AppTheme.Text.primary.withAlphaComponent(AppTheme.Opacity.moderate).cgColor
        )
        context.setLineWidth(AppTheme.BorderWidth.thin)
        context.move(to: CGPoint(x: body.minX, y: body.minY))
        context.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
        context.move(to: CGPoint(x: body.minX, y: body.maxY))
        context.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        context.strokePath()
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(
            isSelected
                ? AppTheme.Text.primary.cgColor
                : AppTheme.Border.primary.cgColor
        )
        context.setLineWidth(isSelected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin)
        context.strokePath()

        drawLabel(resolved, in: body, context: context)
    }

    private static func drawLabel(_ resolved: ResolvedTransition, in body: NSRect, context: CGContext) {
        guard body.width >= AppTheme.ComponentSize.timelineClipLabelMinWidth else { return }
        let string = NSAttributedString(string: label(for: resolved.transition), attributes: [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.micro, weight: .semibold),
            .foregroundColor: AppTheme.Text.primary,
        ])
        let size = string.size()
        guard size.width <= body.width - AppTheme.Spacing.xs else { return }
        context.saveGState()
        context.clip(to: body)
        string.draw(at: NSPoint(
            x: body.midX - size.width / 2,
            y: body.midY - size.height / 2
        ))
        context.restoreGState()
    }

    static func label(for transition: ClipTransition) -> String {
        guard let direction = transition.direction else { return transition.style.displayName }
        return "\(transition.style.displayName) \(direction.rawValue.capitalized)"
    }
}
