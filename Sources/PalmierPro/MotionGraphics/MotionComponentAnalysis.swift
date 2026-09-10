import Foundation
import JavaScriptCore

struct MotionComponentAnalysis: Codable, Sendable {
    struct Import: Codable, Sendable { var module: String; var names: [String] }
    var exports: [String]
    var props: [MotionPropSchema]
    var fixtures: [String: [String: MotionValue]]
    var imports: [Import]
    var isStory: Bool
    var diagnostics: [String]
}

struct MotionRepositoryComponent: Codable, Sendable, Identifiable {
    var path: String
    var exportName: String
    var propCount: Int
    var isStory: Bool
    var id: String { path + "#" + exportName }
}

struct MotionRepositoryIndex: Codable, Sendable {
    var components: [MotionRepositoryComponent]
    var truncated: Bool
}

actor MotionComponentAnalyzer {
    static let shared = MotionComponentAnalyzer()
    private var context: JSContext?

    func analyze(at url: URL, exportName: String = "default") throws -> MotionComponentAnalysis {
        try Task.checkCancellation()
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard metadata.isRegularFile == true, (metadata.fileSize ?? Int.max) <= 2 * 1024 * 1024 else {
            throw MotionSceneError.invalidField("component entry must be a regular source file smaller than 2 MB")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return try analyze(source: source, filename: url.lastPathComponent, exportName: exportName)
    }

    func analyze(source: String, filename: String, exportName: String) throws -> MotionComponentAnalysis {
        try Task.checkCancellation()
        let context = try preparedContext()
        context.exception = nil
        let result = context.objectForKeyedSubscript("PalmierComponentAnalysis")?.objectForKeyedSubscript("analyze")?
            .call(withArguments: [source, filename, exportName])
        if let exception = context.exception { throw MotionSceneError.sceneFailed(exception.toString() ?? "component analysis failed") }
        guard let json = result?.toString() else { throw MotionSceneError.sceneFailed("component analysis returned no result") }
        return try JSONDecoder().decode(MotionComponentAnalysis.self, from: Data(json.utf8))
    }

    func index(repository: URL, search: String = "") throws -> MotionRepositoryIndex {
        try Task.checkCancellation()
        let root = repository.resolvingSymlinksInPath().standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw MotionSceneError.invalidField("choose a repository directory") }
        let excluded: Set<String> = ["node_modules", ".git", ".build", "build", "dist", ".next", "Pods", "vendor", "coverage"]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { throw MotionSceneError.invalidField("repository could not be indexed") }
        var components: [MotionRepositoryComponent] = []
        var count = 0
        var truncated = false
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let metadata = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if metadata.isSymbolicLink == true || metadata.isDirectory == true && excluded.contains(url.lastPathComponent) {
                enumerator.skipDescendants(); continue
            }
            guard metadata.isDirectory != true, ["tsx", "jsx", "ts", "js"].contains(url.pathExtension), !url.lastPathComponent.hasSuffix(".d.ts"),
                  (metadata.fileSize ?? Int.max) <= 2 * 1024 * 1024 else { continue }
            count += 1
            if count > 2000 { truncated = true; break }
            let analysis = try analyze(at: url)
            let relative = String(url.path.dropFirst(root.path.count + 1))
            for name in analysis.exports where search.isEmpty || relative.localizedCaseInsensitiveContains(search) || name.localizedCaseInsensitiveContains(search) {
                if analysis.isStory && name == "default" { continue }
                components.append(MotionRepositoryComponent(path: relative, exportName: name, propCount: analysis.props.count, isStory: analysis.isStory))
            }
        }
        return MotionRepositoryIndex(components: components.sorted { $0.id < $1.id }, truncated: truncated)
    }

    private func preparedContext() throws -> JSContext {
        if let context { return context }
        guard let url = BundledResource.url("MotionRuntime/Compiler/component-analyzer.js"), let context = JSContext() else { throw MotionSceneError.runtimeMissing }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        if let exception = context.exception { throw MotionSceneError.sceneFailed(exception.toString() ?? "component analyzer could not start") }
        self.context = context
        return context
    }
}
