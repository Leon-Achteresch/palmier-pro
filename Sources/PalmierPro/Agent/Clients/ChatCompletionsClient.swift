import Foundation

/// Streams a turn from OpenRouter or Google AI on the user's own key.
struct ChatCompletionsClient: AgentClient {
    let provider: AgentProvider
    let apiKey: String
    let settings: AgentRunSettings

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeAgentStream { continuation in
            try await run(system: system, tools: tools, messages: messages, continuation: continuation)
        }
    }

    private func run(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        guard !apiKey.isEmpty else { throw AgentClientTransportError.missingAPIKey(provider) }

        var request = URLRequest(url: provider.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if provider == .openRouter {
            request.setValue("https://palmier.io", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Palmier Pro", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ChatCompletionsRequestBody.build(
                provider: provider,
                settings: settings,
                system: system,
                tools: tools,
                messages: messages
            ),
            options: [.sortedKeys]
        )

        let bytes = try await AgentHTTP.bytes(for: request) { status, body in
            AgentClientTransportError.httpError(provider: provider, status: status, body: body)
        }
        var parser = ChatCompletionsStreamParser(provider: provider)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try parser.consume(line: line) {
                continuation.yield(event)
            }
        }
        for event in parser.finish() {
            continuation.yield(event)
        }
    }
}

enum ChatCompletionsRequestBody {
    static func build(
        provider: AgentProvider,
        settings: AgentRunSettings,
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> [String: Any] {
        let modelId = settings.model.providerModelId
        var body: [String: Any] = [
            "model": modelId,
            "stream": true,
            "messages": [["role": "system", "content": system]] + chatMessages(messages),
        ]
        if !tools.isEmpty {
            let sanitize = provider == .google || GeminiSchemaSanitizer.applies(to: modelId)
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": sanitize
                            ? GeminiSchemaSanitizer.sanitize(tool.inputSchema)
                            : tool.inputSchema,
                    ],
                ]
            }
        }
        if let effort = effortValue(settings.reasoningEffort) {
            switch provider {
            case .openRouter: body["reasoning"] = ["effort": effort]
            case .google: body["reasoning_effort"] = effort
            }
        }
        return body
    }

    private static func effortValue(_ effort: AgentReasoningEffort) -> String? {
        switch effort {
        case .none: nil
        case .minimal, .low: "low"
        case .medium: "medium"
        case .high, .xHigh, .max: "high"
        }
    }

    private static func chatMessages(_ messages: [AgentRequestMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            var textParts: [String] = []
            var contentParts: [[String: Any]] = []
            var toolCalls: [[String: Any]] = []
            var toolMessages: [[String: Any]] = []
            var toolResultImages: [[String: Any]] = []

            for block in message.content {
                switch block {
                case .image(let base64, let mediaType):
                    contentParts.append(imagePart(base64: base64, mediaType: mediaType))
                case .content(let content):
                    switch content {
                    case .thinking:
                        continue
                    case .text(let text):
                        guard !text.isEmpty else { continue }
                        textParts.append(text)
                        contentParts.append(["type": "text", "text": text])
                    case .toolUse(let id, let name, let inputJSON):
                        toolCalls.append([
                            "id": id,
                            "type": "function",
                            "function": ["name": name, "arguments": normalizedJSON(inputJSON)],
                        ])
                    case .toolResult(let toolUseID, let output, let isError):
                        var text = output.compactMap { block -> String? in
                            if case .text(let value) = block { return value }
                            return nil
                        }.joined(separator: "\n")
                        for case .image(let base64, let mediaType) in output {
                            toolResultImages.append(imagePart(base64: base64, mediaType: mediaType))
                        }
                        if isError { text = "Tool error: " + text }
                        toolMessages.append([
                            "role": "tool",
                            "tool_call_id": toolUseID,
                            "content": text.isEmpty ? (isError ? "Tool error" : "OK") : text,
                        ])
                    }
                }
            }

            switch message.role {
            case .assistant:
                if !textParts.isEmpty || !toolCalls.isEmpty {
                    var item: [String: Any] = ["role": "assistant", "content": textParts.joined(separator: "\n")]
                    if !toolCalls.isEmpty { item["tool_calls"] = toolCalls }
                    items.append(item)
                }
            case .user:
                if !contentParts.isEmpty {
                    items.append(["role": "user", "content": contentParts])
                }
            }
            items.append(contentsOf: toolMessages)
            // Chat completions tool results carry text only; images follow as a user turn.
            if !toolResultImages.isEmpty {
                items.append(["role": "user", "content": toolResultImages])
            }
        }
        return items
    }

    private static func imagePart(base64: String, mediaType: String) -> [String: Any] {
        ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(base64)"]]
    }

    private static func normalizedJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: normalized, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

struct ChatCompletionsStreamParser {
    let provider: AgentProvider

    private var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var stopReason: AgentStopReason = .endTurn
    private var didStop = false

    init(provider: AgentProvider) {
        self.provider = provider
    }

    mutating func consume(line: String) throws -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return [] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentClientTransportError.streamError(provider: provider, message: "Invalid event payload.")
        }
        if let error = object["error"] as? [String: Any] {
            throw AgentClientTransportError.streamError(
                provider: provider,
                message: error["message"] as? String ?? "Unknown stream error."
            )
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return [] }

        var events: [AgentStreamEvent] = []
        if let delta = choice["delta"] as? [String: Any] {
            if let reasoning = reasoningText(delta), !reasoning.isEmpty {
                events.append(.thinkingDelta(reasoning))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.textDelta(content))
            } else if let parts = delta["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { events.append(.textDelta(text)) }
            }
            accumulateToolCalls(delta["tool_calls"] as? [[String: Any]])
        }
        if let finish = choice["finish_reason"] as? String {
            didStop = true
            stopReason = Self.stopReason(finish, hasToolCalls: !toolCalls.isEmpty)
        }
        return events
    }

    mutating func finish() -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = toolCalls.sorted { $0.key < $1.key }.map { _, call in
            .toolUseComplete(
                id: call.id,
                name: call.name,
                inputJSON: call.arguments.isEmpty ? "{}" : call.arguments
            )
        }
        if !didStop, !toolCalls.isEmpty { stopReason = .toolUse }
        events.append(.messageStop(stopReason: didStop || !toolCalls.isEmpty ? stopReason : .other))
        return events
    }

    private func reasoningText(_ delta: [String: Any]) -> String? {
        if let text = delta["reasoning"] as? String { return text }
        if let text = delta["reasoning_content"] as? String { return text }
        if let details = delta["reasoning_details"] as? [[String: Any]] {
            let text = details.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private mutating func accumulateToolCalls(_ calls: [[String: Any]]?) {
        guard let calls else { return }
        for call in calls {
            let index = call["index"] as? Int ?? toolCalls.count
            var entry = toolCalls[index] ?? (id: "", name: "", arguments: "")
            if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
            if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                if let arguments = function["arguments"] as? String { entry.arguments += arguments }
            }
            if entry.id.isEmpty { entry.id = "call_\(index)" }
            toolCalls[index] = entry
        }
    }

    private static func stopReason(_ finish: String, hasToolCalls: Bool) -> AgentStopReason {
        switch finish {
        case "tool_calls", "function_call": .toolUse
        case "length", "max_tokens": .maxTokens
        case "content_filter": .refusal
        default: hasToolCalls ? .toolUse : .endTurn
        }
    }
}
