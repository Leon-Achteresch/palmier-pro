import Foundation

enum MediaQuality: Sendable {
    case playback
    case full
}

struct ProxyReference: Sendable, Equatable {
    let url: URL
    let status: ProxyStatus
}

enum ProxyResolution {
    static func url(
        original: URL?,
        proxy: ProxyReference?,
        useProxies: Bool,
        quality: MediaQuality
    ) -> URL? {
        guard let original else { return nil }
        guard quality == .playback, useProxies, let proxy, proxy.status == .ready else { return original }
        return proxy.url
    }

    static func urlMap(
        originals: [String: URL],
        proxies: [String: ProxyReference],
        useProxies: Bool,
        quality: MediaQuality
    ) -> [String: URL] {
        guard quality == .playback, useProxies, !proxies.isEmpty else { return originals }
        var resolved = originals
        for (assetId, original) in originals {
            resolved[assetId] = url(
                original: original, proxy: proxies[assetId], useProxies: useProxies, quality: quality
            )
        }
        return resolved
    }
}
