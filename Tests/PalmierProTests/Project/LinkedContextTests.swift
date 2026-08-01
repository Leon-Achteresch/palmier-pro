import Foundation
import Testing
@testable import PalmierPro

@Suite("Linked context")
struct LinkedContextReaderTests {
    @Test func listAndReadStayInsideRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-linked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let brand = root.appendingPathComponent("brand", isDirectory: true)
        try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
        let tokens = brand.appendingPathComponent("tokens.css")
        try "color: #112233;".write(to: tokens, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules", isDirectory: true),
            withIntermediateDirectories: true
        )

        let listed = try LinkedContextReader.list(rootPath: root.path, relativePath: nil, maxDepth: 3)
        #expect(listed.entries.contains(where: { $0.path == "brand" && $0.kind == "directory" }))
        #expect(listed.entries.contains(where: { $0.path == "brand/tokens.css" && $0.kind == "file" }))
        #expect(!listed.entries.contains(where: { $0.path.hasPrefix("node_modules") }))

        let read = try LinkedContextReader.read(rootPath: root.path, relativePath: "brand/tokens.css")
        guard case .text(let file) = read else {
            Issue.record("expected text read")
            return
        }
        #expect(file.text.contains("#112233"))

        #expect(throws: LinkedContextReader.LinkedContextError.self) {
            _ = try LinkedContextReader.read(rootPath: root.path, relativePath: "../outside.txt")
        }
    }

    @Test func projectFileRoundTripsLinkedContextPath() throws {
        var file = ProjectFile(
            timelines: [Fixtures.timeline()],
            activeTimelineId: nil,
            openTimelineIds: nil,
            linkedContextPath: "/Users/demo/App"
        )
        let data = try JSONEncoder().encode(file)
        let decoded = try ProjectFile.decode(data)
        #expect(decoded.linkedContextPath == "/Users/demo/App")

        file.linkedContextPath = nil
        let without = try JSONEncoder().encode(file)
        #expect(try ProjectFile.decode(without).linkedContextPath == nil)
    }
}

@Suite("Linked context — editor")
@MainActor
struct LinkedContextEditorTests {
    @Test func snapshotAndApplyPreservePath() {
        let e = EditorViewModel()
        e.setLinkedContextPath("/tmp/brand-kit")
        let file = e.projectFileSnapshot()
        #expect(file.linkedContextPath == URL(fileURLWithPath: "/tmp/brand-kit").standardizedFileURL.path)

        let e2 = EditorViewModel()
        e2.applyProjectFile(file)
        #expect(e2.linkedContextPath == file.linkedContextPath)
    }

    @Test func getTimelineReportsLinkedContext() async throws {
        let h = ToolHarness()
        h.editor.setLinkedContextPath("/tmp/product-src")
        let json = try await h.runOK("get_timeline")
        let dict = try #require(json as? [String: Any])
        let linked = try #require(dict["linkedContext"] as? [String: Any])
        #expect((linked["path"] as? String)?.contains("product-src") == true)
    }

    @Test func readProjectContextListsAndReads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-linked-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Brand\nprimary: #ff5500\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let h = ToolHarness()
        h.editor.setLinkedContextPath(root.path)

        let listed = try await h.runOK("read_project_context", args: ["action": "list"])
        let listDict = try #require(listed as? [String: Any])
        let entries = try #require(listDict["entries"] as? [[String: Any]])
        #expect(entries.contains(where: { ($0["path"] as? String) == "README.md" }))

        let read = try await h.runOK("read_project_context", args: [
            "action": "read",
            "path": "README.md",
        ])
        let readDict = try #require(read as? [String: Any])
        #expect((readDict["text"] as? String)?.contains("#ff5500") == true)
    }

    @Test func readProjectContextRequiresLinkedFolder() async {
        let h = ToolHarness()
        let result = await h.runRaw("read_project_context", args: ["action": "list"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("linked context"))
    }
}
