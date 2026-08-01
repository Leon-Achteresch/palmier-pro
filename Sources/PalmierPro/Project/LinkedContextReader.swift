import Foundation
import UniformTypeIdentifiers

enum LinkedContextReader {
    static let maxListEntries = 200
    static let maxTextBytes = 256_000
    static let maxImageBytes = 2_000_000
    static let defaultListDepth = 2
    static let maxListDepth = 6

    private static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", ".svn", ".hg",
        "node_modules", "Pods", "DerivedData",
        ".next", "dist", "build", "vendor",
        ".turbo", ".cache", "__pycache__", ".venv",
    ]

    private static let textExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "json", "jsonc", "md", "mdx", "txt", "csv",
        "css", "scss", "sass", "less",
        "html", "htm", "xml", "svg", "plist",
        "yml", "yaml", "toml", "ini", "env",
        "sh", "zsh", "bash", "py", "rb", "go", "rs",
        "kt", "java", "c", "h", "cpp", "hpp", "m", "mm",
        "graphql", "sql", "proto",
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic",
    ]

    enum ReadKind: String, Sendable {
        case text
        case image
        case binary
    }

    struct ListEntry: Sendable {
        let path: String
        let kind: String
        let byteSize: Int64?
    }

    struct ListResult: Sendable {
        let root: String
        let path: String
        let entries: [ListEntry]
        let truncated: Bool
        let accessible: Bool
    }

    struct TextRead: Sendable {
        let path: String
        let kind: ReadKind
        let text: String
        let byteSize: Int
        let truncated: Bool
    }

    struct ImageRead: Sendable {
        let path: String
        let kind: ReadKind
        let data: Data
        let mediaType: String
        let byteSize: Int
    }

    nonisolated static func list(rootPath: String, relativePath: String?, maxDepth: Int) throws -> ListResult {
        let root = try resolveRoot(rootPath)
        let base = try resolve(root: root, relativePath: relativePath)
        let depth = min(max(1, maxDepth), maxListDepth)
        var entries: [ListEntry] = []
        var truncated = false
        try walk(root: root, directory: base, depthRemaining: depth, entries: &entries, truncated: &truncated)
        entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return ListResult(
            root: root.path,
            path: relativePathString(of: base, under: root),
            entries: entries,
            truncated: truncated,
            accessible: true
        )
    }

    enum FileContent: Sendable {
        case text(TextRead)
        case image(ImageRead)
    }

    nonisolated static func read(rootPath: String, relativePath: String) throws -> FileContent {
        let root = try resolveRoot(rootPath)
        let url = try resolve(root: root, relativePath: relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw LinkedContextError.notFound(relativePath)
        }
        guard !isDir.boolValue else {
            throw LinkedContextError.isDirectory(relativePath)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let ext = url.pathExtension.lowercased()
        let rel = relativePathString(of: url, under: root)

        if textExtensions.contains(ext) || ext.isEmpty {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let limit = min(data.count, maxTextBytes)
            let slice = data.prefix(limit)
            guard let text = String(data: slice, encoding: .utf8)
                    ?? String(data: slice, encoding: .isoLatin1) else {
                throw LinkedContextError.unreadable(rel)
            }
            return .text(TextRead(
                path: rel,
                kind: .text,
                text: text,
                byteSize: size,
                truncated: data.count > maxTextBytes
            ))
        }

        if imageExtensions.contains(ext) {
            guard size <= maxImageBytes else {
                throw LinkedContextError.tooLarge(rel, size, maxImageBytes)
            }
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            return .image(ImageRead(
                path: rel,
                kind: .image,
                data: data,
                mediaType: mime,
                byteSize: size
            ))
        }

        throw LinkedContextError.unsupportedType(rel, ext)
    }

    enum LinkedContextError: LocalizedError {
        case missingRoot
        case rootNotDirectory(String)
        case notFound(String)
        case isDirectory(String)
        case outsideRoot
        case tooLarge(String, Int, Int)
        case unreadable(String)
        case unsupportedType(String, String)

        var errorDescription: String? {
            switch self {
            case .missingRoot:
                "No linked context folder is set for this project. Choose one in the Inspector (empty selection → Context)."
            case .rootNotDirectory(let path):
                "Linked context path is missing or not a folder: \(path)"
            case .notFound(let path):
                "Not found: \(path)"
            case .isDirectory(let path):
                "Path is a directory — use action='list' for \(path)"
            case .outsideRoot:
                "Path escapes the linked context folder."
            case .tooLarge(let path, let size, let max):
                "File too large to read (\(size) bytes > \(max)): \(path)"
            case .unreadable(let path):
                "Could not decode text for \(path)"
            case .unsupportedType(let path, let ext):
                "Unsupported file type.\(ext.isEmpty ? "" : " .\(ext)") for \(path). Read text sources, design tokens, or common image formats."
            }
        }
    }

    private nonisolated static func resolveRoot(_ rootPath: String) throws -> URL {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LinkedContextError.missingRoot }
        let root = URL(fileURLWithPath: trimmed).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw LinkedContextError.rootNotDirectory(root.path)
        }
        return root
    }

    private nonisolated static func resolve(root: URL, relativePath: String?) throws -> URL {
        let rel = (relativePath ?? ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate: URL
        if rel.isEmpty || rel == "." {
            candidate = root
        } else {
            candidate = root.appendingPathComponent(rel).standardizedFileURL
        }
        try ensureInside(root: root, url: candidate)
        return candidate
    }

    private nonisolated static func ensureInside(root: URL, url: URL) throws {
        let rootPath = root.path
        let path = url.path
        if path == rootPath { return }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { throw LinkedContextError.outsideRoot }
    }

    private nonisolated static func relativePathString(of url: URL, under root: URL) -> String {
        let rootPath = root.path
        let path = url.path
        if path == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }

    private nonisolated static func walk(
        root: URL,
        directory: URL,
        depthRemaining: Int,
        entries: inout [ListEntry],
        truncated: inout Bool
    ) throws {
        guard depthRemaining > 0, !truncated else { return }
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return
        }

        for url in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if entries.count >= maxListEntries {
                truncated = true
                return
            }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory == true
            if isDirectory, skippedDirectoryNames.contains(name) { continue }
            let rel = relativePathString(of: url.standardizedFileURL, under: root)
            if isDirectory {
                entries.append(ListEntry(path: rel, kind: "directory", byteSize: nil))
                try walk(
                    root: root,
                    directory: url.standardizedFileURL,
                    depthRemaining: depthRemaining - 1,
                    entries: &entries,
                    truncated: &truncated
                )
            } else {
                entries.append(ListEntry(
                    path: rel,
                    kind: "file",
                    byteSize: values?.fileSize.map(Int64.init)
                ))
            }
        }
    }
}
