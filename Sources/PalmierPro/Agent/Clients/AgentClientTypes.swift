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
        cliVariant("claude-code", "claude-fable-5", "Fable 5"),
        cliVariant("claude-code", "claude-opus-5", "Opus 5"),
        cliVariant("claude-code", "claude-sonnet-5", "Sonnet 5"),
        cliVariant("claude-code", "claude-haiku-4-5-20251001", "Haiku 4.5"),
    ]

    static let codex = AgentModel(
        id: "codex",
        name: "Codex",
        supportedEfforts: [.xhigh, .high, .medium, .low],
        defaultEffort: .medium
    )

    static let codexCatalog: [AgentModel] = [
        codex,
        cliVariant("codex", "gpt-5.6-sol", "GPT-5.6 Sol"),
        cliVariant("codex", "gpt-5.6-terra", "GPT-5.6 Terra"),
        cliVariant("codex", "gpt-5.6-luna", "GPT-5.6 Luna"),
        cliVariant("codex", "gpt-5.5", "GPT-5.5"),
        cliVariant("codex", "gpt-5.4", "GPT-5.4"),
    ]

    private static func cliVariant(_ cli: String, _ model: String, _ name: String) -> AgentModel {
        let base = cli == "codex" ? codex : claudeCode
        return AgentModel(
            id: "\(cli)/\(model)",
            name: name,
            supportedEfforts: base.supportedEfforts,
            defaultEffort: base.defaultEffort
        )
    }

    var isClaudeCode: Bool { id == AgentModel.claudeCode.id || id.hasPrefix("claude-code/") }

    var isCodex: Bool { id == AgentModel.codex.id || id.hasPrefix("codex/") }

    var isCLIAgent: Bool { isClaudeCode || isCodex }

    var claudeCodeModelId: String? { cliModelId(prefix: "claude-code/") }

    var codexModelId: String? { cliModelId(prefix: "codex/") }

    private func cliModelId(prefix: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    /// Menu group the model is listed under.
    var provider: String {
        if isClaudeCode { return "Claude Code" }
        if isCodex { return "Codex" }
        guard let vendor = id.split(separator: "/").first, id.contains("/") else { return "Other" }
        return Self.vendorNames[String(vendor)] ?? String(vendor).capitalized
    }

    private static let vendorNames = [
        "openai": "OpenAI",
        "x-ai": "xAI",
        "meta-llama": "Meta",
        "mistralai": "Mistral",
        "deepseek": "DeepSeek",
        "z-ai": "Z.ai",
    ]

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
