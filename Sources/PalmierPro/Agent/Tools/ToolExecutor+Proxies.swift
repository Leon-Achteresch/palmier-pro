import Foundation

extension ToolExecutor {
    func manageProxies(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ManageProxiesArgs = try decodeToolArgs(args, path: "manage_proxies")
        guard let action = ProxyAction(rawValue: input.action) else {
            throw ToolError("manage_proxies: action must be status, generate, cancel, remove, enable, or disable")
        }
        if input.assetIds != nil, !action.acceptsAssetIds {
            throw ToolError("manage_proxies: assetIds only applies to generate, cancel, and remove")
        }
        if input.regenerate != nil, action != .generate {
            throw ToolError("manage_proxies: regenerate only applies to generate")
        }

        switch action {
        case .status:
            return try proxyResult(editor, action: action)
        case .enable, .disable:
            let enabled = action == .enable
            let changed = editor.useProxies != enabled
            editor.setUseProxies(enabled)
            return try proxyResult(editor, action: action, extra: [
                "useProxies": editor.useProxies,
                "changed": changed,
            ], notes: changed ? [] : ["Proxy playback was already \(enabled ? "on" : "off") — nothing changed."])
        case .generate:
            return try generateProxies(editor, assetIds: input.assetIds, regenerate: input.regenerate ?? false)
        case .cancel:
            let targets = try proxyTargets(editor, assetIds: input.assetIds)
            let cancelled = targets.filter { editor.proxyService.cancel(assetId: $0.id) }.map(\.id)
            return try proxyResult(editor, action: action, extra: [
                "cancelledAssetIds": cancelled,
            ], notes: cancelled.isEmpty ? ["No proxy jobs were queued or generating — nothing to cancel."] : [])
        case .remove:
            return try await removeProxies(editor, assetIds: input.assetIds)
        }
    }

    private func generateProxies(
        _ editor: EditorViewModel, assetIds: [String]?, regenerate: Bool
    ) throws -> ToolResult {
        guard editor.projectURL != nil else {
            throw ToolError("manage_proxies: \(ProxyRefusal.projectNotSaved.message)")
        }
        let targets = try proxyTargets(editor, assetIds: assetIds)
        var queued: [String] = []
        var skipped: [[String: Any]] = []
        for asset in targets {
            if let refusal = editor.proxyService.enqueue(asset, regenerate: regenerate) {
                skipped.append(["assetId": asset.id, "reason": refusal.message])
            } else {
                queued.append(asset.id)
            }
        }
        var notes: [String] = []
        if queued.isEmpty {
            notes.append("Nothing was queued. Pass regenerate=true to re-encode assets that already have a proxy.")
        } else {
            notes.append("Transcoding runs in the background, two assets at a time. Poll manage_proxies action=status for readiness.")
        }
        var extra: [String: Any] = ["queuedAssetIds": queued]
        if !skipped.isEmpty { extra["skipped"] = skipped }
        return try proxyResult(editor, action: .generate, extra: extra, notes: notes)
    }

    private func removeProxies(_ editor: EditorViewModel, assetIds: [String]?) async throws -> ToolResult {
        var removed: [String] = []
        if assetIds == nil {
            removed = try await editor.proxyService.removeAllProxies()
        } else {
            for asset in try proxyTargets(editor, assetIds: assetIds) {
                if try await editor.proxyService.removeProxy(for: asset) { removed.append(asset.id) }
            }
        }
        return try proxyResult(editor, action: .remove, extra: ["removedAssetIds": removed], notes: removed.isEmpty
            ? ["No proxies existed for the requested assets — nothing was removed."]
            : [])
    }

    private func proxyTargets(_ editor: EditorViewModel, assetIds: [String]?) throws -> [MediaAsset] {
        guard let assetIds else { return editor.proxyEligibleAssets }
        guard !assetIds.isEmpty else {
            throw ToolError("manage_proxies: assetIds must not be empty — omit it to target every video asset")
        }
        var seen: Set<String> = []
        var targets: [MediaAsset] = []
        for id in assetIds where seen.insert(id).inserted {
            let asset = try asset(id, editor: editor, label: "manage_proxies: media asset")
            guard ProxyPlan.isEligible(type: asset.type) else {
                throw ToolError("manage_proxies: '\(id)' is \(asset.type.rawValue) — \(ProxyRefusal.notVideo.message)")
            }
            targets.append(asset)
        }
        return targets
    }

    private func proxyResult(
        _ editor: EditorViewModel,
        action: ProxyAction,
        extra: [String: Any] = [:],
        notes: [String] = []
    ) throws -> ToolResult {
        var payload: [String: Any] = [
            "action": action.rawValue,
            "useProxies": editor.useProxies,
            "pendingCount": editor.proxyService.pendingCount,
            "proxies": editor.proxyEligibleAssets.map { asset -> [String: Any] in
                var row: [String: Any] = [
                    "assetId": asset.id,
                    "name": asset.name,
                    "status": asset.proxyStatus.statusValue,
                ]
                if let error = asset.proxyStatus.failureMessage { row["error"] = error }
                return row
            },
        ]
        payload.merge(extra) { _, new in new }
        if !notes.isEmpty { payload["notes"] = notes }
        guard let json = Self.jsonString(payload) else {
            throw ToolError("manage_proxies: failed to encode proxy report")
        }
        return .ok(json)
    }
}

private enum ProxyAction: String {
    case status, generate, cancel, remove, enable, disable

    var acceptsAssetIds: Bool {
        switch self {
        case .generate, .cancel, .remove: true
        case .status, .enable, .disable: false
        }
    }
}

private struct ManageProxiesArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["action", "assetIds", "regenerate"]

    let action: String
    var assetIds: [String]?
    var regenerate: Bool?
}

private extension ProxyStatus {
    var statusValue: String {
        switch self {
        case .none: "none"
        case .queued: "queued"
        case .generating: "generating"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
