import SwiftUI

extension InspectorView {
    func mixSection(audios: [Clip]) -> some View {
        EditorPanelGroup(
            "Mix",
            isExpanded: $audioMixExpanded,
            onReset: {
                commitPropertiesToClips(audios, actionName: "Reset Mix") { $0.audioMix = nil }
            }
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                panRow(audios: audios)
                eqRow(label: "Low", audios: audios, gain: \.lowGainDb)
                eqRow(label: "Mid", audios: audios, gain: \.midGainDb)
                midFrequencyRow(audios: audios)
                eqRow(label: "High", audios: audios, gain: \.highGainDb)
                compressorRow(audios: audios)
                if audios.contains(where: { $0.audioMix?.compressor != nil }) {
                    compressorField(label: "Threshold", audios: audios, range: ClipAudioMixLimits.thresholdDb,
                                    format: "%.1f", suffix: " dB", sensitivity: 0.3, value: \.thresholdDb)
                    compressorField(label: "Ratio", audios: audios, range: ClipAudioMixLimits.ratio,
                                    format: "%.1f", suffix: ":1", sensitivity: 0.1, value: \.ratio)
                    compressorField(label: "Attack", audios: audios, range: ClipAudioMixLimits.attackMs,
                                    format: "%.1f", suffix: " ms", sensitivity: 0.2, value: \.attackMs)
                    compressorField(label: "Release", audios: audios, range: ClipAudioMixLimits.releaseMs,
                                    format: "%.0f", suffix: " ms", sensitivity: 2, value: \.releaseMs)
                    compressorField(label: "Makeup", audios: audios, range: ClipAudioMixLimits.makeupGainDb,
                                    format: "%.1f", suffix: " dB", sensitivity: 0.3, value: \.makeupGainDb)
                }
            }
        }
    }

    private func panRow(audios: [Clip]) -> some View {
        propertyRow(
            label: "Pan",
            onReset: { commitMix(audios, actionName: "Reset Pan") { $0.pan = 0 } },
            reservesKeyframeControls: true
        ) {
            ScrubbableNumberField(
                value: sharedClipValue(audios) { $0.audioMix?.pan ?? 0 },
                range: ClipAudioMixLimits.pan,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                dragSensitivity: 0.01,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { value in applyMix(audios) { $0.pan = value } }
            ) { value in
                commitMix(audios, actionName: "Change Pan") { $0.pan = value }
            }
            .help("Stereo position: negative is left, positive is right. Mono sources keep their level.")
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    private func eqRow(
        label: String, audios: [Clip], gain: WritableKeyPath<AudioEQSettings, Double>
    ) -> some View {
        propertyRow(
            label: label,
            onReset: {
                commitMix(audios, actionName: "Reset \(label) EQ") { mix in
                    var settings = mix.eq ?? AudioEQSettings()
                    settings[keyPath: gain] = 0
                    mix.eq = settings
                }
            },
            reservesKeyframeControls: true
        ) {
            ScrubbableNumberField(
                value: sharedClipValue(audios) { $0.audioMix?.eq?[keyPath: gain] ?? 0 },
                range: ClipAudioMixLimits.eqGainDb,
                format: "%.1f",
                valueSuffix: " dB",
                dragSensitivity: 0.2,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { value in
                    applyMix(audios) { mix in
                        var settings = mix.eq ?? AudioEQSettings()
                        settings[keyPath: gain] = value
                        mix.eq = settings
                    }
                }
            ) { value in
                commitMix(audios, actionName: "Change \(label) EQ") { mix in
                    var settings = mix.eq ?? AudioEQSettings()
                    settings[keyPath: gain] = value
                    mix.eq = settings
                }
            }
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    private func midFrequencyRow(audios: [Clip]) -> some View {
        propertyRow(
            label: "Mid Freq",
            onReset: {
                commitMix(audios, actionName: "Reset Mid Frequency") { mix in
                    var settings = mix.eq ?? AudioEQSettings()
                    settings.midFrequency = ClipAudioMixLimits.midFrequencyDefault
                    mix.eq = settings
                }
            },
            reservesKeyframeControls: true
        ) {
            ScrubbableNumberField(
                value: sharedClipValue(audios) {
                    $0.audioMix?.eq?.midFrequency ?? ClipAudioMixLimits.midFrequencyDefault
                },
                range: ClipAudioMixLimits.midFrequency,
                format: "%.0f",
                valueSuffix: " Hz",
                dragSensitivity: 10,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { value in
                    applyMix(audios) { mix in
                        var settings = mix.eq ?? AudioEQSettings()
                        settings.midFrequency = value
                        mix.eq = settings
                    }
                }
            ) { value in
                commitMix(audios, actionName: "Change Mid Frequency") { mix in
                    var settings = mix.eq ?? AudioEQSettings()
                    settings.midFrequency = value
                    mix.eq = settings
                }
            }
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    private func compressorRow(audios: [Clip]) -> some View {
        let allOn = !audios.isEmpty && audios.allSatisfy { $0.audioMix?.compressor != nil }
        return propertyRow(
            label: "Compressor",
            onReset: { commitMix(audios, actionName: "Reset Compressor") { $0.compressor = nil } }
        ) {
            Toggle("", isOn: Binding(
                get: { allOn },
                set: { enabled in
                    commitMix(audios, actionName: enabled ? "Enable Compressor" : "Disable Compressor") { mix in
                        mix.compressor = enabled ? (mix.compressor ?? AudioCompressorSettings()) : nil
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel("Compressor")
        }
        .help("Evens out level peaks. High ratios act as a limiter.")
    }

    private func compressorField(
        label: String,
        audios: [Clip],
        range: ClosedRange<Double>,
        format: String,
        suffix: String,
        sensitivity: Double,
        value: WritableKeyPath<AudioCompressorSettings, Double>
    ) -> some View {
        propertyRow(label: label, reservesKeyframeControls: true) {
            ScrubbableNumberField(
                value: sharedClipValue(audios) {
                    ($0.audioMix?.compressor ?? AudioCompressorSettings())[keyPath: value]
                },
                range: range,
                format: format,
                valueSuffix: suffix,
                dragSensitivity: sensitivity,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newValue in
                    applyMix(audios) { mix in
                        var settings = mix.compressor ?? AudioCompressorSettings()
                        settings[keyPath: value] = newValue
                        mix.compressor = settings
                    }
                }
            ) { newValue in
                commitMix(audios, actionName: "Change Compressor \(label)") { mix in
                    var settings = mix.compressor ?? AudioCompressorSettings()
                    settings[keyPath: value] = newValue
                    mix.compressor = settings
                }
            }
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    private func applyMix(_ clips: [Clip], _ modify: @escaping (inout ClipAudioMix) -> Void) {
        editor.applyClipProperties(clipIds: clips.map(\.id)) { clip in
            var mix = clip.audioMix ?? ClipAudioMix()
            modify(&mix)
            clip.audioMix = mix.normalized
        }
    }

    private func commitMix(
        _ clips: [Clip], actionName: String, _ modify: @escaping (inout ClipAudioMix) -> Void
    ) {
        editor.commitClipProperties(clipIds: clips.map(\.id), actionName: actionName) { clip in
            var mix = clip.audioMix ?? ClipAudioMix()
            modify(&mix)
            clip.audioMix = mix.normalized
        }
    }
}
