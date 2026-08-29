import SwiftUI

struct TextTab: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    private static let defaults = TextStyle()

    private var clip: Clip { clips[0] }
    private var clipIds: [String] { clips.map(\.id) }
    private var isBatch: Bool { clips.count > 1 }

    private var fillMode: TextFillMode? {
        sharedClipValue(clips) { $0.textFillMode ?? .color }
    }

    private var styleDefaults: TextStyle {
        var defaults = Self.defaults
        if fillMode == .footage {
            defaults.color = TextFillMode.defaultFootageMatteColor
        }
        return defaults
    }

    private var showsColorControl: Bool {
        guard let fillMode else { return false }
        return fillMode != .inverted
    }

    private var showsSolidFillControls: Bool {
        fillMode == .color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            contentField
            PresetRow(kind: .textStyle, clips: clips)
                .padding(.horizontal, AppTheme.Spacing.lg)
            TextStyleControls(
                selection: TextStyleSelection(
                    styles: clips.map { $0.textStyle ?? styleDefaults },
                    fallback: styleDefaults
                ),
                defaults: styleDefaults,
                showsColorControl: showsColorControl,
                showsSolidFillControls: showsSolidFillControls,
                keyframeClips: clips,
                actions: styleActions,
                afterAlignment: {
                    positionSection
                    tiltSection
                    rotationSection
                    fillModeRow
                },
                afterColor: { opacitySlider }
            )
        }
    }

    private var fillModeRow: some View {
        let current = sharedClipValue(clips) { $0.textFillMode ?? .color }
        return InspectorRow(
            label: L10n.string("Fill"),
            onReset: {
                editor.commitClipProperties(clipIds: clipIds) { $0.setTextFillMode(.color) }
            }
        ) {
            Menu {
                ForEach(TextFillMode.allCases, id: \.self) { mode in
                    Button(L10n.string(key: mode.displayName)) {
                        editor.commitClipProperties(clipIds: clipIds) {
                            $0.setTextFillMode(mode)
                        }
                    }
                }
            } label: {
                EditorMenuValue(text: current.map { L10n.string(key: $0.displayName) } ?? "—")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
        }
    }

    private var contentField: some View {
        EditorPanelGroup(L10n.string("Text")) {
            TextContentField(
                text: Binding(
                    get: { clip.textContent ?? "" },
                    set: { new in
                        guard !isBatch else { return }
                        editor.applyTextContent(clipId: clip.id, content: new)
                    }
                ),
                onCommit: { new in
                    guard !isBatch else { return }
                    editor.commitTextContent(clipId: clip.id, content: new)
                }
            )
            .disabled(isBatch)
            .opacity(isBatch ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
            .frame(minHeight: AppTheme.EditorPanel.textEditorMinHeight)
            .padding(AppTheme.Spacing.smMd)
            .editorValueField()
        }
    }

    private var opacitySlider: some View {
        InspectorRow(
            label: L10n.string("Opacity"),
            onReset: {
                editor.commitClipProperties(clipIds: clipIds) {
                    $0.opacity = 1
                    $0.opacityTrack = nil
                }
            }
        ) {
            InspectorKeyframePropertyControl(clips: clips, property: .opacity)
        }
    }

    @ViewBuilder
    private var positionSection: some View {
        InspectorRow(
            label: L10n.string("Position"),
            onReset: {
                editor.commitClipProperties(clipIds: clipIds) {
                    $0.transform.centerX = Transform().centerX
                    $0.transform.centerY = Transform().centerY
                    $0.positionTrack = nil
                }
            }
        ) {
            InspectorKeyframePropertyControl(clips: clips, property: .position)
        }
    }

    private var tiltSection: some View {
        InspectorRow(
            label: L10n.string("Tilt"),
            onReset: {
                editor.commitClipProperties(clipIds: clipIds, actionName: "Reset Text Tilt") {
                    $0.transform.rotationX = 0
                    $0.transform.rotationY = 0
                }
            }
        ) {
            HStack(spacing: AppTheme.Spacing.sm) {
                tiltField("X", keyPath: \.rotationX)
                tiltField("Y", keyPath: \.rotationY)
            }
            .fixedSize()
        }
    }

    private func tiltField(_ axis: String, keyPath: WritableKeyPath<Transform, Double>) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.transform[keyPath: keyPath] },
            range: Transform.tiltRotationRange,
            format: "%.0f",
            valueSuffix: "°",
            fieldWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
            trailingLabel: axis,
            onChanged: { value in
                editor.applyClipProperties(clipIds: clipIds) {
                    $0.transform[keyPath: keyPath] = value
                }
            }
        ) { value in
            editor.commitClipProperties(clipIds: clipIds, actionName: "Change Text Tilt") {
                $0.transform[keyPath: keyPath] = value
            }
        }
    }

    private var rotationSection: some View {
        InspectorRow(
            label: L10n.string("Rotation"),
            onReset: {
                editor.commitClipProperties(clipIds: clipIds, actionName: "Reset Rotation") {
                    $0.transform.rotation = Transform().rotation
                    $0.rotationTrack = nil
                }
            }
        ) {
            InspectorKeyframePropertyControl(clips: clips, property: .rotation)
        }
    }

    private var styleActions: TextStyleEditingActions {
        TextStyleEditingActions(
            apply: { fitToContent, mutation in
                editor.applyTextStyles(
                    clipIds: clipIds,
                    fitToContent: fitToContent,
                    mutation
                )
            },
            commit: { fitToContent, mutation in
                editor.commitTextStyles(
                    clipIds: clipIds,
                    fitToContent: fitToContent,
                    mutation
                )
            },
            commitColor: { key, mutation in
                editor.debouncedCommitTextStyles(clipIds: clipIds, key: key, mutation)
            },
            cancelPending: { editor.cancelDebouncedCommit(key: $0) },
            cancelFontPreview: { _ in
                editor.revertClipProperties(clipIds: clipIds)
            }
        )
    }
}

struct TextAnimateTab: View {
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor

    private var clip: Clip { clips[0] }
    private var targetIds: [String] {
        editor.captionGroupTextClipIds(expanding: clips.map(\.id))
    }

    var body: some View {
        let anim = clip.textAnimation ?? TextAnimation()
        EditorPanelGroup(L10n.string("Animation")) {
            CaptionPresetGallery(
                selection: Binding(
                    get: { anim.preset },
                    set: { new in setAnim { $0.preset = new } }
                ),
                highlight: anim.highlight
            )
            if anim.preset.usesHighlight { highlightRow(anim) }
        }
        keyframeGroup
        if clips.count == 1 { accentGroup }
    }

    private var keyframeProperties: [AnimatableProperty] {
        AnimatableProperty.visualLaneOrder.filter { property in
            clips.allSatisfy { $0.supportsKeyframes(for: property) }
        }
    }

    private var keyframeGroup: some View {
        EditorPanelGroup(L10n.string("Keyframes")) {
            ForEach(keyframeProperties, id: \.self) { property in
                InspectorRow(
                    label: L10n.string(key: property.displayName),
                    onReset: {
                        editor.commitClipProperties(clipIds: targetIds) {
                            $0.clearKeyframes(for: property)
                        }
                    }
                ) {
                    InspectorKeyframePropertyControl(clips: clips, property: property)
                }
            }
        }
    }

    private var accentWords: [String] {
        TextAccent.tokens(in: clip.textContent ?? "").map(\.text)
    }

    private var accentColor: TextStyle.RGBA {
        clip.textAccent?.color ?? TextAnimation.defaultHighlight
    }

    @ViewBuilder
    private var accentGroup: some View {
        let words = accentWords
        if !words.isEmpty {
            EditorPanelGroup("Accent") {
                InspectorRow(
                    label: "Color",
                    onReset: { setAccent(color: TextAnimation.defaultHighlight, words: selectedAccentWords) }
                ) {
                    ColorField(
                        displayColor: accentColor.swiftUIColor,
                        onUserChange: { new in
                            editor.debouncedCommitClipProperties(clipIds: targetIds, key: "textAccent") {
                                guard let existing = $0.textAccent else { return }
                                $0.textAccent = TextAccent(color: TextStyle.RGBA(new), words: existing.words)
                            }
                        }
                    )
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 56), spacing: AppTheme.Spacing.xs)],
                    alignment: .leading,
                    spacing: AppTheme.Spacing.xs
                ) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        accentChip(word: word, index: index)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.sm)
            }
        }
    }

    private var selectedAccentWords: [Int] { clip.textAccent?.words ?? [] }

    private func accentChip(word: String, index: Int) -> some View {
        let on = clip.textAccent?.covers(index) ?? false
        return Button {
            var next = Set(selectedAccentWords)
            if on { next.remove(index) } else { next.insert(index) }
            setAccent(color: accentColor, words: Array(next))
        } label: {
            Text(word)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .padding(.horizontal, AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(on ? accentColor.swiftUIColor.opacity(AppTheme.Opacity.medium) : AppTheme.Background.raisedColor)
                )
                .foregroundStyle(on ? accentColor.swiftUIColor : AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.plain)
    }

    private func setAccent(color: TextStyle.RGBA, words: [Int]) {
        editor.cancelDebouncedCommit(key: "textAccent")
        let value: TextAccent? = words.isEmpty ? nil : TextAccent(color: color, words: words)
        editor.commitClipProperties(clipIds: targetIds) { $0.textAccent = value }
    }

    private func setAnim(_ modify: (inout TextAnimation) -> Void) {
        var a = clip.textAnimation ?? TextAnimation()
        modify(&a)
        let value: TextAnimation? = a.preset == .none ? nil : a
        editor.cancelDebouncedCommit(key: "textHighlight")
        editor.commitClipProperties(clipIds: targetIds) { $0.textAnimation = value }
    }

    private func highlightRow(_ anim: TextAnimation) -> some View {
        InspectorRow(
            label: L10n.string("Highlight"),
            onReset: {
                editor.cancelDebouncedCommit(key: "textHighlight")
                editor.commitClipProperties(clipIds: targetIds) {
                    guard var animation = $0.textAnimation else { return }
                    animation.highlight = TextAnimation.defaultHighlight
                    $0.textAnimation = animation
                }
            }
        ) {
            ColorField(
                displayColor: (anim.highlight ?? TextAnimation.defaultHighlight).swiftUIColor,
                onUserChange: { new in
                    editor.debouncedCommitClipProperties(clipIds: targetIds, key: "textHighlight") {
                        guard var a = $0.textAnimation, a.preset.usesHighlight else { return }
                        a.highlight = TextStyle.RGBA(new)
                        $0.textAnimation = a
                    }
                }
            )
        }
    }
}
