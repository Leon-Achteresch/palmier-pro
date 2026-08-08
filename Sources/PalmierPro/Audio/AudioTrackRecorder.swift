import AVFoundation
import Foundation

struct AudioTrackRecordingResult: Sendable {
    let stagedURL: URL
    let duration: Double
}

actor AudioTrackRecorder {
    enum RecordingError: LocalizedError {
        case microphoneDenied
        case recorderUnavailable
        case couldNotStart
        case notRecording
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Allow microphone access in System Settings to record audio."
            case .recorderUnavailable:
                "No audio input is available."
            case .couldNotStart:
                "Could not start audio recording."
            case .notRecording:
                "No audio recording is active."
            case .emptyRecording:
                "The recording did not contain any audio."
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private var stagedURL: URL?

    func start() async throws {
        guard recorder == nil else { throw RecordingError.couldNotStart }
        guard await Self.requestMicrophoneAccess() else {
            throw RecordingError.microphoneDenied
        }
        try Task.checkCancellation()

        let url = FileIO.temporaryFileURL(pathExtension: "caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.prepareToRecord() else {
                throw RecordingError.recorderUnavailable
            }
            try Task.checkCancellation()
            guard recorder.record() else {
                throw RecordingError.couldNotStart
            }
            self.recorder = recorder
            stagedURL = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func finish() throws -> AudioTrackRecordingResult {
        guard let recorder, let stagedURL else { throw RecordingError.notRecording }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.stagedURL = nil
        guard duration.isFinite, duration > 0 else {
            try? FileManager.default.removeItem(at: stagedURL)
            throw RecordingError.emptyRecording
        }
        return AudioTrackRecordingResult(stagedURL: stagedURL, duration: duration)
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let stagedURL {
            try? FileManager.default.removeItem(at: stagedURL)
        }
        stagedURL = nil
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}
