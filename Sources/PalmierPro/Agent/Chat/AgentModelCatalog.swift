import Foundation
import Observation

/// Chat models the user can run: OpenRouter's tool-capable list, Google's Gemini list, and the local CLI agents.
@Observable
@MainActor
final class AgentModelCatalog {
    static let shared = AgentModelCatalog()

    private(set) var remoteModels: [AgentModel] = []

    @ObservationIgnored private var openRouterModels: [AgentModel] = []
    @ObservationIgnored private var googleModels: [AgentModel] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    private init() {}

    var models: [AgentModel] { remoteModels + AgentModel.cliModels }

    func configure() {
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: .agentAPIKeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AgentModelCatalog.shared.refresh() }
        }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let credentials = await AgentCredentialSnapshot.loadFromKeychain()
            guard !Task.isCancelled else { return }
            async let openRouter = Self.loadOpenRouterModels(hasKey: !credentials[.openRouter].isEmpty)
            async let google = Self.loadGoogleModels(apiKey: credentials[.google])
            let (openRouterModels, googleModels) = await (openRouter, google)
            guard !Task.isCancelled else { return }
            self.openRouterModels = openRouterModels
            self.googleModels = googleModels
            self.remoteModels = openRouterModels + googleModels
        }
    }

    func model(for rawValue: String) -> AgentModel? {
        models.first { $0.rawValue == rawValue }
    }

    private static func loadOpenRouterModels(hasKey: Bool) async -> [AgentModel] {
        guard hasKey else { return [] }
        do {
            return try await OpenRouterAPI.chatModels()
                .map { model in
                    AgentModel.openRouter(
                        id: model.id,
                        name: model.name,
                        efforts: efforts(model.supportedEfforts, supportsReasoning: model.supportsReasoning)
                    )
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            Log.agent.warning("OpenRouter chat model list failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func efforts(_ supported: [String]?, supportsReasoning: Bool) -> [AgentReasoningEffort] {
        guard supportsReasoning else { return [.none] }
        guard let supported, !supported.isEmpty else { return AgentModel.defaultEfforts }
        let mapped = supported.compactMap(AgentReasoningEffort.init(rawValue:))
        return mapped.isEmpty ? AgentModel.defaultEfforts : mapped
    }

    @concurrent
    private static func loadGoogleModels(apiKey: String) async -> [AgentModel] {
        guard !apiKey.isEmpty else { return [] }
        struct Response: Decodable {
            struct Entry: Decodable {
                let name: String
                let displayName: String?
                let supportedGenerationMethods: [String]?
            }
            let models: [Entry]
        }
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            return try JSONDecoder().decode(Response.self, from: data).models
                .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? false }
                .map { entry in
                    let id = entry.name.hasPrefix("models/")
                        ? String(entry.name.dropFirst("models/".count))
                        : entry.name
                    return AgentModel.google(id: id, name: entry.displayName ?? id)
                }
                .filter { $0.providerModelId.hasPrefix("gemini") }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            return []
        }
    }
}
