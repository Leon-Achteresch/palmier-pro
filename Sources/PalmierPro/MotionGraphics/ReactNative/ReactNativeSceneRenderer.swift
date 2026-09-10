#if REACT_NATIVE

import AppKit
import Foundation
import PalmierRNHost

@MainActor
final class ReactNativeSceneRenderer: MotionSceneRendering {
    private let surface: PalmierRNSurface
    private var started = false
    private var cancelPending: ((any Error) -> Void)?
    private var requestID: UUID?

    init(size: CGSize, bundleURL: URL) {
        self.surface = PalmierRNSurface(
            bundleURL: bundleURL,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
    }

    var presentationView: NSView { surface.presentationView }

    func load(scene: MotionScene) async throws {
        let json = try await scene.runtimeJSON()
        guard await Self.prepareRuntime() else { throw MotionSceneError.sceneFailed("native rendering filters are unavailable") }
        try Task.checkCancellation()
        if started {
            try await request { completion in surface.updateDocument(json) { error in completion(error.map { .failure($0) } ?? .success(())) } }
        } else {
            let source = "export default function Scene() { return React.createElement(PalmierMotion.SceneDocument, {document: " + json + "}); }"
            try await request { completion in
                surface.start(withSceneSource: source, fps: scene.fps, durationInFrames: scene.durationInFrames) { error in completion(error.map { .failure($0) } ?? .success(())) }
            }
            started = true
        }
        try assertNoSceneError()
    }

    func seek(toMilliseconds milliseconds: Double) async throws {
        guard started else { throw MotionSceneError.sceneFailed("scene was never loaded") }
        try await request { completion in surface.seek(toMilliseconds: milliseconds) { error in completion(error.map { .failure($0) } ?? .success(())) } }
    }

    func assertSceneHealthy() async throws {
        try assertNoSceneError()
    }

    func slotBounds() async throws -> [MotionSlotBounds] {
        try JSONDecoder().decode([MotionSlotBounds].self, from: Data(surface.slotBoundsJSON.utf8))
    }

    func snapshot() async throws -> CGImage {
        try assertNoSceneError()
        let image: CGImage = try await request { completion in
            surface.captureSnapshot { image, error in
                if let error { completion(.failure(error)) }
                else if let image { completion(.success(image)) }
                else { completion(.failure(MotionSceneError.snapshotFailed)) }
            }
        }
        try Task.checkCancellation()
        guard started else { throw CancellationError() }
        return image
    }

    func tearDown() {
        started = false
        surface.tearDown()
        if let requestID { cancelRequest(CancellationError(), id: requestID) }
    }

    private func request<Value: Sendable>(_ start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
        try Task.checkCancellation()
        guard requestID == nil else { throw MotionSceneError.sceneFailed("a render request is already running") }
        let id = UUID()
        requestID = id
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard self.requestID == id else { return }
            let error = self.surface.sceneError.map(MotionSceneError.sceneFailed) ?? .renderTimedOut
            self.cancelRequest(error, id: id)
            self.surface.tearDown()
            self.started = false
        }
        defer { timeout.cancel() }
        let result: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); requestID = nil; return }
                cancelPending = { continuation.resume(throwing: $0) }
                start { result in
                    Task { @MainActor in
                        guard self.takeRequest(id) else { return }
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in if self.requestID == id { self.tearDown() } }
        }
        try Task.checkCancellation()
        return result
    }

    private func takeRequest(_ id: UUID) -> Bool {
        guard requestID == id else { return false }
        requestID = nil
        cancelPending = nil
        return true
    }

    private func cancelRequest(_ error: any Error, id: UUID) {
        let cancel = cancelPending
        guard takeRequest(id) else { return }
        cancel?(error)
    }

    @concurrent private static func prepareRuntime() async -> Bool { PalmierRNHost.prepareRendering() }

    private func assertNoSceneError() throws {
        if let error = surface.sceneError {
            throw MotionSceneError.sceneFailed(error)
        }
    }
}

#endif
