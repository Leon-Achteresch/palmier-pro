import Foundation
import Observation

/// Owns the OpenRouter key state and the image/video catalog built from the account's access.
@Observable
@MainActor
final class OpenRouterService {
    static let shared = OpenRouterService()

    private(set) var hasKey = false

    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    private init() {}

    func configure() {
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: .openRouterAPIKeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                OpenRouterService.shared.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let key = await Task.detached(priority: .utility) { OpenRouterKeychain.load() }.value
            guard !Task.isCancelled else { return }
            self.apiKey = key
            self.hasKey = key != nil

            guard key != nil else {
                ModelCatalog.shared.setOpenRouterEntries([])
                return
            }
            do {
                async let images = OpenRouterAPI.imageModels()
                async let videos = OpenRouterAPI.videoModels()
                let entries = try await OpenRouterCatalog.entries(
                    imageModels: images,
                    videoModels: videos
                )
                guard !Task.isCancelled, self.apiKey == key else { return }
                ModelCatalog.shared.setOpenRouterEntries(entries)
            } catch {
                Log.generation.warning("OpenRouter model list failed: \(error.localizedDescription)")
            }
        }
    }

    func currentKey() -> String? { apiKey }
}
