import SwiftUI

struct MotionSceneInspector: View {
    let session: MotionEditorSession
    let scene: MotionScene

    var body: some View {
        Text(L10n.string("Scene")).fontWeight(AppTheme.FontWeight.semibold)
        MotionValueField(label: L10n.string("Width"), value: .number(Double(scene.width))) { value in
            if let n = value.integer { configure(width: n) }
        }
        MotionValueField(label: L10n.string("Height"), value: .number(Double(scene.height))) { value in
            if let n = value.integer { configure(height: n) }
        }
        MotionValueField(label: L10n.string("Frame Rate"), value: .number(scene.fps)) { value in
            if let n = value.number { configure(fps: n) }
        }
        MotionValueField(label: L10n.string("Duration Frames"), value: .number(Double(scene.durationInFrames))) { value in
            if let n = value.integer { configure(duration: n) }
        }
        MotionValueField(label: L10n.string("Background"), value: .string(scene.background)) { value in
            if let color = value.string { configure(background: color) }
        }
        Divider()
        Text(L10n.string("Format Variants")).fontWeight(AppTheme.FontWeight.semibold)
        Button(L10n.string("Save Current Format")) {
            session.perform([.format(MotionFormat(name: "\(scene.width) × \(scene.height)", width: scene.width, height: scene.height,
                overrides: Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0.properties) })))])
        }
        ForEach(scene.formats) { format in
            DisclosureGroup {
                MotionValueField(label: L10n.string("Name"), value: .string(format.name)) { value in
                    if let name = value.string { var updated = format; updated.name = name; session.perform([.format(updated)]) }
                }
                MotionValueField(label: L10n.string("Width"), value: .number(Double(format.width))) { value in
                    if let n = value.integer { var updated = format; updated.width = n; session.perform([.format(updated)]) }
                }
                MotionValueField(label: L10n.string("Height"), value: .number(Double(format.height))) { value in
                    if let n = value.integer { var updated = format; updated.height = n; session.perform([.format(updated)]) }
                }
                Button(L10n.string("Apply Format")) { session.perform([.applyFormat(id: format.id)], name: "Apply Motion Format") }
                Button(L10n.string("Update Layer Layout")) {
                    var updated = format
                    updated.overrides = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0.properties) })
                    session.perform([.format(updated)])
                }
                Button(L10n.string("Delete")) { session.perform([.removeFormat(id: format.id)]) }
            } label: { Text(verbatim: format.name) }
        }
        Divider()
        Text(L10n.string("Sound Cues")).fontWeight(AppTheme.FontWeight.semibold)
        Menu(L10n.string("Add Sound Cue")) {
            ForEach(session.editor.mediaAssets.filter { $0.type == .audio }) { asset in
                Button { session.addAudioCue(asset) } label: { Text(verbatim: asset.name) }
            }
        }
        ForEach(scene.audioCues) { cue in
            MotionAudioCueInspector(session: session, cue: cue)
        }
    }

    private func configure(width: Int? = nil, height: Int? = nil, fps: Double? = nil, duration: Int? = nil, background: String? = nil) {
        session.perform([.configure(width: width ?? scene.width, height: height ?? scene.height, fps: fps ?? scene.fps,
                                   duration: duration ?? scene.durationInFrames, background: background ?? scene.background)])
    }
}

private struct MotionAudioCueInspector: View {
    let session: MotionEditorSession
    let cue: MotionAudioCue

    var body: some View {
        DisclosureGroup {
            field(L10n.string("Start Frame"), \.frame)
            field(L10n.string("Source Start Frame"), \.trimStartFrame)
            field(L10n.string("Duration Frames"), \.durationFrames)
            MotionValueField(label: L10n.string("Volume dB"), value: .number(cue.volumeDB)) { value in
                if let n = value.number { var updated = cue; updated.volumeDB = n; session.perform([.audioCue(updated)]) }
            }
            Button(L10n.string("Delete")) { session.perform([.removeAudioCue(id: cue.id)]) }
        } label: { Text(verbatim: session.editor.mediaAssetsById[cue.mediaRef]?.name ?? cue.mediaRef) }
    }

    private func field(_ name: String, _ path: WritableKeyPath<MotionAudioCue, Int>) -> some View {
        MotionValueField(label: name, value: .number(Double(cue[keyPath: path]))) { value in
            if let n = value.integer { var updated = cue; updated[keyPath: path] = n; session.perform([.audioCue(updated)]) }
        }
    }
}
