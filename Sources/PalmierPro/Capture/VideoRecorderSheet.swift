import AVFoundation
import SwiftUI

@MainActor
@Observable
final class VideoRecorderModel {
    enum Phase: Equatable {
        case preparing
        case ready
        case recording
        case saving
    }

    private enum Defaults {
        static let camera = "recorder.cameraId"
        static let microphone = "recorder.microphoneId"
        static let quality = "recorder.quality"
        static let noMicrophone = "none"
    }

    private(set) var phase: Phase = .preparing
    private(set) var cameras: [CaptureDeviceOption] = []
    private(set) var microphones: [CaptureDeviceOption] = []
    private(set) var qualities: [CaptureQuality] = []
    private(set) var isConfigured = false

    var sessionHandle: CaptureSessionHandle { recorder.sessionHandle }
    private(set) var recordingStartedAt: Date?
    var errorMessage: String?

    var cameraId: String? { didSet { if cameraId != oldValue { reconfigure() } } }
    var microphoneId: String? { didSet { if microphoneId != oldValue { reconfigure() } } }
    var quality: CaptureQuality = .maximum { didSet { if quality != oldValue { reconfigure() } } }

    private let recorder = VideoRecorder()
    private var configureTask: Task<Void, Never>?
    private var applyingPreparation = false

    var canRecord: Bool { (phase == .ready && isConfigured) || phase == .recording }

    func load() async {
        cameras = await VideoRecorder.cameras()
        microphones = await VideoRecorder.microphones()
        let defaults = UserDefaults.standard
        applyingPreparation = true
        cameraId = defaults.string(forKey: Defaults.camera).flatMap { id in
            cameras.contains { $0.id == id } ? id : nil
        } ?? cameras.first?.id
        let storedMicrophone = defaults.string(forKey: Defaults.microphone)
        microphoneId = storedMicrophone == Defaults.noMicrophone
            ? nil
            : (storedMicrophone.flatMap { id in microphones.contains { $0.id == id } ? id : nil }
                ?? microphones.first?.id)
        quality = defaults.string(forKey: Defaults.quality).flatMap(CaptureQuality.init(rawValue:)) ?? .maximum
        applyingPreparation = false
        reconfigure()
    }

    func toggleRecording(editor: EditorViewModel) {
        switch phase {
        case .ready: startRecording()
        case .recording: finishRecording(editor: editor)
        case .preparing, .saving: break
        }
    }

    func close() {
        configureTask?.cancel()
        configureTask = nil
        recordingStartedAt = nil
        let recorder = recorder
        Task { @CaptureActor in recorder.teardown() }
    }

    private func reconfigure() {
        guard !applyingPreparation, phase != .recording, phase != .saving else { return }
        configureTask?.cancel()
        phase = .preparing
        errorMessage = nil
        let configuration = CaptureConfiguration(
            cameraId: cameraId,
            microphoneId: microphoneId,
            quality: quality
        )
        let recorder = recorder
        configureTask = Task { @MainActor [weak self] in
            do {
                let preparation = try await recorder.prepare(configuration)
                try Task.checkCancellation()
                self?.apply(preparation)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isConfigured = false
                phase = .ready
            }
        }
    }

    private func apply(_ preparation: CapturePreparation) {
        applyingPreparation = true
        cameraId = preparation.cameraId
        microphoneId = preparation.microphoneId
        qualities = preparation.supportedQualities
        quality = preparation.quality
        applyingPreparation = false
        isConfigured = true
        phase = .ready
        persistSelection()
    }

    private func persistSelection() {
        let defaults = UserDefaults.standard
        defaults.set(cameraId, forKey: Defaults.camera)
        defaults.set(microphoneId ?? Defaults.noMicrophone, forKey: Defaults.microphone)
        defaults.set(quality.rawValue, forKey: Defaults.quality)
    }

    private func startRecording() {
        errorMessage = nil
        let recorder = recorder
        Task { @MainActor [weak self] in
            do {
                try await recorder.startRecording()
                self?.phase = .recording
                self?.recordingStartedAt = .now
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func finishRecording(editor: EditorViewModel) {
        phase = .saving
        recordingStartedAt = nil
        let recorder = recorder
        let folderId = editor.mediaPanelCurrentFolderId
        Task { @MainActor [weak self] in
            do {
                let url = try await recorder.stopRecording()
                let asset = try await editor.importRecordedVideo(at: url, into: folderId)
                editor.mediaPanelToast = MediaPanelToast(message: "Recorded \(asset.name).", kind: .success)
            } catch {
                await recorder.discardStagedFile()
                self?.errorMessage = error.localizedDescription
            }
            self?.phase = .ready
        }
    }
}

struct VideoRecorderSheet: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var isPresented: Bool
    @State private var model = VideoRecorderModel()

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            preview

            row(icon: "video", label: "Camera") {
                Picker("", selection: $model.cameraId) {
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            }
            row(icon: "mic", label: "Microphone") {
                Picker("", selection: $model.microphoneId) {
                    Text("None").tag(String?.none)
                    ForEach(model.microphones) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            }
            row(icon: "ruler", label: "Quality") {
                Picker("", selection: $model.quality) {
                    ForEach(model.qualities) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: AppTheme.Spacing.smMd) {
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer(minLength: AppTheme.Spacing.md)
                recordButton
            }
        }
        .padding(AppTheme.Spacing.lgXl)
        .frame(width: AppTheme.Recorder.sheetWidth)
        .appSheetBackground()
        .task { await model.load() }
        .onDisappear { model.close() }
        .onExitCommand { dismiss() }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.baseColor)
            CapturePreviewLayerView(handle: model.sessionHandle)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            if model.phase == .preparing {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: AppTheme.Recorder.previewHeight)
        .overlay(alignment: .topLeading) {
            if let startedAt = model.recordingStartedAt {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Circle()
                        .fill(AppTheme.Status.errorColor)
                        .frame(width: AppTheme.Recorder.indicatorSize, height: AppTheme.Recorder.indicatorSize)
                    Text(startedAt, style: .timer)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .monospacedDigit()
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(Capsule().fill(AppTheme.Background.prominentColor.opacity(AppTheme.Opacity.prominent)))
                .padding(AppTheme.Spacing.sm)
            }
        }
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording(editor: editor)
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: model.phase == .recording ? "stop.fill" : "record.circle")
                Text(recordButtonTitle)
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Background.baseColor)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(model.phase == .recording ? AppTheme.Status.errorColor : AppTheme.Accent.primary)
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canRecord)
    }

    private var recordButtonTitle: String {
        switch model.phase {
        case .preparing: "Preparing…"
        case .ready: "Record"
        case .recording: "Stop"
        case .saving: "Saving…"
        }
    }

    private func dismiss() {
        guard model.phase != .recording, model.phase != .saving else { return }
        isPresented = false
    }

    private func row<Control: View>(
        icon: String,
        label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.sm)
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.md)
            control()
                .frame(width: AppTheme.Recorder.controlWidth, alignment: .trailing)
        }
    }
}

private struct CapturePreviewLayerView: NSViewRepresentable {
    let handle: CaptureSessionHandle

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: handle.session)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let layer = nsView.layer as? AVCaptureVideoPreviewLayer else { return }
        if layer.session !== handle.session { layer.session = handle.session }
    }
}
