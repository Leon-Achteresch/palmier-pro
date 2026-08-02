import Foundation

@Observable
@MainActor
final class ReferenceLibrary {
    static let shared = ReferenceLibrary()

    private(set) var profiles: [ReferenceProfile] = []
    private let fileURL: URL
    private let disk = ReferenceLibraryDisk()
    private var loadTask: Task<Void, Never>?

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/References/references.json")
    }

    private convenience init() {
        self.init(fileURL: Self.defaultFileURL)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        loadTask = Task { [weak self, disk, fileURL] in
            let loaded = await disk.load(from: fileURL)
            self?.profiles = loaded
        }
    }

    func ensureLoaded() async {
        await loadTask?.value
    }

    func profile(id: String) async -> ReferenceProfile? {
        await ensureLoaded()
        return profiles.first { $0.id == id }
    }

    func add(_ profile: ReferenceProfile) async throws {
        await ensureLoaded()
        let backup = profiles
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        do {
            try await disk.save(profiles, to: fileURL)
        } catch {
            profiles = backup
            throw error
        }
    }

    func remove(id: String) async throws -> Bool {
        await ensureLoaded()
        let backup = profiles
        profiles.removeAll { $0.id == id }
        guard profiles.count != backup.count else { return false }
        do {
            try await disk.save(profiles, to: fileURL)
        } catch {
            profiles = backup
            throw error
        }
        return true
    }
}

private actor ReferenceLibraryDisk {
    func load(from url: URL) -> [ReferenceProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ReferenceProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [ReferenceProfile], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: url, options: .atomic)
    }
}
