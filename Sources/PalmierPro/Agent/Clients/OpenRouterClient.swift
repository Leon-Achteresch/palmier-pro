import Foundation

/// Streams the agent loop through OpenRouter's OpenAI-compatible chat API.
struct OpenRouterClient: AgentClient {
    let apiKey: String
    let model: AgentModel
    var reasoningEffort: AgentReasoningEffort?
    var maxTokens: Int = 8192

    private static let endpoint = OpenRouterAPI.baseURL.appending(path: "chat/completions")

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AgentStreamError.missingKey }

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": [systemMessage(system)] + OpenRouterMessageConverter.convert(messages),
        ]
        if let reasoningEffort {
            body["reasoning"] = [
                "effort": reasoningEffort.rawValue,
                "exclude": true,
            ]
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ],
                ]
            }
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue("Palmier Pro", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line + "\n" }
            throw AgentStreamError.from(status: http.statusCode, body: errorBody)
        }

        try await OpenRouterSSE.parse(bytes: bytes, continuation: continuation)
    }

    /// Anthropic models bill cached prefixes only with an explicit breakpoint; other providers cache on their own.
    private func systemMessage(_ system: String) -> [String: Any] {
        guard model.id.hasPrefix("anthropic/") else {
            return ["role": "system", "content": system]
        }
        return [
            "role": "system",
            "content": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
        ]
    }
}

/// Anthropic content blocks -> OpenAI chat messages.
enum OpenRouterMessageConverter {
    static func convert(_ messages: [AnthropicMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .assistant: out.append(contentsOf: assistantMessages(message.content))
            case .user: out.append(contentsOf: userMessages(message.content))
            }
        }
        return out
    }

    private static func assistantMessages(_ blocks: [[String: Any]]) -> [[String: Any]] {
        var text = ""
        var toolCalls: [[String: Any]] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { break }
                let input = block["input"] as? [String: Any] ?? [:]
                let arguments = (try? JSONSerialization.data(withJSONObject: input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": arguments],
                ])
            default: break
            }
        }
        guard !text.isEmpty || !toolCalls.isEmpty else { return [] }
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !toolCalls.isEmpty { message["tool_calls"] = toolCalls }
        return [message]
    }

    private static func userMessages(_ blocks: [[String: Any]]) -> [[String: Any]] {
        var toolMessages: [[String: Any]] = []
        var parts: [[String: Any]] = []

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
            case "image":
                if let part = imagePart(block) { parts.append(part) }
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { break }
                let content = block["content"] as? [[String: Any]] ?? []
                var resultText = ""
                for entry in content {
                    switch entry["type"] as? String {
                    case "text":
                        resultText += entry["text"] as? String ?? ""
                    case "image":
                        // OpenAI tool messages are text-only; images ride along as a user part.
                        if let part = imagePart(entry) { parts.append(part) }
                    default: break
                    }
                }
                if resultText.isEmpty, !parts.isEmpty { resultText = "See the attached image." }
                toolMessages.append([
                    "role": "tool",
                    "tool_call_id": id,
                    "content": resultText.isEmpty ? "(no output)" : resultText,
                ])
            default: break
            }
        }

        var out = toolMessages
        if !parts.isEmpty { out.append(["role": "user", "content": parts]) }
        return out
    }

    private static func imagePart(_ block: [String: Any]) -> [String: Any]? {
        guard let source = block["source"] as? [String: Any],
              let mime = source["media_type"] as? String,
              let data = source["data"] as? String else { return nil }
        return OpenRouterAPI.imageContentPart("data:\(mime);base64,\(data)")
    }
}

enum OpenRouterSSE {
    static func parse(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        var pendingCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var stopReason: AnthropicStopReason?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = event["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "OpenRouter stream error"
                continuation.finish(throwing: AgentStreamError.upstream(message))
                return
            }
            if let usage = event["usage"] as? [String: Any] {
                AgentUsageLog.record(
                    promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                    completionTokens: usage["completion_tokens"] as? Int ?? 0
                )
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }

            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    var accumulated = pendingCalls[index] ?? (id: "", name: "", arguments: "")
                    if let id = call["id"] as? String, !id.isEmpty { accumulated.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty { accumulated.name = name }
                        if let arguments = function["arguments"] as? String { accumulated.arguments += arguments }
                    }
                    pendingCalls[index] = accumulated
                }
            }
            if let reason = choice["finish_reason"] as? String {
                stopReason = switch reason {
                case "tool_calls", "function_call": .toolUse
                case "length": .maxTokens
                case "content_filter": .refusal
                default: .endTurn
                }
            }
        }

        for (_, call) in pendingCalls.sorted(by: { $0.key < $1.key }) where !call.name.isEmpty {
            let arguments = call.arguments.isEmpty ? "{}" : call.arguments
            let id = call.id.isEmpty ? UUID().uuidString : call.id
            continuation.yield(.toolUseComplete(id: id, name: call.name, inputJSON: arguments))
        }
        let resolved = pendingCalls.isEmpty ? (stopReason ?? .endTurn) : .toolUse
        continuation.yield(.messageStop(stopReason: resolved))
    }
}
