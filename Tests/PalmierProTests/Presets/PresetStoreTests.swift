import Foundation
import Testing
@testable import PalmierPro

enum PresetFileProbe {
    @concurrent static func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @concurrent static func write(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    @concurrent static func remove(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("PresetStore")
@MainActor
struct PresetStoreTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-presets-\(UUID().uuidString)", isDirectory: true)
    }

    private func lookPayload(exposure: Double = 0.4) -> PresetPayload {
        .effects([Effect.make("color.exposure", ["ev": exposure])])
    }

    @Test func roundTripsPresetsThroughDisk() async throws {
        let root = temporaryRoot()
        defer { Task { await PresetFileProbe.remove(root) } }

        let store = PresetStore(rootURL: root)
        let saved = try await store.save(name: "Warm", kind: .look, payload: lookPayload())
        #expect(store.userPresets.map(\.id) == [saved.id])

        let reopened = PresetStore(rootURL: root)
        await reopened.ensureLoaded()
        let loaded = try #require(reopened.preset(id: saved.id))
        #expect(loaded.name == "Warm")
        #expect(loaded.kind == .look)
        #expect(loaded.payload.effects?.map(\.type) == ["color.exposure"])
        #expect(loaded.payload.effects?.first?.params["ev"]?.value == 0.4)
        #expect(loaded.isBuiltIn == false)
    }

    @Test func writesOneFilePerPresetUnderItsKind() async throws {
        let root = temporaryRoot()
        defer { Task { await PresetFileProbe.remove(root) } }

        let store = PresetStore(rootURL: root)
        let look = try await store.save(name: "Warm", kind: .look, payload: lookPayload())
        let text = try await store.save(
            name: "Title",
            kind: .textStyle,
            payload: .textStyle(TextStylePayload(style: TextStyle(), fillMode: nil, animation: nil))
        )

        let lookFile = root.appendingPathComponent("look/\(look.id).json")
        let textFile = root.appendingPathComponent("textStyle/\(text.id).json")
        #expect(await PresetFileProbe.exists(lookFile))
        #expect(await PresetFileProbe.exists(textFile))
    }

    @Test func suffixesDuplicateNamesWithinTheSameKind() async throws {
        let root = temporaryRoot()
        defer { Task { await PresetFileProbe.remove(root) } }

        let store = PresetStore(rootURL: root)
        let first = try await store.save(name: "Warm", kind: .look, payload: lookPayload())
        let second = try await store.save(name: "Warm", kind: .look, payload: lookPayload(exposure: 0.8))
        let third = try await store.save(name: "Warm", kind: .look, payload: lookPayload(exposure: 1.2))
        let otherKind = try await store.save(
            name: "Warm",
            kind: .effects,
            payload: .effects([Effect.make("stylize.grain", ["amount": 0.3])])
        )

        #expect(first.name == "Warm")
        #expect(second.name == "Warm 2")
        #expect(third.name == "Warm 3")
        #expect(otherKind.name == "Warm")
    }

    @Test func renamingAvoidsCollisionsAndDeletingRemovesTheFile() async throws {
        let root = temporaryRoot()
        defer { Task { await PresetFileProbe.remove(root) } }

        let store = PresetStore(rootURL: root)
        _ = try await store.save(name: "Warm", kind: .look, payload: lookPayload())
        let other = try await store.save(name: "Cool", kind: .look, payload: lookPayload(exposure: -0.4))

        let renamed = try await store.rename(id: other.id, to: "Warm")
        #expect(renamed.name == "Warm 2")

        let deleted = try await store.delete(id: other.id)
        #expect(deleted.id == other.id)
        #expect(store.preset(id: other.id) == nil)
        #expect(await PresetFileProbe.exists(root.appendingPathComponent("look/\(other.id).json")) == false)
    }

    @Test func rejectsEmptyNamesUnknownIdsAndBuiltInEdits() async throws {
        let root = temporaryRoot()
        defer { Task { await PresetFileProbe.remove(root) } }

        let store = PresetStore(rootURL: root)
        await #expect(throws: PresetStoreError.self) {
            try await store.save(name: "   ", kind: .look, payload: lookPayload())
        }
        await #expect(throws: PresetStoreError.self) {
            try await store.rename(id: "missing", to: "Warm")
        }
        await #expect(throws: PresetStoreError.self) {
            try await store.delete(id: "missing")
        }
        let builtIn = try #require(PresetStore.builtInPresets.first)
        await #expect(throws: PresetStoreError.self) {
            try await store.delete(id: builtIn.id)
        }
    }

    @Test func libraryListsBuiltInLooksAheadOfSavedOnes() async throws {
        let root = temporaryRoot()
        defer { Task { await PresetFileProbe.remove(root) } }

        let store = PresetStore(rootURL: root)
        _ = try await store.save(name: "Warm", kind: .look, payload: lookPayload())

        let looks = store.library(kind: .look)
        #expect(looks.prefix(LookPreset.allCases.count).map(\.isBuiltIn) == Array(repeating: true, count: LookPreset.allCases.count))
        #expect(looks.last?.name == "Warm")
        #expect(store.library(kind: .effects).isEmpty)
    }

    @Test func skipsFilesWhosePayloadDoesNotMatchTheirKind() async throws {
        let root = temporaryRoot()
        defer { Task { await PresetFileProbe.remove(root) } }

        let mismatched = StylePreset(
            name: "Bogus",
            kind: .look,
            payload: .effects([Effect.make("stylize.grain", ["amount": 0.3])])
        )
        let directory = root.appendingPathComponent("look", isDirectory: true)
        try await PresetFileProbe.write(
            JSONEncoder().encode(mismatched),
            to: directory.appendingPathComponent("\(mismatched.id).json")
        )
        try await PresetFileProbe.write(Data("not json".utf8), to: directory.appendingPathComponent("broken.json"))

        let store = PresetStore(rootURL: root)
        await store.ensureLoaded()
        #expect(store.userPresets.isEmpty)
    }

    @Test(arguments: [
        (["Warm"], "Warm 2"),
        (["Warm", "Warm 2"], "Warm 3"),
        (["Cool"], "Warm"),
        ([], "Warm"),
    ])
    func uniqueNameAppendsTheFirstFreeSuffix(existing: [String], expected: String) {
        #expect(PresetStore.uniqueName("Warm", among: existing) == expected)
    }
}
