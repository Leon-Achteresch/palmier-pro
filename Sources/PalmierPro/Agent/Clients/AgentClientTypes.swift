import Foundation

// MARK: - Shared value types

enum AgentReasoningEffort: String, CaseIterable, Sendable {
    case max
    case xhigh
    case high
    case medium
    case low
    case minimal
    case none

    var displayName: String {
        switch self {
        case .max: "Max"
        case .xhigh: "Extra high"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .minimal: "Minimal"
        case .none: "Off"
        }
    }
}

struct AgentModel: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let supportedEfforts: [AgentReasoningEffort]
    let defaultEffort: AgentReasoningEffort?
    let reasoningMandatory: Bool

    var displayName: String { name }
    var supportsReasoningEffort: Bool { !supportedEfforts.isEmpty }

    init(
        id: String,
        name: String,
        supportedEfforts: [AgentReasoningEffort] = [],
        defaultEffort: AgentReasoningEffort? = nil,
        reasoningMandatory: Bool = false
    ) {
        self.id = id
        self.name = name
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.reasoningMandatory = reasoningMandatory
    }

    static let claudeCode = AgentModel(
        id: "claude-code",
        name: "Claude Code",
        supportedEfforts: [.xhigh, .high, .medium, .low],
        defaultEffort: .high
    )

    static let claudeCodeCatalog: [AgentModel] = [
        claudeCode,
        claudeCodeVariant("claude-fable-5", "Claude Code · Fable 5"),
        claudeCodeVariant("claude-opus-5", "Claude Code · Opus 5"),
        claudeCodeVariant("claude-sonnet-5", "Claude Code · Sonnet 5"),
        claudeCodeVariant("claude-haiku-4-5-20251001", "Claude Code · Haiku 4.5"),
    ]

    private static func claudeCodeVariant(_ model: String, _ name: String) -> AgentModel {
        AgentModel(
            id: "claude-code/\(model)",
            name: name,
            supportedEfforts: claudeCode.supportedEfforts,
            defaultEffort: claudeCode.defaultEffort
        )
    }

    var isClaudeCode: Bool { id == AgentModel.claudeCode.id || id.hasPrefix("claude-code/") }

    var claudeCodeModelId: String? {
        guard id.hasPrefix("claude-code/") else { return nil }
        return String(id.dropFirst("claude-code/".count))
    }

    static let fallback = AgentModel(
        id: "anthropic/claude-sonnet-5",
        name: "Claude Sonnet 5",
        supportedEfforts: [.max, .xhigh, .high, .medium, .low],
        defaultEffort: .high
    )

    static let fallbackCatalog: [AgentModel] = [
        fallback,
        AgentModel(
            id: "anthropic/claude-opus-5",
            name: "Claude Opus 5",
            supportedEfforts: [.max, .xhigh, .high, .medium, .low],
            defaultEffort: .high
        ),
        AgentModel(
            id: "openai/gpt-5.5",
            name: "GPT-5.5",
            supportedEfforts: [.xhigh, .high, .medium, .low, .none],
            defaultEffort: .medium
        ),
        AgentModel(id: "google/gemini-3.6-flash", name: "Gemini 3.6 Flash"),
        AgentModel(id: "x-ai/grok-4.5", name: "Grok 4.5"),
    ]
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
