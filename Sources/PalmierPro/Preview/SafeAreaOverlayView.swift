import SwiftUI

struct SafeAreaOverlayView: View {
    @Environment(EditorViewModel.self) var editor

    static let actionSafeFraction: CGFloat = 0.9
    static let titleSafeFraction: CGFloat = 0.8

    private static let crosshairArm = AppTheme.Spacing.mdLg
    private static let guideColor = AppTheme.Border.dividerColor

    var body: some View {
        Canvas(opaque: false) { context, size in
            let video = PreviewHitTester.videoContentRect(in: size, timeline: editor.timeline)
            guard video.width > 0, video.height > 0 else { return }

            context.stroke(
                Path(Self.safeRect(Self.actionSafeFraction, in: video)),
                with: .color(Self.guideColor),
                lineWidth: AppTheme.BorderWidth.hairline
            )
            context.stroke(
                Path(Self.safeRect(Self.titleSafeFraction, in: video)),
                with: .color(Self.guideColor),
                lineWidth: AppTheme.BorderWidth.thin
            )

            var crosshair = Path()
            let arm = min(Self.crosshairArm, min(video.width, video.height) / 2)
            crosshair.move(to: CGPoint(x: video.midX - arm, y: video.midY))
            crosshair.addLine(to: CGPoint(x: video.midX + arm, y: video.midY))
            crosshair.move(to: CGPoint(x: video.midX, y: video.midY - arm))
            crosshair.addLine(to: CGPoint(x: video.midX, y: video.midY + arm))
            context.stroke(crosshair, with: .color(Self.guideColor), lineWidth: AppTheme.BorderWidth.hairline)
        }
        .allowsHitTesting(false)
    }

    static func safeRect(_ fraction: CGFloat, in video: CGRect) -> CGRect {
        video.insetBy(dx: video.width * (1 - fraction) / 2, dy: video.height * (1 - fraction) / 2)
    }
}
