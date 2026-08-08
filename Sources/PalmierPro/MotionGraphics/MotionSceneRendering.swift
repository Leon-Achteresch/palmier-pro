import CoreGraphics

/// The bake loop, cache and encoder are shared by every runtime; only frame production differs.
@MainActor
protocol MotionSceneRendering: AnyObject {
    func load(scene: MotionScene) async throws
    func seek(toMilliseconds milliseconds: Double) async throws
    func assertSceneHealthy() async throws
    func snapshot() async throws -> CGImage
    func tearDown()
}

extension MotionSceneRenderer: MotionSceneRendering {}

enum MotionSceneRendererFactory {
    @MainActor
    static func renderer(for scene: MotionScene) async throws -> any MotionSceneRendering {
        switch scene.runtime {
        case .web:
            return MotionSceneRenderer(size: scene.size, runtimeHTML: try await MotionSceneRenderer.loadRuntimeHTML())
        case .reactNative:
            #if REACT_NATIVE
            return try ReactNativeSceneRenderer(size: scene.size)
            #else
            throw MotionSceneError.reactNativeUnavailable
            #endif
        }
    }
}
