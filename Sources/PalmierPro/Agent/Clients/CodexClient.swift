import Foundation

struct CodexClient: CLIAgentClient {
    let workingDirectory: URL?
    let mcpPort: UInt16
    let resumeSessionId: String?
    let model: String?
    let effort: AgentReasoningEffort?

    var command: String {
        var parts = ["codex exec"]
        if let resumeSessionId {
            parts.append("resume \(resumeSessionId.singleQuotedForShell)")
        }
        parts.append(contentsOf: [
            "--json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox",
            "-c \(mcpServerConfig.singleQuotedForShell)",
        ])
        if let model {
            parts.append("-m \(model.singleQuotedForShell)")
        }
        if let effort {
            parts.append("-c \("model_reasoning_effort=\"\(effort.rawValue)\"".singleQuotedForShell)")
        }
        parts.append("-")
        return parts.joined(separator: " ")
    }

    private var mcpServerConfig: String {
        "mcp_servers.palmier-pro.url=\"http://127.0.0.1:\(mcpPort)/mcp\""
    }

    static func isTerminal(_ object: [String: Any]) -> Bool {
        object["type"] as? String == "turn.completed"
    }

    static func failureMessage(status: Int32, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 127 || trimmed.contains("command not found") {
            return "Codex CLI not found. Install it (npm install -g @openai/codex) and run `codex login` in a terminal first."
        }
        return trimmed.isEmpty ? "Codex exited with status \(status)." : String(trimmed.suffix(500))
    }

    static func events(from object: [String: Any]) -> [CLIAgentEvent] {
        switch object["type"] as? String {
        case "thread.started":
            guard let id = object["thread_id"] as? String else { return [] }
            return [.sessionId(id)]
        case "item.started":
            guard let item = object["item"] as? [String: Any],
                  let block = toolUseBlock(item) else { return [] }
            return [.assistantBlocks([block])]
        case "item.completed":
            guard let item = object["item"] as? [String: Any] else { return [] }
            if item["type"] as? String == "agent_message" {
                guard let text = item["text"] as? String, !text.isEmpty else { return [] }
                return [.assistantBlocks([.text(text)])]
            }
            if item["type"] as? String == "error" {
                return [.failed(item["message"] as? String ?? "Codex failed.")]
            }
            guard let block = toolResultBlock(item) else { return [] }
            return [.toolResults([block])]
        case "turn.failed", "error":
            let error = object["error"] as? [String: Any]
            let message = (error?["message"] as? String)
                ?? (object["message"] as? String)
                ?? "Codex failed."
            return [.failed(message)]
        default:
            return []
        }
    }

    private static func toolUseBlock(_ item: [String: Any]) -> AgentContentBlock? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String {
        case "mcp_tool_call":
            guard let server = item["server"] as? String, let tool = item["tool"] as? String else { return nil }
            return .toolUse(id: id, name: "mcp__\(server)__\(tool)", inputJSON: CLIAgentJSON.string(from: item["arguments"]))
        case "command_execution":
            guard let command = item["command"] as? String else { return nil }
            return .toolUse(id: id, name: "Bash", inputJSON: CLIAgentJSON.string(from: ["command": command]))
        case "file_change":
            return .toolUse(id: id, name: "Edit", inputJSON: CLIAgentJSON.string(from: item["changes"]))
        case "web_search":
            return .toolUse(id: id, name: "WebSearch", inputJSON: CLIAgentJSON.string(from: ["query": item["query"] ?? ""]))
        default:
            return nil
        }
    }

    private static func toolResultBlock(_ item: [String: Any]) -> AgentContentBlock? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String {
        case "mcp_tool_call":
            let error = (item["error"] as? [String: Any])?["message"] as? String
            let failed = error != nil || item["status"] as? String == "failed"
            let content = error.map { [ToolResult.Block.text($0)] } ?? resultContent(item["result"])
            return .toolResult(toolUseId: id, content: content, isError: failed)
        case "command_execution":
            let output = item["aggregated_output"] as? String ?? ""
            let exitCode = item["exit_code"] as? Int
            return .toolResult(toolUseId: id, content: [.text(output)], isError: exitCode != 0)
        case "file_change", "web_search":
            return .toolResult(
                toolUseId: id,
                content: [.text(CLIAgentJSON.string(from: item))],
                isError: item["status"] as? String == "failed"
            )
        default:
            return nil
        }
    }

    private static func resultContent(_ raw: Any?) -> [ToolResult.Block] {
        guard let raw else { return [] }
        let entries = (raw as? [String: Any])?["content"] as? [[String: Any]] ?? raw as? [[String: Any]]
        guard let entries else { return [.text(CLIAgentJSON.string(from: raw))] }
        return entries.compactMap { entry in
            switch entry["type"] as? String {
            case "text":
                return (entry["text"] as? String).map(ToolResult.Block.text)
            case "image":
                guard let data = entry["data"] as? String else { return nil }
                return .image(base64: data, mediaType: entry["mimeType"] as? String ?? "image/png")
            default:
                return nil
            }
        }
    }
}
