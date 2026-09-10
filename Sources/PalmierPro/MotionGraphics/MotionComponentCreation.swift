import Foundation

extension MotionSceneStore {
    func createComponent(name: String, source: String, mediaRef: String, expectedRevision: String,
                         editor: EditorViewModel) async throws -> MotionSceneReceipt {
        let projectURL = editor.projectURL
        let snapshot = try await load(mediaRef: mediaRef, editor: editor)
        guard snapshot.revision == expectedRevision else { throw MotionSceneError.invalidField("scene revision conflict; read the current scene and retry") }
        let component = try await MotionComponentCompiler.shared.compile(source: source, name: name, runtime: snapshot.scene.runtime).component
        try Task.checkCancellation()
        guard editor.projectURL == projectURL else { throw MotionSceneError.invalidField("project changed during component creation") }
        let node = snapshot.scene.makeLayer(kind: .component, name: component.name, componentID: component.id)
        return try await apply([.component(component), .add([node])], mediaRef: mediaRef, expectedRevision: expectedRevision,
                               actionName: "Create Motion Component", editor: editor)
    }
}

enum MotionComponentTemplate: CaseIterable, Sendable {
    case card, title

    func source(runtime: MotionSceneRuntime) -> String {
        let props = self == .card
            ? "{title = 'Title', subtitle = 'Subtitle', background = '#182131', color = '#ffffff', cornerRadius = 16}: {title: string; subtitle: string; background: string; color: string; cornerRadius: number}"
            : "{title = 'Title', color = '#ffffff', fontSize = 48}: {title: string; color: string; fontSize: number}"
        let content: String
        switch (runtime, self) {
        case (.web, .card):
            content = """
              <div style={{width: '100%', height: '100%', boxSizing: 'border-box', padding: 24, borderRadius: cornerRadius, background, color, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 12}}>
                <div style={{fontSize: 32, fontWeight: 600}}>{title}</div>
                <div style={{fontSize: 18}}>{subtitle}</div>
              </div>
            """
        case (.web, .title):
            content = "<div style={{width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center', color, fontSize, fontWeight: 600}}>{title}</div>"
        case (.reactNative, .card):
            content = """
              <View style={{width: '100%', height: '100%', padding: 24, borderRadius: cornerRadius, backgroundColor: background, justifyContent: 'center', gap: 12}}>
                <Text style={{fontSize: 32, fontWeight: '600', color}}>{title}</Text>
                <Text style={{fontSize: 18, color}}>{subtitle}</Text>
              </View>
            """
        case (.reactNative, .title):
            content = "<View style={{width: '100%', height: '100%', alignItems: 'center', justifyContent: 'center'}}><Text style={{color, fontSize, fontWeight: '600'}}>{title}</Text></View>"
        }
        return """
        import React from 'react';
        \(runtime == .reactNative ? "import {View, Text} from 'react-native';" : "")
        export default function Component(\(props)) {
          return (\(content));
        }
        """
    }
}
