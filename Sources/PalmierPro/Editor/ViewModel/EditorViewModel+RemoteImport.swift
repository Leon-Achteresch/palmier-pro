import Foundation

extension EditorViewModel {
    nonisolated static let remoteImportMaxBytes: Int64 = 5 * 1024 * 1024 * 1024
    nonisolated static let remoteImportRequestTimeout: TimeInterval = 15 * 60

    @discardableResult
    func importRemoteMedia(
        url: URL,
        type: ClipType,
        fileExtension: String,
        name: String,
        folderId: String? = nil
    ) -> MediaAsset? {
        guard let projectURL else { return nil }
        let id = UUID().uuidString
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let destURL = mediaDir.appendingPathComponent("imported-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(id: id, url: destURL, type: type, name: name)
        placeholder.folderId = folderId
        placeholder.importInput = MediaImportInput(sourceURL: url.absoluteString, createdAt: Date())
        placeholder.generationStatus = .downloading
        importMediaAsset(placeholder)
        onProjectCheckpointRequired?()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.downloadRemoteImport(asset: placeholder, remoteURL: url)
        }
        return placeholder
    }

    private func downloadRemoteImport(asset: MediaAsset, remoteURL: URL) async {
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = Self.remoteImportRequestTimeout
            let delegate = RemoteImportDownloadDelegate(maxBytes: Self.remoteImportMaxBytes)
            let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)

            if let httpResp = response as? HTTPURLResponse, !(200..<300).contains(httpResp.statusCode) {
                await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: tempURL)
                }.value
                throw RemoteImportError(message: "server returned HTTP \(httpResp.statusCode)")
            }

            asset.url = try await commitStagedProjectMedia(
                tempURL,
                filename: asset.url.lastPathComponent,
                maxBytes: Self.remoteImportMaxBytes
            )
            let finalized = await finalizeImportedAsset(asset)
            guard finalized else {
                onProjectCheckpointRequired?()
                return
            }
            asset.importInput = nil
            updateManifestMetadata(for: [asset])
            onProjectCheckpointRequired?()
        } catch {
            let message = (error as? RemoteImportError)?.message ?? error.localizedDescription
            Log.project.error("remote import download failed url=\(remoteURL.absoluteString) error=\(message)")
            asset.generationStatus = .failed(message)
            updateManifestMetadata(for: [asset])
            onProjectCheckpointRequired?()
        }
    }
}

struct RemoteImportError: Error, Sendable {
    let message: String
}

fileprivate final class RemoteImportDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maxBytes: Int64
    init(maxBytes: Int64) { self.maxBytes = maxBytes }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maxBytes {
            downloadTask.cancel()
            return
        }
        if totalBytesWritten > maxBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // No-op: the async download(for:delegate:) API copies the temp file for us.
    }
}
