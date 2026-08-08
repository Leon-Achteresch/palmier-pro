import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite("Motion scene model")
struct MotionSceneModelTests {

    private func scene(
        width: Int = 320,
        height: Int = 240,
        fps: Double = 30,
        durationInFrames: Int = 30,
        source: String = "export default function Scene() { return null }"
    ) -> MotionScene {
        MotionScene(width: width, height: height, fps: fps, durationInFrames: durationInFrames, source: source)
    }

    @Test func durationDerivesFromFrameCountAndRate() {
        #expect(scene(fps: 30, durationInFrames: 45).duration == 1.5)
    }

    @Test(arguments: [
        (0, 240, 30.0, 30),
        (320, 0, 30.0, 30),
        (5000, 240, 30.0, 30),
        (320, 240, 0.0, 30),
        (320, 240, 500.0, 30),
        (320, 240, 30.0, 0),
        (320, 240, 30.0, 40000),
    ])
    func rejectsOutOfRangeFields(width: Int, height: Int, fps: Double, frames: Int) {
        #expect(throws: MotionSceneError.self) {
            try scene(width: width, height: height, fps: fps, durationInFrames: frames).validated()
        }
    }

    @Test func rejectsNonFiniteFrameRate() {
        #expect(throws: MotionSceneError.self) { try scene(fps: .nan).validated() }
        #expect(throws: MotionSceneError.self) { try scene(fps: .infinity).validated() }
    }

    @Test func rejectsBlankSource() {
        #expect(throws: MotionSceneError.self) { try scene(source: "   \n\t ").validated() }
    }

    @Test func roundTripsThroughItsFileFormat() throws {
        let original = try scene(source: "export default () => null").validated()
        #expect(try MotionScene.decoded(from: original.encoded()) == original)
    }

    @Test func rejectsMalformedFile() {
        #expect(throws: MotionSceneError.self) { try MotionScene.decoded(from: Data("not json".utf8)) }
    }

    /// The render cache is keyed by this, so every field that changes the pixels must change it.
    @Test func contentHashCoversEveryRenderInput() {
        let base = scene()
        #expect(base.contentHash == scene().contentHash)
        #expect(base.contentHash != scene(width: 321).contentHash)
        #expect(base.contentHash != scene(height: 241).contentHash)
        #expect(base.contentHash != scene(fps: 60).contentHash)
        #expect(base.contentHash != scene(durationInFrames: 31).contentHash)
        #expect(base.contentHash != scene(source: "export default () => null").contentHash)
    }

    @Test func encoderSizeIsEven() {
        #expect(scene(width: 321, height: 241).encodedSize == CGSize(width: 320, height: 240))
    }

    @Test func sniffRejectsNonSceneFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motion-sniff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("ok.motion")
        try scene().validated().encoded().write(to: valid)
        #expect(MotionScene.isMotionScene(at: valid))

        let garbage = directory.appendingPathComponent("bad.motion")
        try Data("{}".utf8).write(to: garbage)
        #expect(!MotionScene.isMotionScene(at: garbage))

        let wrongExtension = directory.appendingPathComponent("ok.json")
        try scene().validated().encoded().write(to: wrongExtension)
        #expect(!MotionScene.isMotionScene(at: wrongExtension))
    }

    @Test func clipTypeMapsTheSceneExtension() {
        #expect(ClipType(fileExtension: "motion") == .motion)
        #expect(ClipType.motion.isVisual)
    }
}

@Suite("Motion scene rendering", .serialized)
@MainActor
struct MotionSceneRenderingTests {

    /// Paints only the top-left quadrant, so a vertically flipped bake is impossible to miss.
    private static let quadrantScene = """
    import { motion } from "motion/react"

    export default function Scene() {
      return (
        <div className="w-full h-full">
          <motion.div
            className="absolute left-0 top-0 w-1/2 h-1/2 bg-red-600"
            initial={{ opacity: 1 }}
            animate={{ opacity: 1 }}
          />
        </div>
      )
    }
    """

    private func bake(_ scene: MotionScene) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motion-bake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sceneURL = directory.appendingPathComponent("scene.motion")
        try scene.encoded().write(to: sceneURL)
        return try await MotionVideoGenerator.motionVideo(for: sceneURL, mediaRef: "test")
    }

    private struct Frame {
        let bgra: [UInt8]
        let width: Int
        let height: Int

        /// Row 0 is the top of the video frame, matching the DOM's origin.
        func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let index = (y * width + x) * 4
            return (bgra[index + 2], bgra[index + 1], bgra[index], bgra[index + 3])
        }
    }

    /// AVAssetImageGenerator flattens alpha away, so the frame is read straight off the track.
    private func firstFrame(_ url: URL) async throws -> Frame {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        reader.startReading()
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                memcpy(
                    destination.baseAddress!.advanced(by: row * width * 4),
                    base.advanced(by: row * bytesPerRow),
                    width * 4
                )
            }
        }
        return Frame(bgra: pixels, width: width, height: height)
    }

    @Test func bakesAtTheDeclaredSizeAsAlphaProRes() async throws {
        let scene = try MotionScene(
            width: 320, height: 240, fps: 30, durationInFrames: 6,
            source: Self.quadrantScene
        ).validated()
        let url = try await bake(scene)

        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let format = try #require(track.formatDescriptions.first as! CMFormatDescription?)
        #expect(format.mediaSubType == CMFormatDescription.MediaSubType(rawValue: kCMVideoCodecType_AppleProRes4444))
        #expect(format.dimensions.width == 320)
        #expect(format.dimensions.height == 240)

        let frame = try await firstFrame(url)
        #expect(frame.width == 320)
        #expect(frame.height == 240)
    }

    /// The last frame is held far out so a clip can be dragged past the animation as a freeze-frame.
    @Test func holdsTheFinalFrameSoClipsCanBeExtended() async throws {
        let scene = try MotionScene(
            width: 160, height: 120, fps: 30, durationInFrames: 3,
            source: Self.quadrantScene + "\n// hold probe\n"
        ).validated()
        let duration = try await AVURLAsset(url: try await bake(scene)).load(.duration)
        #expect(duration.seconds > 60)
    }

    /// Compositing an offscreen window needs a running NSApplication, which `swift test` does not
    /// provide: every snapshot comes back blank here. Verified instead through the app harness,
    /// where a top-left red quadrant reads back as R212 A255 with the other three quadrants at A0.
    @Test(.disabled("offscreen compositing is unavailable in the SwiftPM test process"))
    func bakesUprightWithPreservedAlpha() async throws {
        let scene = try MotionScene(
            width: 320, height: 240, fps: 30, durationInFrames: 6,
            source: Self.quadrantScene
        ).validated()
        let frame = try await firstFrame(try await bake(scene))

        let topLeft = frame.pixel(x: 40, y: 30)
        let bottomRight = frame.pixel(x: 280, y: 210)
        #expect(topLeft.a > 200)
        #expect(topLeft.r > 120 && topLeft.g < 110 && topLeft.b < 110)
        #expect(bottomRight.a == 0)
    }

    @Test func rendersTheSameBytesForTheSameSource() async throws {
        let source = Self.quadrantScene + "\n// determinism probe\n"
        let scene = try MotionScene(
            width: 160, height: 120, fps: 30, durationInFrames: 4, source: source
        ).validated()
        let first = try await bake(scene)
        MotionVideoGenerator.cache.clear()
        let second = try await bake(scene)
        #expect(try Data(contentsOf: first) == (try Data(contentsOf: second)))
    }

    @Test func reusesTheCachedRenderForUnchangedSource() async throws {
        let scene = try MotionScene(
            width: 160, height: 120, fps: 30, durationInFrames: 4,
            source: Self.quadrantScene + "\n// cache probe\n"
        ).validated()
        #expect(try await bake(scene) == (try await bake(scene)))
    }

    @Test func editingTheSourceProducesADifferentRender() async throws {
        let base = try MotionScene(
            width: 160, height: 120, fps: 30, durationInFrames: 4,
            source: Self.quadrantScene + "\n// key probe A\n"
        ).validated()
        var edited = base
        edited.source += "// key probe B\n"
        #expect(try await bake(base) != (try await bake(edited.validated())))
    }

    @Test func surfacesSceneFailuresInsteadOfShippingBlankFrames() async throws {
        let broken = try MotionScene(
            width: 160, height: 120, fps: 30, durationInFrames: 2,
            source: "export default function Scene() { throw new Error('boom from the scene') }"
        ).validated()
        await #expect(throws: MotionSceneError.self) { try await bake(broken) }
    }

    @Test func rejectsASceneWithoutADefaultExport() async throws {
        let noExport = try MotionScene(
            width: 160, height: 120, fps: 30, durationInFrames: 2,
            source: "const Scene = () => null"
        ).validated()
        await #expect(throws: MotionSceneError.self) { try await bake(noExport) }
    }

    @Test func rejectsAnUnknownImport() async throws {
        let badImport = try MotionScene(
            width: 160, height: 120, fps: 30, durationInFrames: 2,
            // Referenced, because the transform elides imports a scene never uses.
            source: "import fs from 'node:fs'\nexport default () => fs.readFileSync('/etc/passwd')"
        ).validated()
        await #expect(throws: MotionSceneError.self) { try await bake(badImport) }
    }
}
