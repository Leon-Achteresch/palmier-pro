import Foundation

extension ToolExecutor {
    private static let readProjectContextAllowedKeys: Set<String> = ["action", "path", "maxDepth"]

    func readProjectContext(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.readProjectContextAllowedKeys, path: "read_project_context")
        guard let action = args.string("action") else {
            throw ToolError("read_project_context requires action ('list' or 'read').")
        }
        guard let root = editor.linkedContextPath, !root.isEmpty else {
            throw ToolError(LinkedContextReader.LinkedContextError.missingRoot.localizedDescription)
        }

        switch action {
        case "list":
            let relative = args.string("path")
            let depth = args.int("maxDepth") ?? LinkedContextReader.defaultListDepth
            let listed = try await Task.detached(priority: .utility) {
                try LinkedContextReader.list(rootPath: root, relativePath: relative, maxDepth: depth)
            }.value
            var payload: [String: Any] = [
                "root": listed.root,
                "path": listed.path,
                "accessible": listed.accessible,
                "truncated": listed.truncated,
                "entries": listed.entries.map { entry -> [String: Any] in
                    var row: [String: Any] = ["path": entry.path, "kind": entry.kind]
                    if let size = entry.byteSize { row["byteSize"] = size }
                    return row
                },
            ]
            if listed.truncated {
                payload["note"] = "Listing truncated at \(LinkedContextReader.maxListEntries) entries — narrow path or reduce maxDepth."
            }
            guard let json = Self.jsonString(payload) else {
                throw ToolError("Failed to encode linked context listing.")
            }
            return .ok(json)

        case "read":
            guard let relative = args.string("path"), !relative.isEmpty else {
                throw ToolError("read_project_context action='read' requires path.")
            }
            let result = try await Task.detached(priority: .utility) {
                try LinkedContextReader.read(rootPath: root, relativePath: relative)
            }.value
            switch result {
            case .text(let file):
                var payload: [String: Any] = [
                    "path": file.path,
                    "kind": file.kind.rawValue,
                    "byteSize": file.byteSize,
                    "truncated": file.truncated,
                    "text": file.text,
                ]
                if file.truncated {
                    payload["note"] = "Text truncated at \(LinkedContextReader.maxTextBytes) bytes."
                }
                guard let json = Self.jsonString(payload) else {
                    throw ToolError("Failed to encode linked context file.")
                }
                return .ok(json)
            case .image(let file):
                let meta: [String: Any] = [
                    "path": file.path,
                    "kind": file.kind.rawValue,
                    "byteSize": file.byteSize,
                    "mediaType": file.mediaType,
                ]
                guard let metaJSON = Self.jsonString(meta) else {
                    throw ToolError("Failed to encode linked context image metadata.")
                }
                return ToolResult(
                    content: [
                        .image(base64: file.data.base64EncodedString(), mediaType: file.mediaType),
                        .text(metaJSON),
                    ],
                    isError: false
                )
            }

        default:
            throw ToolError("read_project_context action must be 'list' or 'read'.")
        }
    }
}
