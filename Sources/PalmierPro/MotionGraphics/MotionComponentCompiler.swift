import CryptoKit
import Foundation

struct MotionComponentImport: Sendable {
    var component: MotionComponent
    var runtime: MotionSceneRuntime
    var exports: [String]
}

struct MotionComponentRegistration: Codable, Sendable {
    var id: String?
    var name: String?
    var entry: String
    var exportName: String
    var runtime: MotionSceneRuntime
    var props: [MotionPropSchema]
    var fixtures: [String: [String: MotionValue]]
    var slots: [String]
}

actor MotionComponentCompiler {
    static let shared = MotionComponentCompiler()
    private let gate = AsyncSemaphore(value: 1)
    private var running: (id: UUID, process: Process)?

    func compile(at url: URL, exportName: String = "default", runtime: MotionSceneRuntime = .web) async throws -> MotionComponentImport {
        try await gate.wait()
        do {
            let result = try await build(at: url, exportName: exportName, runtime: runtime)
            await gate.signal()
            return result
        } catch {
            await gate.signal()
            throw error
        }
    }

    func compile(source: String, name: String, runtime: MotionSceneRuntime) async throws -> MotionComponentImport {
        try Task.checkCancellation()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count < 2 * 1024 * 1024 else {
            throw MotionSceneError.invalidField("provide a component name and source smaller than 2 MB")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("motion-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Log.preview.warning("motion component draft cleanup failed") }
        }
        let entry = directory.appendingPathComponent("Component.tsx")
        try source.write(to: entry, atomically: true, encoding: .utf8)
        var result = try await compile(at: entry, runtime: runtime)
        try Task.checkCancellation()
        result.component.id = UUID().uuidString
        result.component.name = name
        return result
    }

    private func build(at url: URL, exportName: String, runtime: MotionSceneRuntime) async throws -> MotionComponentImport {
        try Task.checkCancellation()
        let registration: MotionComponentRegistration?
        if url.pathExtension.lowercased() == "json" {
            let data = try Data(contentsOf: url)
            guard data.count <= 2 * 1024 * 1024 else { throw MotionSceneError.invalidField("component registration is too large") }
            registration = try JSONDecoder().decode(MotionComponentRegistration.self, from: data)
        } else { registration = nil }
        let entry = registration.map { URL(fileURLWithPath: $0.entry, relativeTo: url.deletingLastPathComponent()).standardizedFileURL } ?? url
        let selectedExport = registration?.exportName ?? exportName
        let target = registration?.runtime ?? runtime
        guard ["tsx", "jsx", "ts", "js", "mjs", "cjs"].contains(entry.pathExtension.lowercased()),
              Self.validExport(selectedExport) else { throw MotionSceneError.invalidField("choose a JavaScript/TypeScript component and a valid export name") }
        let analysis = try await MotionComponentAnalyzer.shared.analyze(at: entry, exportName: selectedExport)
        guard analysis.diagnostics.isEmpty else { throw MotionSceneError.invalidField(analysis.diagnostics.joined(separator: "; ")) }
        guard let compiler = BundledResource.url("MotionRuntime/Compiler/esbuild") else { throw MotionSceneError.sceneFailed("the bundled component compiler is missing; rebuild the motion runtime") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("motion-component-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch { Log.preview.warning("motion component compiler temporary cleanup failed") }
        }
        let buildEntry: URL
        if analysis.isStory {
            guard analysis.exports.contains(selectedExport), selectedExport != "default" else { throw MotionSceneError.invalidField("select a named component story") }
            buildEntry = scratch.appendingPathComponent("story-adapter.tsx")
            let path = String(decoding: try JSONEncoder().encode(entry.path), as: UTF8.self)
            try """
            import React from 'react';
            import meta, { \(selectedExport) as story } from \(path);
            export default function StoryComponent(props) {
              const args = {...meta.args, ...story.args, ...props};
              const context = {args, globals: {}, parameters: {...meta.parameters, ...story.parameters}, viewMode: 'story'};
              const render = story.render || meta.render || ((args) => React.createElement(meta.component, args));
              let content = () => render(args, context);
              for (const decorator of [...(story.decorators || []), ...(meta.decorators || [])]) {
                const previous = content;
                content = () => decorator(previous, context);
              }
              return content();
            }
            """.write(to: buildEntry, atomically: true, encoding: .utf8)
        } else { buildEntry = entry }
        let output = scratch.appendingPathComponent("component.js")
        let metadata = scratch.appendingPathComponent("metadata.json")
        let diagnostics = scratch.appendingPathComponent("diagnostics.txt")
        guard FileManager.default.createFile(atPath: diagnostics.path, contents: nil) else { throw MotionSceneError.writeFailed }
        let log = try FileHandle(forWritingTo: diagnostics)
        defer { try? log.close() }
        let external = ["react", "react/jsx-runtime", "react/jsx-dev-runtime", "react-dom", "react-dom/client", "palmier", "remotion"]
            + (target == .web ? ["motion", "motion/react", "framer-motion", "lucide-react"] : ["react-native"])
        var arguments = [buildEntry.path, "--bundle", "--format=esm", "--platform=browser", "--target=es2022", "--jsx=transform",
                         "--define:process.env.NODE_ENV=\"production\"", "--outfile=\(output.path)", "--metafile=\(metadata.path)",
                         "--log-level=warning", "--charset=utf8"]
        arguments += external.map { "--external:\($0)" }
        arguments += ["png", "jpg", "jpeg", "webp", "gif", "svg", "woff", "woff2", "ttf", "otf", "mp4", "mp3"].map { "--loader:.\($0)=dataurl" }
        let process = Process()
        process.executableURL = compiler
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": scratch.path]
        process.currentDirectoryURL = entry.deletingLastPathComponent()
        process.standardOutput = log
        process.standardError = log
        let requestID = UUID()
        running = (requestID, process)
        defer { running = nil }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() }
                catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { await self.cancel(requestID) }
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = try String(contentsOf: diagnostics, encoding: .utf8)
            throw MotionSceneError.sceneFailed("component build failed: \(message.prefix(4000))")
        }
        struct Metadata: Decodable {
            struct Output: Decodable {
                struct Import: Decodable { var path: String; var external: Bool? }
                var exports: [String]?
                var imports: [Import]
            }
            var outputs: [String: Output]
        }
        let meta = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadata))
        let exports = meta.outputs.filter { $0.key.hasSuffix("component.js") }.values.flatMap { $0.exports ?? [] }.sorted()
        guard exports.contains(analysis.isStory ? "default" : selectedExport) else { throw MotionSceneError.invalidField("export '\(selectedExport)' not found; available exports: \(exports.joined(separator: ", "))") }
        for imported in meta.outputs.values.flatMap(\.imports) where imported.external == true {
            guard target == .web || !["react-dom", "react-dom/client"].contains(imported.path) else {
                throw MotionSceneError.invalidField("React DOM components require a web scene")
            }
            guard external.contains(imported.path) || imported.path.hasPrefix("data:") else {
                throw MotionSceneError.invalidField("unsupported external dependency '\(imported.path)'; bundle it or provide a controlled fixture")
            }
        }
        let code = try String(contentsOf: output, encoding: .utf8)
        let cssURL = output.deletingPathExtension().appendingPathExtension("css")
        let css = FileManager.default.fileExists(atPath: cssURL.path) ? try String(contentsOf: cssURL, encoding: .utf8) : ""
        guard target == .web || css.isEmpty else { throw MotionSceneError.invalidField("React Native components cannot import CSS") }
        let identity = SHA256.hash(data: Data("\(entry.standardizedFileURL.path)|\(selectedExport)|\(target.rawValue)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let component = MotionComponent(
            id: registration?.id ?? "component-\(identity)", name: registration?.name ?? entry.deletingPathExtension().lastPathComponent,
            source: code + "\nconst __palmierSelected = module.exports[\"\(analysis.isStory ? "default" : selectedExport)\"]; module.exports = {default: __palmierSelected};",
            stylesheet: css, props: registration?.props ?? analysis.props, fixtures: registration?.fixtures ?? analysis.fixtures, slots: registration?.slots ?? []
        )
        var validation = MotionScene(width: 320, height: 180, fps: 30, durationInFrames: 30, runtime: target)
        validation.components = [component]
        _ = try validation.validated()
        return MotionComponentImport(component: component, runtime: target, exports: exports)
    }

    private func cancel(_ id: UUID) {
        guard let running, running.id == id, running.process.isRunning else { return }
        running.process.terminate()
    }

    private static func validExport(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" || first == "$" else { return false }
        return name.count <= 128 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    }
}
