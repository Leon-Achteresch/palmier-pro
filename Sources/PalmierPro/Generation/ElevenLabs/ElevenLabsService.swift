import Foundation
import Observation

/// Owns the ElevenLabs key state, the account's voice list, and the catalog entries built from them.
@Observable
@MainActor
final class ElevenLabsService {
    static let shared = ElevenLabsService()

    private(set) var hasKey = false
    private(set) var voices: [ElevenLabsAPI.Voice] = []

    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    private init() {}

    func configure() {
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: .elevenLabsAPIKeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ElevenLabsService.shared.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let key = await Task.detached(priority: .utility) { ElevenLabsKeychain.load() }.value
            guard !Task.isCancelled else { return }
            self.apiKey = key
            self.hasKey = key != nil

            var fetched: [ElevenLabsAPI.Voice] = []
            if let key {
                do {
                    fetched = try await ElevenLabsAPI.voices(apiKey: key)
                } catch {
                    Log.generation.warning("ElevenLabs voice list failed: \(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled, self.apiKey == key else { return }
            self.voices = fetched
            ModelCatalog.shared.setElevenLabsEntries(
                key == nil ? [] : ElevenLabsCatalog.entries(voices: fetched)
            )
        }
    }

    func currentKey() -> String? { apiKey }

    /// Accepts a voice name from the catalog, a raw ElevenLabs voice id, or nothing.
    func voiceId(named name: String?) -> String {
        let fallback = voices.first?.id ?? ElevenLabsAPI.fallbackVoiceId
        guard let name, !name.isEmpty else { return fallback }
        if let match = voices.first(where: { $0.name == name }) { return match.id }
        if voices.contains(where: { $0.id == name }) { return name }
        return voices.isEmpty ? name : fallback
    }
}
