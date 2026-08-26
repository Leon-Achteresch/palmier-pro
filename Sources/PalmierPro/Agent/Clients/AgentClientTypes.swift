import Foundation

extension Notification.Name {
    static let agentAPIKeyChanged = Notification.Name("agentAPIKeyChanged")
}

enum AgentProvider: String, CaseIterable, Sendable {
    case openRouter
    case google

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .google: "Google AI"
        }
    }

    /// Both providers speak the OpenAI chat-completions dialect, so one client serves them.
    var chatCompletionsURL: URL {
        switch self {
        case .openRouter:
            URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .google:
            URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        }
    }

    @concurrent
    func loadAPIKey() async -> String {
        switch self {
        case .openRouter: OpenRouterKeychain.load() ?? ""
        case .google: GeminiKeychain.load() ?? ""
        }
    }

    @concurrent
    func setAPIKey(_ key: String?) async {
        switch self {
        case .openRouter:
            if let key { OpenRouterKeychain.save(key) } else { OpenRouterKeychain.delete() }
        case .google:
            if let key { GeminiKeychain.save(key) } else { GeminiKeychain.delete() }
        }
        NotificationCenter.default.post(name: .agentAPIKeyChanged, object: rawValue)
    }
}

enum AgentReasoningEffort: String, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xHigh = "xhigh"
    case max

    var labelKey: String {
        switch self {
        case .none: L10n.key("None")
        case .minimal: L10n.key("Minimal")
        case .low: L10n.key("Low")
        case .medium: L10n.key("Medium")
        case .high: L10n.key("High")
        case .xHigh: L10n.key("X High")
        case .max: L10n.key("Max")
        }
    }
}

/// A chat model the user can run: an OpenRouter slug, a Google model, or a local CLI agent.
struct AgentModel: Hashable, Sendable, Identifiable {
    let rawValue: String
    let displayName: String
    let supportedReasoningEfforts: [AgentReasoningEffort]

    var id: String { rawValue }

    init(
        rawValue: String,
        displayName: String? = nil,
        supportedReasoningEfforts: [AgentReasoningEffort] = AgentModel.defaultEfforts
    ) {
        self.rawValue = rawValue
        self.displayName = displayName ?? AgentModel.derivedDisplayName(rawValue)
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }

    static let defaultEfforts: [AgentReasoningEffort] = [.low, .medium, .high]
    static let cliEfforts: [AgentReasoningEffort] = [.low, .medium, .high, .xHigh]

    static let openRouterPrefix = "openrouter:"
    static let googlePrefix = "google:"

    static let claudeCode = AgentModel(
        rawValue: "claude-code",
        displayName: "Claude Code",
        supportedReasoningEfforts: cliEfforts
    )
    static let codex = AgentModel(
        rawValue: "codex",
        displayName: "Codex",
        supportedReasoningEfforts: cliEfforts
    )
    static let cliModels: [AgentModel] = [claudeCode, codex]
    static let defaultModel = claudeCode

    static func openRouter(
        id: String,
        name: String? = nil,
        efforts: [AgentReasoningEffort] = defaultEfforts
    ) -> AgentModel {
        AgentModel(
            rawValue: openRouterPrefix + id,
            displayName: name ?? id,
            supportedReasoningEfforts: efforts
        )
    }

    static func google(id: String, name: String? = nil) -> AgentModel {
        AgentModel(
            rawValue: googlePrefix + id,
            displayName: name ?? id,
            supportedReasoningEfforts: defaultEfforts
        )
    }

    var provider: AgentProvider? {
        if rawValue.hasPrefix(Self.openRouterPrefix) { return .openRouter }
        if rawValue.hasPrefix(Self.googlePrefix) { return .google }
        return nil
    }

    /// The id the provider expects in the request body.
    var providerModelId: String {
        guard let provider else { return rawValue }
        switch provider {
        case .openRouter: return String(rawValue.dropFirst(Self.openRouterPrefix.count))
        case .google: return String(rawValue.dropFirst(Self.googlePrefix.count))
        }
    }

    var isClaudeCode: Bool { rawValue == "claude-code" || rawValue.hasPrefix("claude-code/") }
    var isCodex: Bool { rawValue == "codex" || rawValue.hasPrefix("codex/") }
    var isCLIAgent: Bool { isClaudeCode || isCodex }

    var claudeCodeModelId: String? { cliModelId(prefix: "claude-code/") }
    var codexModelId: String? { cliModelId(prefix: "codex/") }

    private func cliModelId(prefix: String) -> String? {
        guard rawValue.hasPrefix(prefix) else { return nil }
        return String(rawValue.dropFirst(prefix.count))
    }

    private static func derivedDisplayName(_ rawValue: String) -> String {
        if rawValue.hasPrefix(openRouterPrefix) { return String(rawValue.dropFirst(openRouterPrefix.count)) }
        if rawValue.hasPrefix(googlePrefix) { return String(rawValue.dropFirst(googlePrefix.count)) }
        return rawValue
    }
}

struct AgentRunSettings: Equatable, Sendable {
    let model: AgentModel
    let reasoningEffort: AgentReasoningEffort
}

enum AgentReasoningPreferences {
    static func effort(for model: AgentModel, defaults: UserDefaults) -> AgentReasoningEffort {
        guard let rawValue = defaults.string(forKey: key("effort", model: model)),
              let effort = AgentReasoningEffort(rawValue: rawValue),
              model.supportedReasoningEfforts.contains(effort)
        else { return .medium }
        return effort
    }

    static func set(_ effort: AgentReasoningEffort, for model: AgentModel, defaults: UserDefaults) {
        defaults.set(effort.rawValue, forKey: key("effort", model: model))
    }

    private static func key(_ setting: String, model: AgentModel) -> String {
        "agentReasoning.\(setting).\(model.rawValue)"
    }
}

struct AgentCredentialSnapshot: Equatable, Sendable {
    private let apiKeys: [AgentProvider: String]

    init(_ apiKeys: [AgentProvider: String] = [:]) {
        self.apiKeys = apiKeys
    }

    subscript(provider: AgentProvider) -> String {
        apiKeys[provider, default: ""]
    }

    func hasKey(for model: AgentModel) -> Bool {
        guard let provider = model.provider else { return model.isCLIAgent }
        return !self[provider].isEmpty
    }

    @concurrent
    static func loadFromKeychain() async -> AgentCredentialSnapshot {
        var keys: [AgentProvider: String] = [:]
        for provider in AgentProvider.allCases {
            keys[provider] = await provider.loadAPIKey()
        }
        return AgentCredentialSnapshot(keys)
    }
}

enum AgentStopReason: String, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case pauseTurn = "pause_turn"
    case refusal = "refusal"
    case other
}

struct AgentRequestMessage: Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let content: [AgentRequestBlock]
}

enum AgentRequestBlock: Sendable {
    case content(AgentContentBlock)
    case image(base64: String, mediaType: String)
}

struct AgentToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum AgentStreamEvent: Equatable, Sendable {
    case thinkingDelta(String)
    case textDelta(String)
    case toolUseComplete(id: String, name: String, inputJSON: String)
    case messageStop(stopReason: AgentStopReason)
}

enum AgentStreamError: LocalizedError {
    case missingKey
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your API key in Settings › Agent to use AI chat."
        case .upstream(let message): message
        }
    }
}

enum AgentClientTransportError: LocalizedError {
    case missingAPIKey(AgentProvider)
    case httpError(provider: AgentProvider, status: Int, body: String)
    case streamError(provider: AgentProvider, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "No \(provider.displayName) API key is set."
        case .httpError(let provider, let status, let body):
            "\(provider.displayName) API error (\(status)): \(body.prefix(500))"
        case .streamError(let provider, let message):
            "\(provider.displayName) stream error: \(message)"
        }
    }
}

protocol AgentClient: Sendable {
    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

func makeAgentStream(
    _ operation: @escaping @Sendable (
        AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> Void
) -> AsyncThrowingStream<AgentStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await operation(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

enum AgentHTTP {
    static let streamIdleTimeout: TimeInterval = 600

    static func bytes(
        for request: URLRequest,
        makeError: (Int, String) -> any Error
    ) async throws -> URLSession.AsyncBytes {
        var request = request
        request.timeoutInterval = streamIdleTimeout
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode >= 400 else {
            return bytes
        }
        var body = ""
        for try await line in bytes.lines { body += line + "\n" }
        throw makeError(response.statusCode, body)
    }
}

enum AgentServiceError: Error {
    case unavailable(AgentModel)
    case refusal(AgentModel)
    case upstream(String)
}
