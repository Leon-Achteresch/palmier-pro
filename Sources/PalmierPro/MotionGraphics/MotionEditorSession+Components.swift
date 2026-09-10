import AppKit

struct MotionComponentCandidate: Identifiable {
    var id: String { component.id }
    var component: MotionComponent
    var previous: MotionComponent
    var expectedRevision: String
    var changedProps: [String] {
        let previousProps = Dictionary(uniqueKeysWithValues: previous.props.map { ($0.id, $0) })
        let props = Dictionary(uniqueKeysWithValues: component.props.map { ($0.id, $0) })
        return Set(previousProps.keys).union(props.keys).filter { previousProps[$0] != props[$0] }.sorted()
    }
    var removedSlots: [String] { previous.slots.filter { !component.slots.contains($0) } }
}

extension MotionEditorSession {
    func createComponent(name: String, source: String) {
        let expected = revision
        run {
            let receipt = try await self.editor.motionScenes.createComponent(name: name, source: source,
                mediaRef: self.mediaRef, expectedRevision: expected, editor: self.editor)
            if let snapshot = self.editor.motionScenes.snapshot(for: receipt.mediaRef) {
                self.selection = Set(snapshot.scene.nodes.filter { receipt.changedIDs.contains($0.id) }.map(\.id))
            }
            self.selectedComponentID = nil
            self.showingComponentCreation = false
        }
    }

    func browseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = editor.linkedContextPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url else { return }
                self.run {
                    let result = try await MotionComponentAnalyzer.shared.index(repository: url)
                    try Task.checkCancellation()
                    self.repositoryURL = url
                    self.repositoryIndex = result
                }
            }
        }
    }

    func importRepositoryComponent(_ item: MotionRepositoryComponent) {
        guard let repositoryURL else { return }
        importComponent(at: repositoryURL.appendingPathComponent(item.path), exportName: item.exportName)
    }

    func importComponent(at url: URL, exportName: String) {
        guard let scene else { return }
        let expected = revision
        run {
            let result = try await MotionComponentCompiler.shared.compile(at: url, exportName: exportName, runtime: scene.runtime)
            guard result.runtime == scene.runtime else { throw MotionSceneError.invalidField("component runtime does not match this scene") }
            try Task.checkCancellation()
            if let previous = scene.components.first(where: { $0.id == result.component.id }), previous != result.component {
                self.componentCandidate = MotionComponentCandidate(component: result.component, previous: previous, expectedRevision: expected)
            } else {
                _ = try await self.editor.motionScenes.apply([.component(result.component)], mediaRef: self.mediaRef,
                    expectedRevision: expected, actionName: "Import Motion Component", editor: self.editor)
                self.selection = []
                self.selectedComponentID = result.component.id
            }
        }
    }

    func applyComponentCandidate(_ candidate: MotionComponentCandidate) {
        run {
            _ = try await self.editor.motionScenes.apply([.component(candidate.component)], mediaRef: self.mediaRef,
                expectedRevision: candidate.expectedRevision, actionName: "Update Motion Component", editor: self.editor)
            self.componentCandidate = nil
        }
    }
}
