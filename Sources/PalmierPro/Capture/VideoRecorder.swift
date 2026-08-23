import AVFoundation
import Foundation

@globalActor
actor CaptureActor {
    static let shared = CaptureActor()
}

struct CaptureDeviceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum CaptureQuality: String, CaseIterable, Identifiable, Sendable {
    case maximum, uhd4K, hd1080, hd720, sd480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: "Maximum"
        case .uhd4K: "4K"
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        }
    }

    var preset: AVCaptureSession.Preset {
        switch self {
        case .maximum: .high
        case .uhd4K: .hd4K3840x2160
        case .hd1080: .hd1920x1080
        case .hd720: .hd1280x720
        case .sd480: .vga640x480
        }
    }
}

struct CaptureConfiguration: Sendable, Equatable {
    var cameraId: String?
    var microphoneId: String?
    var quality: CaptureQuality = .maximum
}

struct CapturePreparation: Sendable {
    let cameraId: String
    let microphoneId: String?
    let supportedQualities: [CaptureQuality]
    let quality: CaptureQuality
}

/// The session is only mutated on `CaptureActor`; the main actor reads it to attach a preview layer.
struct CaptureSessionHandle: @unchecked Sendable {
    let session: AVCaptureSession
}

/// Holds the capture objects so `VideoRecorder` can create them outside its actor and use them on it.
private struct CaptureBox: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCaptureMovieFileOutput()
}

@CaptureActor
final class VideoRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum RecordingError: LocalizedError {
        case cameraDenied
        case microphoneDenied
        case noCamera
        case cannotConfigure
        case notReady
        case alreadyRecording
        case notRecording

        var errorDescription: String? {
            switch self {
            case .cameraDenied: "Allow camera access in System Settings to record video."
            case .microphoneDenied: "Allow microphone access in System Settings to record sound."
            case .noCamera: "No camera is available."
            case .cannotConfigure: "The selected capture device could not be configured."
            case .notReady: "The capture session is not running."
            case .alreadyRecording: "A video recording is already running."
            case .notRecording: "No video recording is active."
            }
        }
    }

    private nonisolated let box = CaptureBox()
    private var cameraInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var stagedURL: URL?
    private var pending: CheckedContinuation<URL, any Error>?
    private var finished: Result<URL, any Error>?

    nonisolated var sessionHandle: CaptureSessionHandle { CaptureSessionHandle(session: box.session) }

    nonisolated override init() { super.init() }

    private var session: AVCaptureSession { box.session }
    private var output: AVCaptureMovieFileOutput { box.output }

    static func cameras() -> [CaptureDeviceOption] {
        devices(mediaType: .video, types: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera])
    }

    static func microphones() -> [CaptureDeviceOption] {
        devices(mediaType: .audio, types: [.microphone, .external])
    }

    private static func devices(
        mediaType: AVMediaType,
        types: [AVCaptureDevice.DeviceType]
    ) -> [CaptureDeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: mediaType, position: .unspecified)
            .devices
            .map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    func prepare(_ configuration: CaptureConfiguration) async throws -> CapturePreparation {
        guard !output.isRecording else { throw RecordingError.cannotConfigure }
        guard await Self.authorize(.video) else { throw RecordingError.cameraDenied }
        if configuration.microphoneId != nil, await Self.authorize(.audio) == false {
            throw RecordingError.microphoneDenied
        }
        try Task.checkCancellation()

        guard let camera = configuration.cameraId.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? AVCaptureDevice.default(for: .video) else { throw RecordingError.noCamera }

        session.beginConfiguration()

        if cameraInput?.device.uniqueID != camera.uniqueID {
            if let cameraInput { session.removeInput(cameraInput) }
            cameraInput = nil
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw RecordingError.cannotConfigure
            }
            session.addInput(input)
            cameraInput = input
        }

        if microphoneInput?.device.uniqueID != configuration.microphoneId {
            if let microphoneInput { session.removeInput(microphoneInput) }
            microphoneInput = nil
            if let requested = configuration.microphoneId,
               let microphone = AVCaptureDevice(uniqueID: requested),
               let input = try? AVCaptureDeviceInput(device: microphone),
               session.canAddInput(input) {
                session.addInput(input)
                microphoneInput = input
            }
        }
        let microphoneId = microphoneInput?.device.uniqueID

        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }

        let supported = CaptureQuality.allCases.filter { session.canSetSessionPreset($0.preset) }
        let quality = supported.contains(configuration.quality) ? configuration.quality : (supported.first ?? .maximum)
        session.sessionPreset = quality.preset
        session.commitConfiguration()

        if !session.isRunning { session.startRunning() }

        return CapturePreparation(
            cameraId: camera.uniqueID,
            microphoneId: microphoneId,
            supportedQualities: supported,
            quality: quality
        )
    }

    func startRecording() throws {
        guard session.isRunning else { throw RecordingError.notReady }
        guard !output.isRecording else { throw RecordingError.alreadyRecording }
        finished = nil
        let url = FileIO.temporaryFileURL(pathExtension: "mov")
        stagedURL = url
        output.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() async throws -> URL {
        if let finished {
            self.finished = nil
            return try finished.get()
        }
        guard output.isRecording else { throw RecordingError.notRecording }
        let url = try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            output.stopRecording()
        }
        stagedURL = nil
        return url
    }

    func teardown() {
        if output.isRecording { output.stopRecording() }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        cameraInput = nil
        microphoneInput = nil
        if let pending {
            self.pending = nil
            pending.resume(throwing: CancellationError())
        }
        discardStagedFile()
        finished = nil
    }

    func discardStagedFile() {
        guard let stagedURL else { return }
        self.stagedURL = nil
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stagedURL) }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        let failure = error
        Task { @CaptureActor [weak self] in
            self?.complete(url: outputFileURL, error: failure)
        }
    }

    private func complete(url: URL, error: (any Error)?) {
        let result: Result<URL, any Error>
        if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
            result = .failure(error)
        } else {
            result = .success(url)
        }
        if let pending {
            self.pending = nil
            pending.resume(with: result)
        } else {
            finished = result
        }
    }

    private static func authorize(_ mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: mediaType)
        case .denied, .restricted: false
        @unknown default: false
        }
    }
}
