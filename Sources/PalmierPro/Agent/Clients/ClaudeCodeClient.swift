import Foundation

struct ClaudeCodeClient: Sendable {
    let workingDirectory: URL?
    let mcpPort: UInt16
    let resumeSessionId: String?
    let model: String?
    let effort: AgentReasoningEffort?

    enum Event: Sendable {
        case sessionId(String)
        case textDelta(String)
        case assistantBlocks([AgentContentBlock])
        case toolResults([AgentContentBlock])
        case failed(String)
    }

    func stream(prompt: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await run(prompt: prompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        prompt: String,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command + " 2>&1"]
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout

        let (exitStatuses, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }

        try process.run()
        let pid = process.processIdentifier

        try await withTaskCancellationHandler {
            let writer = stdin.fileHandleForWriting
            try? writer.write(contentsOf: Data(prompt.utf8))
            try? writer.close()

            var sawResult = false
            var unparsedTail = ""
            for try await line in stdout.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                guard let object = Self.jsonObject(from: line) else {
                    unparsedTail = String((unparsedTail + line + "\n").suffix(2000))
                    continue
                }
                if object["type"] as? String == "result" { sawResult = true }
                for event in Self.events(from: object) {
                    continuation.yield(event)
                }
            }

            var status: Int32 = 0
            for await exitStatus in exitStatuses { status = exitStatus }
            if status != 0, !sawResult {
                throw AgentStreamError.upstream(Self.failureMessage(status: status, output: unparsedTail))
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }
    }

    private var command: String {
        var parts = [
            "claude -p --output-format stream-json --include-partial-messages --verbose",
            "--allowedTools mcp__palmier-pro,Skill,Read,Glob",
            "--mcp-config \(mcpConfigJSON.singleQuotedForShell)",
        ]
        if let model {
            parts.append("--model \(model.singleQuotedForShell)")
        }
        if let effort {
            parts.append("--effort \(effort.rawValue)")
        }
        if let resumeSessionId {
            parts.append("--resume \(resumeSessionId.singleQuotedForShell)")
        }
        return parts.joined(separator: " ")
    }

    private var mcpConfigJSON: String {
        "{\"mcpServers\":{\"palmier-pro\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:\(mcpPort)/mcp\"}}}"
    }

    private static func failureMessage(status: Int32, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 127 || trimmed.contains("command not found") {
            return "Claude Code CLI not found. Install it (npm install -g @anthropic-ai/claude-code) and sign in from a terminal first."
        }
        return trimmed.isEmpty ? "Claude Code exited with status \(status)." : String(trimmed.suffix(500))
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func events(from object: [String: Any]) -> [Event] {
        switch object["type"] as? String {
        case "system":
            guard object["subtype"] as? String == "init",
                  let id = object["session_id"] as? String else { return [] }
            return [.sessionId(id)]
        case "stream_event":
            guard object["parent_tool_use_id"] is NSNull || object["parent_tool_use_id"] == nil,
                  let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case "assistant":
            let isSubagent = !(object["parent_tool_use_id"] is NSNull || object["parent_tool_use_id"] == nil)
            let blocks = assistantBlocks(in: object, includeText: isSubagent)
            return blocks.isEmpty ? [] : [.assistantBlocks(blocks)]
        case "user":
            let results = toolResultBlocks(in: object)
            return results.isEmpty ? [] : [.toolResults(results)]
        case "result":
            guard let subtype = object["subtype"] as? String, subtype != "success" else { return [] }
            let message = (object["result"] as? String)
                ?? (object["errorMessage"] as? String)
                ?? "Claude Code failed (\(subtype))."
            return [.failed(message)]
        default:
            return []
        }
    }

    private static func assistantBlocks(in object: [String: Any], includeText: Bool) -> [AgentContentBlock] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        var blocks: [AgentContentBlock] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if includeText, let text = block["text"] as? String, !text.isEmpty {
                    blocks.append(.text(text))
                }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { break }
                let input = block["input"] as? [String: Any] ?? [:]
                let json = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                blocks.append(.toolUse(id: id, name: name, inputJSON: json))
            default:
                break
            }
        }
        return blocks
    }

    private static func toolResultBlocks(in object: [String: Any]) -> [AgentContentBlock] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        var results: [AgentContentBlock] = []
        for block in content where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String else { continue }
            results.append(.toolResult(
                toolUseId: id,
                content: resultContent(block["content"]),
                isError: block["is_error"] as? Bool ?? false
            ))
        }
        return results
    }

    private static func resultContent(_ raw: Any?) -> [ToolResult.Block] {
        if let text = raw as? String {
            return [.text(text)]
        }
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            switch entry["type"] as? String {
            case "text":
                return (entry["text"] as? String).map(ToolResult.Block.text)
            case "image":
                guard let source = entry["source"] as? [String: Any],
                      let data = source["data"] as? String else { return nil }
                return .image(base64: data, mediaType: source["media_type"] as? String ?? "image/png")
            default:
                return nil
            }
        }
    }
}
