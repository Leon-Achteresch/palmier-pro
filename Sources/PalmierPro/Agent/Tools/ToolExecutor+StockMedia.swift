import Foundation

extension ToolExecutor {
    private static let searchStockMediaAllowedKeys: Set<String> = ["query", "kind", "provider", "page", "perPage"]

    func searchStockMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.searchStockMediaAllowedKeys, path: "search_stock_media")

        guard let query = args.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ToolError("Missing required 'query'")
        }
        guard let kindRaw = args.string("kind"), let kind = StockMediaKind(rawValue: kindRaw) else {
            throw ToolError("'kind' must be 'photo' or 'video'")
        }
        let page = args.int("page") ?? 1
        guard page >= 1 else { throw ToolError("'page' must be >= 1") }
        let perPage = args.int("perPage") ?? 20
        guard (1...StockMediaAPI.maxPerPage).contains(perPage) else {
            throw ToolError("'perPage' must be between 1 and \(StockMediaAPI.maxPerPage)")
        }

        var requestedProvider: StockMediaProvider?
        if let providerRaw = args.string("provider") {
            guard let parsed = StockMediaProvider(rawValue: providerRaw) else {
                throw ToolError("'provider' must be one of \(StockMediaProvider.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            requestedProvider = parsed
        }

        let keys = await Task.detached(priority: .utility) {
            var keys: [StockMediaProvider: String] = [:]
            for provider in StockMediaProvider.allCases {
                keys[provider] = StockMediaKeychain.load(provider: provider)
            }
            return keys
        }.value
        let configured = StockMediaProvider.allCases.filter { keys[$0] != nil }

        let provider: StockMediaProvider
        if let requestedProvider {
            provider = requestedProvider
        } else if let first = configured.first {
            provider = first
        } else {
            throw ToolError("No stock media API key is configured. Ask the user to add a free Pexels (pexels.com/api) or Pixabay (pixabay.com/api/docs) API key in Settings → Models.")
        }
        guard let apiKey = keys[provider] else {
            throw ToolError("No \(provider.displayName) API key is configured. Ask the user to add one in Settings → Models\(configured.isEmpty ? "" : ", or use provider '\(configured[0].rawValue)'").")
        }

        let result: StockMediaAPI.SearchResult
        do {
            result = try await StockMediaAPI.search(
                provider: provider, kind: kind, query: query,
                page: page, perPage: perPage, apiKey: apiKey
            )
        } catch {
            throw ToolError((error as? StockMediaAPI.APIError)?.message ?? error.localizedDescription)
        }

        let items = result.items.map { item -> [String: Any] in
            var entry: [String: Any] = [
                "id": item.id,
                "width": item.width,
                "height": item.height,
                "author": item.author,
                "downloadUrl": item.downloadURL.absoluteString,
                "thumbnailUrl": item.thumbnailURL.absoluteString,
            ]
            if let duration = item.durationSeconds { entry["durationSeconds"] = duration }
            if let pageURL = item.pageURL { entry["pageUrl"] = pageURL.absoluteString }
            return entry
        }

        return .ok(Self.jsonString([
            "provider": provider.rawValue,
            "kind": kind.rawValue,
            "query": query,
            "page": page,
            "totalResults": result.totalResults,
            "configuredProviders": configured.map(\.rawValue),
            "license": provider.licenseNote,
            "items": items,
            "note": "Nothing imported yet. Import a result with import_media source.url = downloadUrl (set source.mimeType '\(kind == .photo ? "image/jpeg" : "video/mp4")' if the URL has no usable extension).",
        ] as [String: Any]) ?? "{}")
    }
}
