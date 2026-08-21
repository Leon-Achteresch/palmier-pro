import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — manage_proxies", .serialized)
@MainActor
struct ManageProxiesToolTests {
    private func harness() throws -> (ToolHarness, URL) {
        let h = ToolHarness()
        let projectURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("proxy-tool-\(UUID().uuidString).palmier", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        h.editor.projectURL = projectURL
        h.editor.proxyService.transcode = { _, output in
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data([0x1]).write(to: output)
            return CGSize(width: 960, height: 540)
        }
        return (h, projectURL)
    }

    private func settle(_ h: ToolHarness) async {
        while h.editor.proxyService.pendingCount > 0 { await Task.yield() }
    }

    @Test func statusListsEveryVideoAssetWithItsState() async throws {
        let (h, projectURL) = try harness()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let video = h.makeAsset(name: "A-roll")
        h.makeAsset(name: "Music", type: .audio)
        video.proxyStatus = .failed("encoder said no")

        let json = try await h.runOK("manage_proxies", args: ["action": "status"]) as? [String: Any]
        let rows = try #require(json?["proxies"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(video.id.hasPrefix(try #require(rows[0]["assetId"] as? String)))
        #expect(rows[0]["status"] as? String == "failed")
        #expect(rows[0]["error"] as? String == "encoder said no")
        #expect(json?["useProxies"] as? Bool == false)
    }

    @Test func generateQueuesEveryEligibleAssetAndReportsReadiness() async throws {
        let (h, projectURL) = try harness()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let a = h.makeAsset(name: "A")
        let b = h.makeAsset(name: "B")
        h.makeAsset(name: "Still", type: .image)

        let json = try await h.runOK("manage_proxies", args: ["action": "generate"]) as? [String: Any]
        let queued = try #require(json?["queuedAssetIds"] as? [String])
        #expect(queued.count == 2)
        #expect(queued.allSatisfy { short in [a.id, b.id].contains { $0.hasPrefix(short) } })
        await settle(h)
        #expect(a.proxyStatus == .ready)
        #expect(FileManager.default.fileExists(atPath: ProxyPlan.url(assetId: b.id, projectURL: projectURL).path))

        let repeated = try await h.runOK("manage_proxies", args: ["action": "generate"]) as? [String: Any]
        #expect((repeated?["queuedAssetIds"] as? [String])?.isEmpty == true)
        let skipped = try #require(repeated?["skipped"] as? [[String: Any]])
        #expect(skipped.count == 2)
        #expect(skipped[0]["reason"] as? String == ProxyRefusal.alreadyReady.message)
    }

    @Test func enableAndDisableToggleAsOneUndoableStep() async throws {
        let (h, projectURL) = try harness()
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let enabled = try await h.runOK("manage_proxies", args: ["action": "enable"]) as? [String: Any]
        #expect(enabled?["useProxies"] as? Bool == true)
        #expect(enabled?["changed"] as? Bool == true)
        #expect(h.editor.useProxies)

        let repeated = try await h.runOK("manage_proxies", args: ["action": "enable"]) as? [String: Any]
        #expect(repeated?["changed"] as? Bool == false)
        #expect((repeated?["notes"] as? [String])?.isEmpty == false)

        let disabled = try await h.runOK("manage_proxies", args: ["action": "disable"]) as? [String: Any]
        #expect(disabled?["useProxies"] as? Bool == false)
        #expect(!h.editor.useProxies)
    }

    @Test func removeDeletesFilesAndReportsANoOpSecondTime() async throws {
        let (h, projectURL) = try harness()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let asset = h.makeAsset(name: "A")
        _ = try await h.runOK("manage_proxies", args: ["action": "generate"])
        await settle(h)

        let removed = try await h.runOK("manage_proxies", args: ["action": "remove"]) as? [String: Any]
        let removedIds = try #require(removed?["removedAssetIds"] as? [String])
        #expect(removedIds.count == 1)
        #expect(asset.id.hasPrefix(removedIds[0]))
        #expect(asset.proxyStatus == .none)
        #expect(!FileManager.default.fileExists(atPath: ProxyPlan.url(assetId: asset.id, projectURL: projectURL).path))

        let again = try await h.runOK("manage_proxies", args: ["action": "remove"]) as? [String: Any]
        #expect((again?["removedAssetIds"] as? [String])?.isEmpty == true)
        #expect((again?["notes"] as? [String])?.isEmpty == false)
    }

    @Test func cancelStopsQueuedWorkAndReportsIt() async throws {
        let (h, projectURL) = try harness()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let asset = h.makeAsset(name: "A")
        asset.proxyStatus = .queued

        let json = try await h.runOK("manage_proxies", args: [
            "action": "cancel", "assetIds": [asset.id],
        ]) as? [String: Any]
        #expect((json?["cancelledAssetIds"] as? [String])?.isEmpty == true)
        #expect((json?["notes"] as? [String])?.isEmpty == false)
    }

    @Test func invalidArgumentsAreRefusedBeforeAnyWork() async throws {
        let (h, projectURL) = try harness()
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let audio = h.makeAsset(name: "Music", type: .audio)

        for args in [
            ["action": "sharpen"],
            ["action": "status", "assetIds": ["a"]],
            ["action": "status", "regenerate": true],
            ["action": "generate", "assetIds": []],
            ["action": "generate", "assetIds": ["ghost"]],
            ["action": "generate", "assetIds": [audio.id]],
            ["action": "generate", "unknownField": true],
        ] as [[String: Any]] {
            let result = await h.runRaw("manage_proxies", args: args)
            #expect(result.isError == true, "expected refusal for \(args)")
        }
        #expect(h.editor.proxyService.pendingCount == 0)
    }

    @Test func generateRefusesUntilTheProjectIsSaved() async throws {
        let h = ToolHarness()
        h.makeAsset(name: "A")
        let result = await h.runRaw("manage_proxies", args: ["action": "generate"])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("Save the project"))
    }
}
