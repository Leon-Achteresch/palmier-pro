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

    @Test func rejectsObsoleteSingleSourceScenes() throws {
        let legacy = """
        {"version":1,"width":640,"height":360,"fps":30,"durationInFrames":30,"source":"export default function Scene() { return null }"}
        """
        #expect(throws: MotionSceneError.unsupportedVersion(1)) {
            try MotionScene.decoded(from: Data(legacy.utf8))
        }
    }

    @Test func runtimeSurvivesARoundTrip() throws {
        let decoded = try MotionScene.decoded(from: try scene(.reactNative).encoded())
        #expect(decoded.runtime == .reactNative)
    }

    @Test func runtimeChangesTheContentHash() throws {
        #expect(try scene(.web).contentHash != scene(.reactNative).contentHash)
    }

    @Test func sameRuntimeAndSourceKeepTheCachedRender() throws {
        #expect(try scene(.reactNative).contentHash == scene(.reactNative).contentHash)
    }

    @Test(arguments: MotionSceneRuntime.allCases)
    func everyRuntimeRoundTripsThroughItsRawValue(runtime: MotionSceneRuntime) {
        #expect(MotionSceneRuntime(rawValue: runtime.rawValue) == runtime)
    }
}
