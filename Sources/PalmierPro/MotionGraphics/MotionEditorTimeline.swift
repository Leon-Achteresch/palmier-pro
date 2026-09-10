import SwiftUI

struct MotionEditorTimeline: View {
    @Bindable var session: MotionEditorSession

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            VStack(spacing: AppTheme.Spacing.xs) {
                if let scene = session.scene {
                    HStack {
                        Text(L10n.string("Frame")).frame(width: AppTheme.MotionEditor.trackLabelWidth, alignment: .leading)
                        Slider(value: Binding(get: { Double(session.frame) }, set: { session.seek(Int($0.rounded())) }),
                               in: 0...Double(max(scene.durationInFrames - 1, 1)), step: 1)
                        Text(verbatim: "\(session.frame)").monospacedDigit()
                    }
                    ScrollView {
                        LazyVStack(spacing: AppTheme.Spacing.xxs) {
                            ForEach(scene.nodes.filter { session.selection.isEmpty || session.selection.contains($0.id) }) { node in
                                HStack {
                                    Text(verbatim: node.name).lineLimit(1)
                                        .frame(width: AppTheme.MotionEditor.trackLabelWidth, alignment: .leading)
                                    GeometryReader { geometry in
                                        let unit = geometry.size.width / Double(scene.durationInFrames)
                                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                            .fill(AppTheme.Background.prominentColor)
                                            .frame(width: Double(node.durationFrames) * unit)
                                            .offset(x: Double(node.startFrame) * unit)
                                            .onTapGesture { session.select(node.id) }
                                    }
                                }.frame(height: AppTheme.MotionEditor.keyLaneHeight)
                                ForEach(node.tracks) { track in
                                    MotionKeyLane(session: session, node: node, track: track, duration: scene.durationInFrames)
                                }
                            }
                            ForEach(scene.audioCues) { cue in
                                HStack {
                                    Label { Text(verbatim: session.editor.mediaAssetsById[cue.mediaRef]?.name ?? cue.mediaRef) } icon: { Image(systemName: "waveform") }
                                        .frame(width: AppTheme.MotionEditor.trackLabelWidth, alignment: .leading)
                                    GeometryReader { geometry in
                                        let unit = geometry.size.width / Double(scene.durationInFrames)
                                        Rectangle().fill(AppTheme.Text.secondaryColor)
                                            .frame(width: Double(cue.durationFrames) * unit)
                                            .offset(x: Double(cue.frame) * unit)
                                            .onTapGesture { session.seek(cue.frame); session.selection = [] }
                                    }
                                }.frame(height: AppTheme.MotionEditor.keyLaneHeight)
                            }
                        }
                    }
                }
            }
            if let node = session.selectedNode, let track = node.tracks.first(where: { $0.binding == session.selectedBinding }) {
                Divider()
                MotionTrackInspector(session: session, node: node, track: track)
                    .frame(width: AppTheme.MotionEditor.inspectorWidth)
            }
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .controlSize(.small)
        .padding(AppTheme.Spacing.sm)
    }
}

private struct MotionKeyLane: View {
    let session: MotionEditorSession
    let node: MotionNode
    let track: MotionTrack
    let duration: Int
    @State private var draggedID: String?
    @State private var delta = 0
    @State private var dragGeneration: Int?
    @State private var dragRevision: String?

    var body: some View {
        HStack {
            Button { session.select(node.id); session.selectedBinding = track.binding } label: {
                Text(verbatim: MotionProperty(rawValue: track.binding)?.title ?? track.binding).lineLimit(1)
            }.buttonStyle(.plain)
                .frame(width: AppTheme.MotionEditor.trackLabelWidth, alignment: .leading)
            GeometryReader { geometry in
                let unit = geometry.size.width / Double(duration)
                ZStack(alignment: .leading) {
                    Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.hairline)
                    Rectangle().fill(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.BorderWidth.thin)
                        .offset(x: Double(session.frame) * unit)
                    ForEach(track.keys) { key in
                        Image(systemName: session.selectedKeyID == key.id ? "diamond.fill" : "diamond")
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .position(x: Double(node.startFrame + key.frame + (draggedID == key.id ? delta : 0)) * unit,
                                      y: geometry.size.height / 2)
                            .onTapGesture {
                                session.select(node.id)
                                session.selectedBinding = track.binding
                                session.selectedKeyID = key.id
                                session.seek(node.startFrame + key.frame)
                            }
                            .gesture(DragGesture(coordinateSpace: .named(track.id)).onChanged { value in
                                guard !session.busy, !node.locked else { return }
                                if draggedID == nil {
                                    dragGeneration = session.interactionGeneration
                                    dragRevision = session.revision
                                }
                                guard dragGeneration == session.interactionGeneration, dragRevision == session.revision else { return }
                                draggedID = key.id
                                delta = Int((value.translation.width / max(unit, 0.001)).rounded())
                            }.onEnded { _ in
                                defer { draggedID = nil; delta = 0; dragGeneration = nil; dragRevision = nil }
                                guard dragGeneration == session.interactionGeneration, dragRevision == session.revision,
                                      !session.busy, !node.locked, delta != 0 else { return }
                                var updated = track
                                if let index = updated.keys.firstIndex(where: { $0.id == key.id }) {
                                    updated.keys[index].frame += delta
                                    updated.keys.sort { $0.frame < $1.frame }
                                    session.perform([.track(id: node.id, track: updated)], name: "Move Motion Keyframe")
                                }
                            })
                    }
                }
            }
            .coordinateSpace(name: track.id)
        }.frame(height: AppTheme.MotionEditor.keyLaneHeight)
            .onChange(of: session.interactionGeneration) { delta = 0 }
    }
}

private struct MotionTrackInspector: View {
    let session: MotionEditorSession
    let node: MotionNode
    let track: MotionTrack

    var body: some View {
        ScrollView {
            VStack(spacing: AppTheme.Spacing.xs) {
                MotionCurveView(session: session, node: node, track: track)
                    .frame(height: AppTheme.MotionEditor.curveHeight)
                if let key = track.keys.first(where: { $0.id == session.selectedKeyID }) {
                    MotionValueField(label: L10n.string("Frame"), value: .number(Double(key.frame))) { value in
                        if let n = value.integer { update(key) { $0.frame = n } }
                    }
                    MotionValueField(label: L10n.string("Value"), value: key.value) { value in update(key) { $0.value = value } }
                    MotionEasingEditor(easing: key.easing) { easing in update(key) { $0.easing = easing } }
                    Button(L10n.string("Delete Keyframe")) { session.perform([.removeKey(id: node.id, binding: track.binding, keyID: key.id)]) }
                }
                MotionValueField(label: L10n.string("Repeat Count"), value: .number(Double(track.repeatCount))) { value in
                    if let n = value.integer { var updated = track; updated.repeatCount = n; save(updated) }
                }
                MotionValueField(label: L10n.string("Gap Frames"), value: .number(Double(track.gapFrames))) { value in
                    if let n = value.integer { var updated = track; updated.gapFrames = n; save(updated) }
                }
                Toggle(L10n.string("Mirror"), isOn: Binding(get: { track.mirror }, set: { var updated = track; updated.mirror = $0; save(updated) }))
                Button(L10n.string("Remove Track")) { session.perform([.removeTrack(id: node.id, binding: track.binding)]) }
            }
        }.disabled(session.busy || node.locked)
    }

    private func update(_ key: MotionKey, change: (inout MotionKey) -> Void) {
        var updated = track
        guard let index = updated.keys.firstIndex(where: { $0.id == key.id }) else { return }
        change(&updated.keys[index])
        updated.keys.sort { $0.frame < $1.frame }
        save(updated)
    }
    private func save(_ track: MotionTrack) { session.perform([.track(id: node.id, track: track)]) }
}

private struct MotionCurveView: View {
    let session: MotionEditorSession
    let node: MotionNode
    let track: MotionTrack
    @State private var samples: [Double] = []

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, let low = samples.min(), let high = samples.max() else { return }
            let span = max(high - low, 1)
            var path = Path()
            for (index, value) in samples.enumerated() {
                let point = CGPoint(x: Double(index) / Double(samples.count - 1) * size.width, y: (1 - (value - low) / span) * size.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(AppTheme.Text.primaryColor), lineWidth: AppTheme.BorderWidth.thin)
        }
        .padding(AppTheme.Spacing.xs)
        .background(AppTheme.Background.surfaceColor)
        .task(id: session.revision + track.id) {
            do { samples = try await session.curveSamples(node: node, track: track) }
            catch is CancellationError { }
            catch { session.error = error.localizedDescription }
        }
    }
}
