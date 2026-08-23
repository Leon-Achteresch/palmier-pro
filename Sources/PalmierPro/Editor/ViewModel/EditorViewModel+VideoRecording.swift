import Foundation

extension EditorViewModel {
    enum VideoRecordingImportError: LocalizedError {
        case unreadableRecording

        var errorDescription: String? {
            switch self {
            case .unreadableRecording:
                "The recording could not be read."
            }
        }
    }

    @discardableResult
    func importRecordedVideo(at stagedURL: URL, into folderId: String?) async throws -> MediaAsset {
        try projectPackageCoordinator.beginMutation()
        defer { projectPackageCoordinator.endMutation() }

        let filename = "recording-\(UUID().uuidString.prefix(8)).mov"
        let committedURL = try await commitStagedProjectMedia(
            stagedURL,
            filename: filename,
            workAlreadyAdmitted: true
        )

        let name = "Video Recording \(Date.now.formatted(date: .omitted, time: .standard))"
        let asset = MediaAsset(url: committedURL, type: .video, name: name)
        asset.folderId = folderId
        guard await asset.loadMetadata(includeThumbnail: true),
              asset.duration.isFinite,
              asset.duration > 0 else {
            throw VideoRecordingImportError.unreadableRecording
        }

        let before = mediaLibraryUndoSnapshot()
        undo.perform("Record Video") {
            importMediaAsset(asset)
            undo.register("Record Video", withTarget: self) { editor in
                editor.restoreMediaLibraryUndoSnapshot(before, actionName: "Record Video")
            }
        }
        searchIndex.schedule(asset)
        prepareMediaVisuals(for: asset)
        onProjectCheckpointRequired?()
        return asset
    }
}
