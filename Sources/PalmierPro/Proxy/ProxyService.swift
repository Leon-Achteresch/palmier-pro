import AVFoundation

enum ProxyRefusal: Equatable, Sendable {
    case notVideo
    case projectNotSaved
    case alreadyReady
    case alreadyPending

    var message: String {
        switch self {
        case .notVideo: "Only video assets can have a proxy."
        case .projectNotSaved: "Save the project before generating proxies."
        case .alreadyReady: "A proxy already exists."
        case .alreadyPending: "A proxy is already queued or generating."
        }
    }
}

@Observable
@MainActor
final class ProxyService {
    static let maxConcurrent = 2

    @ObservationIgnored weak var editor: EditorViewModel?

    @ObservationIgnored
    var transcode: @Sendable (_ source: URL, _ output: URL) async throws -> CGSize = {
        try await ProxyTranscoder.transcode(source: $0, to: $1)
    }

    private(set) var waitingIds: [String] = []
    private(set) var generatingIds: [String] = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var runIds: [String: Int] = [:]
    @ObservationIgnored private var nextRunId = 0

    var pendingCount: Int { waitingIds.count + generatingIds.count }
    var hasActivity: Bool { pendingCount > 0 }

    @discardableResult
    func enqueue(_ asset: MediaAsset, regenerate: Bool = false) -> ProxyRefusal? {
        guard ProxyPlan.isEligible(type: asset.type) else { return .notVideo }
        guard editor?.projectURL != nil else { return .projectNotSaved }
        if asset.proxyStatus.isPending { return .alreadyPending }
        if asset.proxyStatus == .ready, !regenerate { return .alreadyReady }
        setStatus(.queued, on: asset)
        waitingIds.append(asset.id)
        pump()
        return nil
    }

    @discardableResult
    func cancel(assetId: String) -> Bool {
        var cancelled = false
        if let index = waitingIds.firstIndex(of: assetId) {
            waitingIds.remove(at: index)
            cancelled = true
        }
        if let task = tasks.removeValue(forKey: assetId) {
            runIds[assetId] = nil
            task.cancel()
            cancelled = true
        }
        generatingIds.removeAll { $0 == assetId }
        if cancelled, let asset = editor?.mediaAssetsById[assetId], asset.proxyStatus.isPending {
            setStatus(.none, on: asset)
        }
        if cancelled { pump() }
        return cancelled
    }

    @discardableResult
    func cancelAll() -> [String] {
        let ids = waitingIds + generatingIds
        for id in ids { cancel(assetId: id) }
        return ids
    }

    @discardableResult
    func removeProxy(for asset: MediaAsset) async throws -> Bool {
        cancel(assetId: asset.id)
        guard let editor, let projectURL = editor.projectURL else {
            let had = asset.proxyStatus != .none
            setStatus(.none, on: asset)
            return had
        }
        let assetId = asset.id
        let removed = try await editor.removeProjectPackageItem(
            relativePath: ProxyPlan.relativePath(assetId: assetId), in: projectURL
        )
        let had = asset.proxyStatus != .none
        setStatus(.none, on: asset)
        refreshPlaybackIfProxied()
        return removed || had
    }

    @discardableResult
    func removeAllProxies() async throws -> [String] {
        cancelAll()
        var cleared: [String] = []
        for asset in editor?.mediaAssets ?? [] where asset.proxyStatus != .none {
            setStatus(.none, on: asset)
            cleared.append(asset.id)
        }
        if let editor, let projectURL = editor.projectURL {
            _ = try await editor.removeProjectPackageItem(
                relativePath: Project.proxyDirectoryName, in: projectURL
            )
        }
        refreshPlaybackIfProxied()
        return cleared
    }

    private func pump() {
        while tasks.count < Self.maxConcurrent, !waitingIds.isEmpty {
            let assetId = waitingIds.removeFirst()
            guard let asset = editor?.mediaAssetsById[assetId], asset.proxyStatus == .queued else { continue }
            start(asset)
        }
    }

    private func start(_ asset: MediaAsset) {
        guard let editor, let projectURL = editor.projectURL else {
            setStatus(.none, on: asset)
            return
        }
        let assetId = asset.id
        let sourceURL = asset.url
        nextRunId += 1
        let runId = nextRunId
        setStatus(.generating, on: asset)
        generatingIds.append(assetId)
        runIds[assetId] = runId
        tasks[assetId] = Task { [weak self] in
            let outcome = await self?.generate(
                assetId: assetId, sourceURL: sourceURL, projectURL: projectURL
            )
            guard let self, self.runIds[assetId] == runId else { return }
            self.runIds[assetId] = nil
            self.tasks[assetId] = nil
            self.generatingIds.removeAll { $0 == assetId }
            if let outcome, let asset = self.editor?.mediaAssetsById[assetId], asset.proxyStatus == .generating {
                self.setStatus(outcome, on: asset)
                if outcome == .ready { self.refreshPlaybackIfProxied() }
            }
            self.pump()
        }
    }

    private func generate(assetId: String, sourceURL: URL, projectURL: URL) async -> ProxyStatus {
        let stagedURL = FileIO.temporaryFileURL(pathExtension: "mov")
        do {
            _ = try await transcode(sourceURL, stagedURL)
            try Task.checkCancellation()
            guard isCurrent(assetId: assetId, sourceURL: sourceURL, projectURL: projectURL) else {
                removeStagedFile(stagedURL)
                return .none
            }
            guard let editor else {
                removeStagedFile(stagedURL)
                return .none
            }
            _ = try await editor.commitStagedProjectMedia(
                stagedURL,
                filename: ProxyPlan.filename(assetId: assetId),
                directory: Project.proxyDirectoryName
            )
            guard isCurrent(assetId: assetId, sourceURL: sourceURL, projectURL: projectURL) else { return .none }
            Log.project.notice("proxy ready asset=\(assetId.prefix(8))")
            return .ready
        } catch is CancellationError {
            removeStagedFile(stagedURL)
            return .none
        } catch {
            removeStagedFile(stagedURL)
            Log.project.error("proxy failed asset=\(assetId.prefix(8)): \(Log.detail(error))")
            return .failed(error.localizedDescription)
        }
    }

    private func isCurrent(assetId: String, sourceURL: URL, projectURL: URL) -> Bool {
        guard let editor, let asset = editor.mediaAssetsById[assetId] else { return false }
        return asset.url == sourceURL
            && editor.projectURL?.standardizedFileURL == projectURL.standardizedFileURL
    }

    private func removeStagedFile(_ url: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func setStatus(_ status: ProxyStatus, on asset: MediaAsset) {
        guard asset.proxyStatus != status else { return }
        asset.proxyStatus = status
        editor?.queueManifestMetadataUpdate(for: asset)
    }

    private func refreshPlaybackIfProxied() {
        guard let editor, editor.useProxies else { return }
        editor.videoEngine?.rebuild()
    }
}
