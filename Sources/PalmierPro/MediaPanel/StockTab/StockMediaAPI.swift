import Foundation

extension Notification.Name {
    static let stockMediaAPIKeyChanged = Notification.Name("stockMediaAPIKeyChanged")
}

enum StockMediaProvider: String, CaseIterable, Sendable, Codable {
    case pexels
    case pixabay

    var displayName: String {
        switch self {
        case .pexels: "Pexels"
        case .pixabay: "Pixabay"
        }
    }

    var keyURL: URL {
        switch self {
        case .pexels: URL(string: "https://www.pexels.com/api/")!
        case .pixabay: URL(string: "https://pixabay.com/api/docs/")!
        }
    }

    var licenseNote: String {
        switch self {
        case .pexels: "Free to use, no attribution required (Pexels License)"
        case .pixabay: "Free to use, no attribution required (Pixabay Content License)"
        }
    }
}

enum StockMediaKind: String, CaseIterable, Sendable, Codable {
    case photo
    case video
}

struct StockMediaItem: Identifiable, Sendable, Hashable {
    let id: String
    let provider: StockMediaProvider
    let kind: StockMediaKind
    let thumbnailURL: URL
    let downloadURL: URL
    let width: Int
    let height: Int
    let durationSeconds: Double?
    let author: String
    let pageURL: URL?

    var fileExtension: String { kind == .photo ? "jpg" : "mp4" }

    var defaultName: String {
        let base = author.isEmpty ? provider.displayName : author
        return "\(base) \(kind == .photo ? "photo" : "video")"
    }
}

enum StockMediaKeychain {
    private static func account(_ provider: StockMediaProvider) -> String {
        "\(provider.rawValue)-api-key"
    }

    static func save(_ key: String, provider: StockMediaProvider) {
        KeychainStore.save(key, account: account(provider))
        NotificationCenter.default.post(name: .stockMediaAPIKeyChanged, object: nil)
    }

    static func load(provider: StockMediaProvider) -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["\(provider.rawValue.uppercased())_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account(provider))
    }

    static func delete(provider: StockMediaProvider) {
        KeychainStore.delete(account: account(provider))
        NotificationCenter.default.post(name: .stockMediaAPIKeyChanged, object: nil)
    }
}

enum StockMediaAPI {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct SearchResult: Sendable {
        let items: [StockMediaItem]
        let totalResults: Int
    }

    static let defaultPerPage = 30
    static let maxPerPage = 80
    private static let requestTimeout: TimeInterval = 30

    @concurrent
    static func search(
        provider: StockMediaProvider,
        kind: StockMediaKind,
        query: String,
        page: Int = 1,
        perPage: Int = defaultPerPage,
        apiKey: String
    ) async throws -> SearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError(message: "Search query is empty") }
        let page = max(1, page)
        let perPage = min(max(1, perPage), maxPerPage)

        switch (provider, kind) {
        case (.pexels, .photo):
            return try await searchPexelsPhotos(query: trimmed, page: page, perPage: perPage, apiKey: apiKey)
        case (.pexels, .video):
            return try await searchPexelsVideos(query: trimmed, page: page, perPage: perPage, apiKey: apiKey)
        case (.pixabay, .photo):
            return try await searchPixabayPhotos(query: trimmed, page: page, perPage: perPage, apiKey: apiKey)
        case (.pixabay, .video):
            return try await searchPixabayVideos(query: trimmed, page: page, perPage: perPage, apiKey: apiKey)
        }
    }

    private static func searchPexelsPhotos(
        query: String, page: Int, perPage: Int, apiKey: String
    ) async throws -> SearchResult {
        struct Response: Decodable {
            struct Photo: Decodable {
                struct Src: Decodable {
                    let original: String
                    let large2x: String?
                    let medium: String?
                }
                let id: Int
                let width: Int
                let height: Int
                let url: String?
                let photographer: String?
                let src: Src
            }
            let photos: [Photo]
            let total_results: Int?
        }

        let url = URL(string: "https://api.pexels.com/v1/search")!
            .appending(queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage)),
            ])
        let data = try await send(pexelsRequest(url: url, apiKey: apiKey), provider: .pexels)
        let response = try decode(Response.self, from: data, provider: .pexels)
        let items = response.photos.compactMap { photo -> StockMediaItem? in
            guard let download = URL(string: photo.src.large2x ?? photo.src.original),
                  let thumb = URL(string: photo.src.medium ?? photo.src.original)
            else { return nil }
            return StockMediaItem(
                id: "pexels-photo-\(photo.id)",
                provider: .pexels,
                kind: .photo,
                thumbnailURL: thumb,
                downloadURL: download,
                width: photo.width,
                height: photo.height,
                durationSeconds: nil,
                author: photo.photographer ?? "",
                pageURL: photo.url.flatMap(URL.init(string:))
            )
        }
        return SearchResult(items: items, totalResults: response.total_results ?? items.count)
    }

    private static func searchPexelsVideos(
        query: String, page: Int, perPage: Int, apiKey: String
    ) async throws -> SearchResult {
        struct Response: Decodable {
            struct Video: Decodable {
                struct File: Decodable {
                    let file_type: String?
                    let width: Int?
                    let height: Int?
                    let link: String
                }
                struct User: Decodable {
                    let name: String?
                }
                let id: Int
                let width: Int
                let height: Int
                let duration: Double?
                let url: String?
                let image: String?
                let user: User?
                let video_files: [File]
            }
            let videos: [Video]
            let total_results: Int?
        }

        let url = URL(string: "https://api.pexels.com/videos/search")!
            .appending(queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage)),
            ])
        let data = try await send(pexelsRequest(url: url, apiKey: apiKey), provider: .pexels)
        let response = try decode(Response.self, from: data, provider: .pexels)
        let items = response.videos.compactMap { video -> StockMediaItem? in
            let mp4Files = video.video_files.filter { ($0.file_type ?? "").lowercased() == "video/mp4" }
            guard let best = mp4Files.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }),
                  let download = URL(string: best.link),
                  let thumb = video.image.flatMap(URL.init(string:))
            else { return nil }
            return StockMediaItem(
                id: "pexels-video-\(video.id)",
                provider: .pexels,
                kind: .video,
                thumbnailURL: thumb,
                downloadURL: download,
                width: best.width ?? video.width,
                height: best.height ?? video.height,
                durationSeconds: video.duration,
                author: video.user?.name ?? "",
                pageURL: video.url.flatMap(URL.init(string:))
            )
        }
        return SearchResult(items: items, totalResults: response.total_results ?? items.count)
    }

    private static func searchPixabayPhotos(
        query: String, page: Int, perPage: Int, apiKey: String
    ) async throws -> SearchResult {
        struct Response: Decodable {
            struct Hit: Decodable {
                let id: Int
                let pageURL: String?
                let webformatURL: String?
                let largeImageURL: String?
                let imageWidth: Int
                let imageHeight: Int
                let user: String?
            }
            let hits: [Hit]
            let totalHits: Int?
        }

        let url = URL(string: "https://pixabay.com/api/")!
            .appending(queryItems: [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "image_type", value: "photo"),
                URLQueryItem(name: "safesearch", value: "true"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage)),
            ])
        let data = try await send(URLRequest(url: url, timeoutInterval: requestTimeout), provider: .pixabay)
        let response = try decode(Response.self, from: data, provider: .pixabay)
        let items = response.hits.compactMap { hit -> StockMediaItem? in
            guard let download = (hit.largeImageURL ?? hit.webformatURL).flatMap(URL.init(string:)),
                  let thumb = (hit.webformatURL ?? hit.largeImageURL).flatMap(URL.init(string:))
            else { return nil }
            return StockMediaItem(
                id: "pixabay-photo-\(hit.id)",
                provider: .pixabay,
                kind: .photo,
                thumbnailURL: thumb,
                downloadURL: download,
                width: hit.imageWidth,
                height: hit.imageHeight,
                durationSeconds: nil,
                author: hit.user ?? "",
                pageURL: hit.pageURL.flatMap(URL.init(string:))
            )
        }
        return SearchResult(items: items, totalResults: response.totalHits ?? items.count)
    }

    private static func searchPixabayVideos(
        query: String, page: Int, perPage: Int, apiKey: String
    ) async throws -> SearchResult {
        struct Response: Decodable {
            struct Hit: Decodable {
                struct Rendition: Decodable {
                    let url: String?
                    let width: Int?
                    let height: Int?
                    let thumbnail: String?
                }
                struct Renditions: Decodable {
                    let large: Rendition?
                    let medium: Rendition?
                    let small: Rendition?
                }
                let id: Int
                let pageURL: String?
                let duration: Double?
                let user: String?
                let videos: Renditions
            }
            let hits: [Hit]
            let totalHits: Int?
        }

        let url = URL(string: "https://pixabay.com/api/videos/")!
            .appending(queryItems: [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "safesearch", value: "true"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage)),
            ])
        let data = try await send(URLRequest(url: url, timeoutInterval: requestTimeout), provider: .pixabay)
        let response = try decode(Response.self, from: data, provider: .pixabay)
        let items = response.hits.compactMap { hit -> StockMediaItem? in
            let best = hit.videos.large ?? hit.videos.medium ?? hit.videos.small
            guard let best,
                  let download = best.url.flatMap(URL.init(string:)),
                  let thumb = (best.thumbnail ?? hit.videos.medium?.thumbnail).flatMap(URL.init(string:))
            else { return nil }
            return StockMediaItem(
                id: "pixabay-video-\(hit.id)",
                provider: .pixabay,
                kind: .video,
                thumbnailURL: thumb,
                downloadURL: download,
                width: best.width ?? 0,
                height: best.height ?? 0,
                durationSeconds: hit.duration,
                author: hit.user ?? "",
                pageURL: hit.pageURL.flatMap(URL.init(string:))
            )
        }
        return SearchResult(items: items, totalResults: response.totalHits ?? items.count)
    }

    private static func pexelsRequest(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func send(_ request: URLRequest, provider: StockMediaProvider) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError(message: "\(provider.displayName) request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "\(provider.displayName) returned an invalid response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw APIError(message: "\(provider.displayName) rejected the API key. Check it in Settings → Models.")
        case 429:
            throw APIError(message: "\(provider.displayName) rate limit reached. Try again in a few minutes.")
        default:
            throw APIError(message: "\(provider.displayName) returned HTTP \(http.statusCode)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, provider: StockMediaProvider) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError(message: "Could not parse the \(provider.displayName) response")
        }
    }
}
