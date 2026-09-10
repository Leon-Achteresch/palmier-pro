import AppKit

/// The bake loop, cache and encoder are shared by every runtime; only frame production differs.
@MainActor
protocol MotionSceneRendering: AnyObject {
    var presentationView: NSView { get }
    func load(scene: MotionScene) async throws
    func seek(toMilliseconds milliseconds: Double) async throws
    func assertSceneHealthy() async throws
    func snapshot() async throws -> CGImage
    func slotBounds() async throws -> [MotionSlotBounds]
    func tearDown()
}

struct MotionSlotBounds: Codable, Sendable, Identifiable {
    var nodeID: String
    var slotID: String
    var bounds: MotionEvaluatedNode.Bounds
    var parentMatrix: [Double]
    var id: String { nodeID + "/" + slotID }
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
            return ReactNativeSceneRenderer(size: scene.size, bundleURL: try await reactNativeBundleURL())
            #else
            throw MotionSceneError.reactNativeUnavailable
            #endif
        }
    }

    @concurrent private static func reactNativeBundleURL() async throws -> URL {
        guard let url = BundledResource.url("RNRuntime/main.jsbundle") else { throw MotionSceneError.runtimeMissing }
        return url
    }
}
