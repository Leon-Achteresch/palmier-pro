import Foundation

extension EditorViewModel {
    var proxyEligibleAssets: [MediaAsset] {
        mediaAssets.filter { ProxyPlan.isEligible(type: $0.type) }
    }

    func proxyReference(for asset: MediaAsset) -> ProxyReference? {
        guard let projectURL, ProxyPlan.isEligible(type: asset.type) else { return nil }
        return ProxyReference(url: ProxyPlan.url(assetId: asset.id, projectURL: projectURL), status: asset.proxyStatus)
    }

    func mediaURLMap(quality: MediaQuality) -> [String: URL] {
        let originals = mediaResolver.expectedURLMap()
        guard quality == .playback, useProxies else { return originals }
        var proxies: [String: ProxyReference] = [:]
        for asset in mediaAssets where asset.proxyStatus == .ready {
            guard let reference = proxyReference(for: asset) else { continue }
            proxies[asset.id] = reference
        }
        return ProxyResolution.urlMap(
            originals: originals, proxies: proxies, useProxies: useProxies, quality: quality
        )
    }

    func setUseProxies(_ enabled: Bool) {
        guard useProxies != enabled else { return }
        useProxies = enabled
        undo.register(enabled ? "Use Proxy Media" : "Use Original Media", withTarget: self) { vm in
            vm.setUseProxies(!enabled)
        }
        videoEngine?.rebuild()
    }

    @discardableResult
    func generateProxiesForAll(regenerate: Bool = false) -> [MediaAsset] {
        proxyEligibleAssets.filter { proxyService.enqueue($0, regenerate: regenerate) == nil }
    }

    func queueProxyIfAutomatic(for asset: MediaAsset) {
        guard useProxies, ProxyPlan.isEligible(type: asset.type), projectURL != nil else { return }
        proxyService.enqueue(asset)
    }

    func invalidateProxy(for asset: MediaAsset) {
        proxyService.cancel(assetId: asset.id)
        guard asset.proxyStatus != .none else { return }
        asset.proxyStatus = .none
        queueManifestMetadataUpdate(for: asset)
        if useProxies { videoEngine?.rebuild() }
    }

    func verifyRestoredProxies() {
        guard let projectURL else { return }
        let candidates = mediaAssets.filter { $0.proxyStatus == .ready }
        guard !candidates.isEmpty else { return }
        let paths = candidates.map { (id: $0.id, path: ProxyPlan.url(assetId: $0.id, projectURL: projectURL).path) }
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
            }.value
            guard let self, !missing.isEmpty, self.projectURL == projectURL else { return }
            var updated: [MediaAsset] = []
            for asset in self.mediaAssets where missing.contains(asset.id) && asset.proxyStatus == .ready {
                asset.proxyStatus = .none
                updated.append(asset)
            }
            guard !updated.isEmpty else { return }
            self.updateManifestMetadata(for: updated)
            if self.useProxies { self.videoEngine?.rebuild() }
        }
    }

    func removeProjectPackageItem(relativePath: String, in projectURL: URL) async throws -> Bool {
        try projectPackageCoordinator.beginMutation()
        defer { projectPackageCoordinator.endMutation() }
        let detached = try await projectPackageCoordinator.performMutation { () -> URL? in
            guard self.projectURL?.standardizedFileURL == projectURL.standardizedFileURL else { return nil }
            let target = projectURL.appendingPathComponent(relativePath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            let staged = projectURL.deletingLastPathComponent()
                .appendingPathComponent(".palmier-removed-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: target, to: staged)
            return staged
        }
        guard let detached else { return false }
        try await Task.detached(priority: .utility) {
            try FileManager.default.removeItem(at: detached)
        }.value
        return true
    }
}
