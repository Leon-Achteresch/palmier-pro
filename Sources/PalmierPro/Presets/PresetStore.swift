import Foundation

enum PresetStoreError: LocalizedError {
    case emptyName
    case notFound(String)
    case readOnly(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "A preset needs a name."
        case .notFound(let id): "Preset not found: \(id)"
        case .readOnly(let name): "'\(name)' is a built-in preset and cannot be changed."
        }
    }
}

@Observable
@MainActor
final class PresetStore {
    static let shared = PresetStore(rootURL: PresetStore.defaultRootURL)

    private(set) var userPresets: [StylePreset] = []
    private let disk: PresetDisk
    private var loadTask: Task<Void, Never>?
    private var appliedVersion = 0

    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/Presets")
    }

    static let builtInPresets: [StylePreset] = LookPreset.allCases.map(\.preset)

    init(rootURL: URL) {
        disk = PresetDisk(root: rootURL)
        loadTask = Task { [weak self, disk] in
            let snapshot = await disk.snapshot()
            self?.apply(snapshot)
        }
    }

    func ensureLoaded() async {
        await loadTask?.value
    }

    func library(kind: PresetKind) -> [StylePreset] {
        Self.builtInPresets.filter { $0.kind == kind }
            + userPresets.filter { $0.kind == kind }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func preset(id: String) -> StylePreset? {
        Self.builtInPresets.first { $0.id == id } ?? userPresets.first { $0.id == id }
    }

    @discardableResult
    func save(name: String, kind: PresetKind, payload: PresetPayload) async throws -> StylePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetStoreError.emptyName }
        let (preset, snapshot) = try await disk.save(name: trimmed, kind: kind, payload: payload)
        apply(snapshot)
        return preset
    }

    @discardableResult
    func rename(id: String, to name: String) async throws -> StylePreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetStoreError.emptyName }
        try requireEditable(id)
        let (preset, snapshot) = try await disk.rename(id: id, to: trimmed)
        apply(snapshot)
        return preset
    }

    @discardableResult
    func delete(id: String) async throws -> StylePreset {
        try requireEditable(id)
        let (preset, snapshot) = try await disk.delete(id: id)
        apply(snapshot)
        return preset
    }

    private func requireEditable(_ id: String) throws {
        if let builtIn = Self.builtInPresets.first(where: { $0.id == id }) {
            throw PresetStoreError.readOnly(builtIn.name)
        }
    }

    private func apply(_ snapshot: PresetSnapshot) {
        guard snapshot.version > appliedVersion else { return }
        appliedVersion = snapshot.version
        userPresets = snapshot.presets
    }

    nonisolated static func uniqueName(_ requested: String, among existing: [String]) -> String {
        guard existing.contains(requested) else { return requested }
        var suffix = 2
        while existing.contains("\(requested) \(suffix)") { suffix += 1 }
        return "\(requested) \(suffix)"
    }
}

struct PresetSnapshot: Sendable {
    let version: Int
    let presets: [StylePreset]
}

actor PresetDisk {
    private let root: URL
    private var presets: [String: StylePreset] = [:]
    private var loaded = false
    private var version = 0

    init(root: URL) {
        self.root = root
    }

    func snapshot() -> PresetSnapshot {
        loadIfNeeded()
        return PresetSnapshot(version: version, presets: sortedPresets)
    }

    func save(name: String, kind: PresetKind, payload: PresetPayload) throws -> (StylePreset, PresetSnapshot) {
        loadIfNeeded()
        let taken = presets.values.filter { $0.kind == kind }.map(\.name)
        let preset = StylePreset(
            name: PresetStore.uniqueName(name, among: taken),
            kind: kind,
            payload: payload
        )
        try write(preset)
        presets[preset.id] = preset
        version += 1
        return (preset, PresetSnapshot(version: version, presets: sortedPresets))
    }

    func rename(id: String, to name: String) throws -> (StylePreset, PresetSnapshot) {
        loadIfNeeded()
        guard var preset = presets[id] else { throw PresetStoreError.notFound(id) }
        let taken = presets.values.filter { $0.kind == preset.kind && $0.id != id }.map(\.name)
        preset.name = PresetStore.uniqueName(name, among: taken)
        try write(preset)
        presets[id] = preset
        version += 1
        return (preset, PresetSnapshot(version: version, presets: sortedPresets))
    }

    func delete(id: String) throws -> (StylePreset, PresetSnapshot) {
        loadIfNeeded()
        guard let preset = presets[id] else { throw PresetStoreError.notFound(id) }
        try FileManager.default.removeItem(at: fileURL(for: preset))
        presets.removeValue(forKey: id)
        version += 1
        return (preset, PresetSnapshot(version: version, presets: sortedPresets))
    }

    private var sortedPresets: [StylePreset] {
        presets.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private func fileURL(for preset: StylePreset) -> URL {
        root.appendingPathComponent(preset.kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(preset.id).json")
    }

    private func write(_ preset: StylePreset) throws {
        let url = fileURL(for: preset)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(preset).write(to: url, options: .atomic)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        for kind in PresetKind.allCases {
            let directory = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let preset = try? decoder.decode(StylePreset.self, from: data),
                      preset.kind == kind, preset.payload.matches(kind), presets[preset.id] == nil else {
                    Log.app.warning("preset skipped file=\(file.lastPathComponent)")
                    continue
                }
                presets[preset.id] = preset
            }
        }
        version += 1
    }
}
