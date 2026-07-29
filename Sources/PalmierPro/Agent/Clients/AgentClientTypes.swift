import Foundation

// MARK: - Shared value types

/// Chat models offered through OpenRouter.
enum AgentModel: String, CaseIterable, Sendable {
    case sonnet5 = "anthropic/claude-sonnet-5"
    case opus5 = "anthropic/claude-opus-5"
    case gpt55 = "openai/gpt-5.5"
    case gemini36Flash = "google/gemini-3.6-flash"
    case grok45 = "x-ai/grok-4.5"

    var displayName: String {
        switch self {
        case .sonnet5: "Claude Sonnet 5"
        case .opus5: "Claude Opus 5"
        case .gpt55: "GPT-5.5"
        case .gemini36Flash: "Gemini 3.6 Flash"
        case .grok45: "Grok 4.5"
        }
    }
}

enum AnthropicStopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case other
}

/// One turn in Anthropic content-block form; the client translates it to its wire format.
struct AnthropicMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [[String: Any]]
}

struct AnthropicToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum AnthropicStreamEvent: Sendable {
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case messageStop(stopReason: AnthropicStopReason)
}

enum AgentStreamError: LocalizedError {
    case missingKey
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your OpenRouter API key in Settings › Agent to use AI chat."
        case .upstream(let message): message
        }
    }

    static func from(status: Int, body: String) -> AgentStreamError {
        if status == 401 || status == 403 { return .missingKey }
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return .upstream(body.isEmpty ? "OpenRouter error (HTTP \(status))" : String(body.prefix(500)))
        }
        return .upstream(message)
    }
}

// MARK: - Client protocol

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
}

// MARK: - Usage logging

enum AgentUsageLog {
    static func record(promptTokens: Int, completionTokens: Int) {
        #if DEBUG
        print("[agent usage] prompt=\(promptTokens) completion=\(completionTokens)")
        #endif
    }
}
