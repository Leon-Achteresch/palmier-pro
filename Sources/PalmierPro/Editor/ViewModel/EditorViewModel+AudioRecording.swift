import AppKit
import Foundation

extension EditorViewModel {
    private struct PersistedAudioRecording {
        let asset: MediaAsset
        let warning: String?
    }

    enum AudioRecordingPlacementError: LocalizedError {
        case invalidAsset
        case invalidDuration
        case invalidStartFrame
        case timelineRemoved
        case trackRemoved
        case trackIsNotAudio

        var errorDescription: String? {
            switch self {
            case .invalidAsset:
                "The recording is not an audio asset."
            case .invalidDuration:
                "The recording has no finite duration."
            case .invalidStartFrame:
                "The recording start position is invalid."
            case .timelineRemoved:
                "The recording's timeline is no longer available."
            case .trackRemoved:
                "The recording's audio track is no longer available."
            case .trackIsNotAudio:
                "The recording target is not an audio track."
            }
        }
    }

    enum AudioRecordingCloseError: LocalizedError {
        case couldNotFinish(String)

        var errorDescription: String? {
            switch self {
            case .couldNotFinish(let reason):
                "Could not finish audio recording: \(reason)"
            }
        }
    }

    func toggleAudioRecording(trackId: String) {
        switch audioRecordingState {
        case .idle:
            startAudioRecording(trackId: trackId)
        case .starting, .recording:
            if audioRecordingState.trackId == trackId {
                if case .recording = audioRecordingState {
                    finishAudioRecording(showFeedback: true)
                } else {
                    cancelAudioRecording()
                }
            }
        case .finalizing:
            break
        }
    }

    func cancelAudioRecording() {
        guard audioRecordingState.canCancel else { return }
        let state = audioRecordingState
        let session: AudioRecordingSession
        switch state {
        case .starting(let value), .recording(let value):
            session = value
        case .idle, .finalizing:
            return
        }
        let pendingTransition = audioRecordingTransitionTask
        pendingTransition?.cancel()
        if case .recording(let session) = state,
           session.shouldPausePlaybackWhenFinished {
            pause()
        }
        audioRecordingState = .finalizing(session)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await pendingTransition?.value
            await audioTrackRecorder.cancel()
            if audioRecordingState == .finalizing(session) {
                audioRecordingState = .idle
                audioRecordingTransitionTask = nil
            }
        }
        audioRecordingTransitionTask = task
    }

    func finishAudioRecordingBeforeClose() async throws {
        let task: Task<Void, Never>?
        switch audioRecordingState {
        case .idle:
            return
        case .starting:
            cancelAudioRecording()
            task = audioRecordingTransitionTask
        case .recording:
            task = finishAudioRecording(showFeedback: false)
        case .finalizing:
            task = audioRecordingTransitionTask
        }
        await task?.value
        if let audioRecordingFailureMessage {
            throw AudioRecordingCloseError.couldNotFinish(audioRecordingFailureMessage)
        }
    }

    @discardableResult
    func placeRecordedAudioAsset(
        _ asset: MediaAsset,
        timelineId: String,
        trackId: String,
        startFrame: Int
    ) throws -> String {
        guard asset.type == .audio else { throw AudioRecordingPlacementError.invalidAsset }
        guard asset.duration.isFinite, asset.duration > 0 else {
            throw AudioRecordingPlacementError.invalidDuration
        }
        guard startFrame >= 0 else { throw AudioRecordingPlacementError.invalidStartFrame }
        guard let targetTimeline = timeline(for: timelineId) else {
            throw AudioRecordingPlacementError.timelineRemoved
        }
        guard targetTimeline.fps > 0,
              asset.duration <= Double(Int.max) / Double(targetTimeline.fps) else {
            throw AudioRecordingPlacementError.invalidDuration
        }
        guard let targetTrack = targetTimeline.tracks.first(where: { $0.id == trackId }) else {
            throw AudioRecordingPlacementError.trackRemoved
        }
        guard targetTrack.type == .audio else {
            throw AudioRecordingPlacementError.trackIsNotAudio
        }

        let before = mediaLibraryUndoSnapshot()
        var clipId: String?
        undo.perform("Record Audio") {
            undo.withoutRegistration {
                if activeTimelineId != timelineId {
                    activateTimeline(timelineId)
                }
                guard let trackIndex = timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
                importMediaAsset(asset)
                addClips(assets: [asset], trackIndex: trackIndex, startFrame: startFrame)
                clipId = timeline.tracks
                    .flatMap(\.clips)
                    .first(where: { $0.mediaRef == asset.id })?
                    .id
                if let clipId {
                    selectedClipIds = [clipId]
                }
            }
            guard clipId != nil else { return }
            undo.register("Record Audio", withTarget: self) { editor in
                editor.restoreMediaLibraryUndoSnapshot(before, actionName: "Record Audio")
            }
        }

        guard let clipId else { throw AudioRecordingPlacementError.trackRemoved }
        searchIndex.schedule(asset)
        notifyTimelineChanged()
        onProjectCheckpointRequired?()
        return clipId
    }

    private func startAudioRecording(trackId: String) {
        guard audioRecordingState == .idle,
              let track = timeline.tracks.first(where: { $0.id == trackId }),
              track.type == .audio else { return }

        audioRecordingFailureMessage = nil
        let session = AudioRecordingSession(
            id: UUID(),
            timelineId: activeTimelineId,
            trackId: trackId,
            startFrame: max(0, currentFrame),
            shouldPausePlaybackWhenFinished: !isPlaying
        )
        audioRecordingState = .starting(session)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await audioTrackRecorder.start()
                try Task.checkCancellation()
                guard audioRecordingState == .starting(session),
                      timeline(for: session.timelineId)?.tracks.contains(where: {
                          $0.id == session.trackId && $0.type == .audio
                      }) == true else {
                    await audioTrackRecorder.cancel()
                    if audioRecordingState == .starting(session) {
                        audioRecordingState = .idle
                        audioRecordingTransitionTask = nil
                        presentAudioRecordingFailure(
                            AudioRecordingPlacementError.trackRemoved.localizedDescription
                        )
                    }
                    return
                }
                audioRecordingState = .recording(session)
                if session.shouldPausePlaybackWhenFinished {
                    play()
                }
            } catch is CancellationError {
                await audioTrackRecorder.cancel()
                if audioRecordingState == .starting(session) {
                    audioRecordingState = .idle
                }
            } catch {
                await audioTrackRecorder.cancel()
                audioRecordingFailureMessage = error.localizedDescription
                if audioRecordingState == .starting(session) {
                    audioRecordingState = .idle
                }
                presentAudioRecordingFailure(error.localizedDescription)
            }
            if audioRecordingState != .finalizing(session) {
                audioRecordingTransitionTask = nil
            }
        }
        audioRecordingTransitionTask = task
    }

    @discardableResult
    private func finishAudioRecording(showFeedback: Bool) -> Task<Void, Never>? {
        guard case .recording(let session) = audioRecordingState else {
            return audioRecordingTransitionTask
        }
        if session.shouldPausePlaybackWhenFinished {
            pause()
        }
        audioRecordingState = .finalizing(session)
        audioRecordingFailureMessage = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await audioTrackRecorder.finish()
                let persisted = try await persistAudioRecording(result, session: session)
                audioRecordingState = .idle
                if showFeedback {
                    if let warning = persisted.warning {
                        mediaPanelToast = MediaPanelToast(message: warning, kind: .warning)
                    } else {
                        mediaPanelToast = MediaPanelToast(
                            message: "Recorded \(persisted.asset.name).",
                            kind: .success
                        )
                    }
                }
            } catch {
                await audioTrackRecorder.cancel()
                audioRecordingFailureMessage = error.localizedDescription
                audioRecordingState = .idle
                if showFeedback {
                    presentAudioRecordingFailure(error.localizedDescription)
                }
            }
            audioRecordingTransitionTask = nil
        }
        audioRecordingTransitionTask = task
        return task
    }

    private func persistAudioRecording(
        _ result: AudioTrackRecordingResult,
        session: AudioRecordingSession
    ) async throws -> PersistedAudioRecording {
        let name = "Audio Recording \(Date.now.formatted(date: .omitted, time: .standard))"
        let asset = MediaAsset(
            url: result.stagedURL,
            type: .audio,
            name: name,
            duration: result.duration
        )
        guard await asset.loadMetadata(includeThumbnail: false),
              asset.duration.isFinite,
              asset.duration > 0 else {
            await discardStagedRecording(at: result.stagedURL)
            throw AudioRecordingPlacementError.invalidDuration
        }

        do {
            try projectPackageCoordinator.beginMutation()
        } catch {
            await discardStagedRecording(at: result.stagedURL)
            throw error
        }
        defer { projectPackageCoordinator.endMutation() }

        let filename = "recording-\(UUID().uuidString.prefix(8)).caf"
        let committedURL = try await commitStagedProjectMedia(
            result.stagedURL,
            filename: filename,
            workAlreadyAdmitted: true
        )
        asset.url = committedURL

        do {
            _ = try placeRecordedAudioAsset(
                asset,
                timelineId: session.timelineId,
                trackId: session.trackId,
                startFrame: session.startFrame
            )
            return PersistedAudioRecording(asset: asset, warning: nil)
        } catch let error as AudioRecordingPlacementError {
            importRecordedAudioAsset(asset)
            return PersistedAudioRecording(
                asset: asset,
                warning: "\(error.localizedDescription) The recording was saved in Media."
            )
        }
    }

    private func importRecordedAudioAsset(_ asset: MediaAsset) {
        let before = mediaLibraryUndoSnapshot()
        undo.perform("Record Audio") {
            importMediaAsset(asset)
            undo.register("Record Audio", withTarget: self) { editor in
                editor.restoreMediaLibraryUndoSnapshot(before, actionName: "Record Audio")
            }
        }
        searchIndex.schedule(asset)
        prepareMediaVisuals(for: asset)
        onProjectCheckpointRequired?()
    }

    @concurrent
    private func discardStagedRecording(at url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    private func presentAudioRecordingFailure(_ message: String) {
        mediaPanelToast = MediaPanelToast(message: message)
        NSSound.beep()
    }
}
