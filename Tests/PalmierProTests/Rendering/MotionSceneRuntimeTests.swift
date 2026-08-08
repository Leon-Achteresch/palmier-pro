import Foundation
import Testing

@testable import PalmierPro

@Suite struct MotionSceneRuntimeTests {
    private func scene(_ runtime: MotionSceneRuntime) -> MotionScene {
        MotionScene(
            width: 640,
            height: 360,
            fps: 30,
            durationInFrames: 30,
            source: "export default function Scene() { return null }",
            runtime: runtime
        )
    }

    @Test func defaultsToTheWebRuntime() {
        #expect(scene(.web).runtime == .web)
        #expect(
            MotionScene(width: 640, height: 360, fps: 30, durationInFrames: 30, source: "x").runtime == .web
        )
    }

    @Test func scenesWrittenBeforeTheRuntimeKeyStillLoad() throws {
        let legacy = """
        {"version":1,"width":640,"height":360,"fps":30,"durationInFrames":30,"source":"export default function Scene() { return null }"}
        """
        let decoded = try MotionScene.decoded(from: Data(legacy.utf8))
        #expect(decoded.runtime == .web)
    }

    @Test func runtimeSurvivesARoundTrip() throws {
        let decoded = try MotionScene.decoded(from: try scene(.reactNative).encoded())
        #expect(decoded.runtime == .reactNative)
    }

    @Test func runtimeChangesTheContentHash() {
        #expect(scene(.web).contentHash != scene(.reactNative).contentHash)
    }

    @Test func sameRuntimeAndSourceKeepTheCachedRender() {
        #expect(scene(.reactNative).contentHash == scene(.reactNative).contentHash)
    }

    @Test(arguments: MotionSceneRuntime.allCases)
    func everyRuntimeRoundTripsThroughItsRawValue(runtime: MotionSceneRuntime) {
        #expect(MotionSceneRuntime(rawValue: runtime.rawValue) == runtime)
    }
}
