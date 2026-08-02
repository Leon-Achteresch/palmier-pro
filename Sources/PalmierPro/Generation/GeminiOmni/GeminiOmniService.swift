import Foundation
import Observation

@Observable
@MainActor
final class GeminiOmniService {
    static let shared = GeminiOmniService()

    private(set) var hasKey = false

    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    private init() {}

    func configure() {
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: .geminiAPIKeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                GeminiOmniService.shared.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let key = await Task.detached(priority: .utility) { GeminiKeychain.load() }.value
            guard !Task.isCancelled else { return }
            self.apiKey = key
            self.hasKey = key != nil
            ModelCatalog.shared.setGeminiEntries(key == nil ? [] : GeminiOmniCatalog.entries())
        }
    }

    func currentKey() -> String? { apiKey }
}
