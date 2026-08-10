import SwiftUI

/// Floating pill over the preview while motion scenes bake, with queue progress and a time estimate.
struct MotionBakeStatusView: View {
    private var progress: MotionBakeProgress { MotionBakeProgress.shared }

    var body: some View {
        if progress.isActive {
            HStack(spacing: AppTheme.Spacing.sm) {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 140)
                Text(statusText)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(.black.opacity(AppTheme.Opacity.strong), in: Capsule())
            .allowsHitTesting(false)
        }
    }

    private var statusText: String {
        let total = progress.jobCount
        var text = "Preparing Motion Scenes \(min(progress.finishedCount + 1, total))/\(total)"
        if let eta = progress.estimatedSecondsRemaining() {
            text += " · ~\(Self.timeText(eta))"
        }
        return text
    }

    private static func timeText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
