#if REACT_NATIVE

import CoreGraphics
import Foundation
import PalmierRNHost

/// Renders a scene through react-native-macos: real RN views laid out by Yoga, mounted by Fabric,
/// snapshotted from an offscreen window. Frame production only; the bake loop is shared.
@MainActor
final class ReactNativeSceneRenderer: MotionSceneRendering {
    private let surface: PalmierRNSurface
    private let size: CGSize
    private var started = false

    // ponytail: fixed settle windows rather than a mount callback — RN exposes surface stage only
    // through C++ Fabric internals. Swap for RCTSurfaceDelegate if a scene ever outruns these.
    private static let startupSettle = Duration.milliseconds(1500)
    private static let seekSettle = Duration.milliseconds(40)

    init(size: CGSize) throws {
        guard let bundleURL = Bundle.module.url(forResource: "main", withExtension: "jsbundle", subdirectory: "RNRuntime")
        else { throw MotionSceneError.runtimeMissing }

        self.size = size
        self.surface = PalmierRNSurface(
            bundleURL: bundleURL,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
    }

    func load(scene: MotionScene) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            surface.start(withSceneSource: scene.source, fps: scene.fps) { error in
                if let error { continuation.resume(throwing: MotionSceneError.sceneFailed(error.localizedDescription)) }
                else { continuation.resume() }
            }
        }
        started = true
        try await Task.sleep(for: Self.startupSettle)
        try assertNoSceneError()
    }

    func seek(toMilliseconds milliseconds: Double) async throws {
        guard started else { throw MotionSceneError.sceneFailed("scene was never loaded") }
        surface.seek(toMilliseconds: milliseconds)
        try await Task.sleep(for: Self.seekSettle)
    }

    func assertSceneHealthy() async throws {
        try assertNoSceneError()
    }

    func snapshot() async throws -> CGImage {
        try assertNoSceneError()
        guard let image = surface.copySnapshot() else {
            throw MotionSceneError.snapshotFailed
        }
        return image
    }

    func tearDown() {
        started = false
    }

    private func assertNoSceneError() throws {
        if let error = surface.sceneError {
            throw MotionSceneError.sceneFailed(error)
        }
    }
}

#endif
