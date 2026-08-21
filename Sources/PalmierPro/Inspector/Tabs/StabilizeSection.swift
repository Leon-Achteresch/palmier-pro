import SwiftUI

extension InspectorView {

    @ViewBuilder
    func stabilizeSection(clips: [Clip]) -> some View {
        let targets = clips.filter(\.supportsStabilization)
        if !targets.isEmpty {
            EditorPanelGroup("Stabilize", contentSpacing: AppTheme.Spacing.smMd) {
                let allOn = targets.allSatisfy(\.isStabilized)
                propertyRow(
                    label: "Stabilize",
                    onReset: {
                        editor.setStabilization(
                            clipIds: Set(targets.map(\.id)),
                            enabled: false,
                            actionName: "Reset Stabilization"
                        )
                    }
                ) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if allOn {
                            ScrubbableNumberField(
                                value: sharedClipValue(targets) { ($0.stabilization?.smoothing ?? 0) * 100 },
                                range: 0...100,
                                format: "%.0f",
                                valueSuffix: "%",
                                dragSensitivity: 0.5,
                                fieldWidth: AppTheme.EditorPanel.numericFieldWidth
                            ) { percent in
                                editor.setStabilization(
                                    clipIds: Set(targets.map(\.id)),
                                    enabled: true,
                                    smoothing: percent / 100,
                                    actionName: "Change Stabilization Smoothing"
                                )
                            }
                            .help("How locked-off the shot looks. Higher fights more shake and crops more of the frame.")
                        }
                        Toggle("", isOn: Binding(
                            get: { allOn },
                            set: { enabled in
                                editor.setStabilization(
                                    clipIds: Set(targets.map(\.id)),
                                    enabled: enabled,
                                    actionName: enabled ? "Stabilize Clip" : "Remove Stabilization"
                                )
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .accessibilityLabel("Stabilize")
                    }
                }
                .help("Smooths handheld shake by analyzing the camera path on-device. The media is not re-encoded.")
                stabilizeStatus(targets: targets)
            }
        }
    }

    @ViewBuilder
    private func stabilizeStatus(targets: [Clip]) -> some View {
        let analyzing = targets.compactMap { editor.stabilizationJobs.job(forClip: $0.id) }
            .filter { $0.state == .analyzing }
        let failed = targets.compactMap { editor.stabilizationJobs.job(forClip: $0.id) }
            .first { $0.state == .failed }
        let crop = targets.compactMap { $0.stabilization?.cropPercent }.max()
        if let job = analyzing.first {
            HStack(spacing: AppTheme.Spacing.xs) {
                ProgressView(value: job.progress)
                    .controlSize(.small)
                    .frame(width: AppTheme.EditorPanel.numericFieldWidth)
                Text(analyzing.count > 1
                    ? "Analyzing \(analyzing.count) shots…"
                    : "Analyzing camera path…")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        } else if let failed {
            Text(failed.failureReason ?? "Stabilization analysis failed.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.errorColor)
        } else if let crop, crop > 0 {
            Text("Crops \(String(format: "%.0f", crop))% to hide the edges.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }
}
