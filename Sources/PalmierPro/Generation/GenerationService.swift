import Foundation

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

@MainActor
final class GenerationService {

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> GenerationParams,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for outputIndex in 0..<count {
            var placeholderInput = genInput
            placeholderInput.outputIndex = outputIndex
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: placeholderInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id
        captureSubmission(genInput: genInput, assetType: assetType, outputCount: count, editor: editor)

        Task { @MainActor in
            await self.runOwnKeyJob(
                placeholders: placeholders,
                buildParams: buildParams,
                genInput: genInput,
                references: references,
                trimmedSource: trimmedSourceOverride,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        return primaryId
    }

    private func captureSubmission(
        genInput: GenerationInput,
        assetType: ClipType,
        outputCount: Int,
        editor: EditorViewModel
    ) {
        var payload = Analytics.originProperties()
        payload["project_id"] = editor.projectId ?? "unknown"
        payload["model"] = genInput.model
        payload["generation_type"] = Self.generationType(assetType: assetType, genInput: genInput)
        payload["output_count"] = outputCount
        Analytics.capture(.generationSubmitted, properties: payload)
    }

    nonisolated static func generationType(assetType: ClipType, genInput: GenerationInput) -> String {
        genInput.upscaleSettings == nil ? assetType.rawValue : "upscale"
    }

    private static func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .preparing
        placeholder.folderId = folderId
        editor.importMediaAsset(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            return projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    private func installGeneratedFile(
        asset: MediaAsset,
        stagedURL: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) async throws -> Bool {
        if !fileExtension.isEmpty, fileExtension != asset.url.pathExtension.lowercased(),
           ClipType(fileExtension: fileExtension) != nil {
            asset.url = asset.url.deletingPathExtension().appendingPathExtension(fileExtension)
        }
        asset.url = try await editor.commitStagedProjectMedia(stagedURL, filename: asset.url.lastPathComponent)

        editor.importMediaAsset(asset, skipAppend: true)
        return await editor.finalizeImportedAsset(asset)
    }

    /// Runs a job on the user's own provider key — no backend job, no credits.
    private func runOwnKeyJob(
        placeholders: [MediaAsset],
        buildParams: ([String]) -> GenerationParams,
        genInput: GenerationInput,
        references: [MediaAsset],
        trimmedSource: TrimmedSource?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        func fail(_ message: String, placeholders: [MediaAsset]) {
            Log.generation.error("own-key job failed model=\(genInput.model) error=\(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
        }

        var input = genInput
        if input.createdAt == nil { input.createdAt = Date() }
        for (outputIndex, placeholder) in placeholders.enumerated() {
            var stored = input
            stored.outputIndex = outputIndex
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { current in
                current = stored
            }
        }
        editor.onProjectCheckpointRequired?()

        var files: [URL] = []
        do {
            files = try await OwnKeyGeneration.run(
                modelId: genInput.model,
                buildParams: buildParams,
                references: references,
                trimmedSource: trimmedSource
            )
        } catch {
            fail(error.localizedDescription, placeholders: placeholders)
            return
        }
        guard !files.isEmpty else {
            fail("The provider returned no file", placeholders: placeholders)
            return
        }

        var finalized: [MediaAsset] = []
        var unfinished: [MediaAsset] = []
        var failure: String?
        for (index, placeholder) in placeholders.enumerated() {
            let outputIndex = placeholder.generationInput?.outputIndex ?? index
            guard outputIndex < files.count else {
                unfinished.append(placeholder)
                continue
            }
            let file = files[outputIndex]
            do {
                if try await installGeneratedFile(
                    asset: placeholder,
                    stagedURL: file,
                    fileExtension: file.pathExtension.lowercased(),
                    editor: editor
                ) {
                    onComplete?(placeholder)
                    finalized.append(placeholder)
                } else {
                    unfinished.append(placeholder)
                }
            } catch {
                failure = error.localizedDescription
                unfinished.append(placeholder)
            }
        }
        Self.cleanupTempFiles(Array(files.dropFirst(placeholders.count)))

        if !unfinished.isEmpty {
            fail(failure ?? "No output for this placeholder", placeholders: unfinished)
        }
        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        }
    }

    /// Own-key jobs have no resumable server job; a relaunch means the request is gone.
    func resumePendingGenerations(editor: EditorViewModel) {
        for asset in editor.mediaAssets where asset.isGenerating {
            updateGenerationMetadata(
                asset, editor: editor,
                status: .failed("Generation was interrupted. Run it again.")
            )
        }
    }

    private func updateGenerationMetadata(
        _ asset: MediaAsset,
        editor: EditorViewModel,
        status: MediaAsset.GenerationStatus? = nil,
        mutateInput: ((inout GenerationInput) -> Void)? = nil
    ) {
        if let status {
            asset.generationStatus = status
        }
        if let mutateInput, var input = asset.generationInput {
            mutateInput(&input)
            asset.generationInput = input
        }
        editor.updateManifestMetadata(for: [asset])
    }

}
