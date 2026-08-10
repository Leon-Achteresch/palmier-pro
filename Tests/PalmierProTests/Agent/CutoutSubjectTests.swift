import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("cutout_subject")
@MainActor
struct CutoutSubjectTests {

    private func harness() -> (ToolHarness, String) {
        let clip = Fixtures.clip(id: "clip-a", start: 0, duration: 60)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        h.addAsset(id: "media-1", duration: 10)
        return (h, clip.id)
    }

    @Test func addsAnEnabledSubjectKeyWithTheRequestedSettings() async throws {
        let (h, clipId) = harness()
        let result = await h.runRaw("cutout_subject", args: [
            "clipIds": [clipId], "quality": "fast", "feather": 0.4, "expand": -0.2,
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let effect = try #require(h.editor.clipFor(id: clipId)?.effects?.first { $0.type == "key.subject" })
        #expect(effect.enabled)
        #expect(effect.params["quality"]?.value == 0)
        #expect(effect.params["feather"]?.value == 0.4)
        #expect(effect.params["expand"]?.value == -0.2)
        #expect(effect.params["invert"]?.value == 0)
    }

    @Test func keepBackgroundInvertsTheMask() async throws {
        let (h, clipId) = harness()
        _ = await h.runRaw("cutout_subject", args: ["clipIds": [clipId], "keep": "background"])
        let effect = try #require(h.editor.clipFor(id: clipId)?.effects?.first { $0.type == "key.subject" })
        #expect(effect.params["invert"]?.value == 1)
    }

    @Test func backgroundMediaLandsOnANewTrackBelowSpanningTheClip() async throws {
        let (h, clipId) = harness()
        let plate = h.addAsset(type: .image, duration: 5)

        let result = await h.runRaw("cutout_subject", args: [
            "clipIds": [clipId], "background": ["mediaRef": plate.id],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let backgroundClip = try #require(h.editor.timeline.tracks.flatMap(\.clips).first { $0.mediaRef == plate.id })
        #expect(backgroundClip.startFrame == 0)
        #expect(backgroundClip.durationFrames == 60)

        let subjectTrack = try #require(h.editor.findClip(id: clipId)?.trackIndex)
        let backgroundTrack = try #require(h.editor.findClip(id: backgroundClip.id)?.trackIndex)
        #expect(backgroundTrack > subjectTrack)
    }

    @Test func cutoutAndBackgroundUndoAsOneAction() async throws {
        let (h, clipId) = harness()
        let undoManager = UndoManager()
        h.editor.undo.attach(undoManager)
        let plate = h.addAsset(type: .image, duration: 5)

        _ = await h.runRaw("cutout_subject", args: [
            "clipIds": [clipId], "background": ["mediaRef": plate.id],
        ])
        undoManager.undo()

        #expect(h.editor.clipFor(id: clipId)?.effects?.contains { $0.type == "key.subject" } != true)
        #expect(!h.editor.timeline.tracks.flatMap(\.clips).contains { $0.mediaRef == plate.id })
    }

    @Test func removeStripsTheKeyAndReportsANoopWhenThereIsNone() async throws {
        let (h, clipId) = harness()
        let noop = await h.runRaw("cutout_subject", args: ["clipIds": [clipId], "remove": true])
        #expect(!noop.isError, "\(ToolHarness.textOf(noop))")
        #expect(ToolHarness.textOf(noop).contains("noop"))

        _ = await h.runRaw("cutout_subject", args: ["clipIds": [clipId]])
        let removed = await h.runRaw("cutout_subject", args: ["clipIds": [clipId], "remove": true])
        #expect(!removed.isError, "\(ToolHarness.textOf(removed))")
        #expect(h.editor.clipFor(id: clipId)?.effects?.contains { $0.type == "key.subject" } != true)
    }

    @Test func refusesAudioClipsUnknownQualityAndOutOfRangeFeather() async {
        let audio = Fixtures.clip(id: "audio-a", mediaType: .audio, start: 0, duration: 30)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [audio])]))
        #expect(await h.runRaw("cutout_subject", args: ["clipIds": ["audio-a"]]).isError)

        let (h2, clipId) = harness()
        #expect(await h2.runRaw("cutout_subject", args: ["clipIds": [clipId], "quality": "ultra"]).isError)
        #expect(await h2.runRaw("cutout_subject", args: ["clipIds": [clipId], "feather": 2]).isError)
        #expect(await h2.runRaw("cutout_subject", args: [
            "clipIds": [clipId], "background": ["mediaRef": "media-1", "colorHex": "#101014"],
        ]).isError)
        #expect(h2.editor.clipFor(id: clipId)?.effects == nil)
    }

    @Test func animatedFeatherSurvivesThroughApplyEffect() async throws {
        let (h, clipId) = harness()
        _ = await h.runRaw("cutout_subject", args: ["clipIds": [clipId]])
        let result = await h.runRaw("apply_effect", args: [
            "clipIds": [clipId],
            "effects": [["type": "key.subject", "params": ["feather": [[0, 0.0], [30, 0.8, "linear"]]]]],
        ])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let effect = try #require(h.editor.clipFor(id: clipId)?.effects?.first { $0.type == "key.subject" })
        #expect(effect.params["feather"]?.track?.keyframes.count == 2)
        #expect(effect.params["quality"]?.value == 1)
    }
}

@Suite("SubjectMask")
struct SubjectMaskTests {

    @Test func returnsTheFrameUntouchedWhenNoSubjectIsFound() {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let flat = CIImage(color: .gray).cropped(to: extent)
        let out = SubjectMask.apply(flat, extent: extent, quality: 0, feather: 0.2, expand: 0, invert: 0)
        #expect(out.extent == flat.extent)

        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            out, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 32, y: 32, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        #expect(pixel[3] == 255)
    }

    @Test func subjectStaysOpaqueWhileTheBackgroundIsCutAway() {
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let background = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: extent)
        let subject = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: extent)
        let discMask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 256, y: 256),
            "inputRadius0": 150.0, "inputRadius1": 155.0,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: extent)
        let frame = subject.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: discMask, kCIInputBackgroundImageKey: background,
        ]).cropped(to: extent)

        let out = SubjectMask.apply(frame, extent: extent, quality: 2, feather: 0, expand: 0, invert: 0)
        let context = CIContext()
        func alpha(x: CGFloat, y: CGFloat) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(
                out, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: x, y: y, width: 1, height: 1),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            return pixel[3]
        }
        #expect(alpha(x: 256, y: 256) == 255)
        #expect(alpha(x: 10, y: 10) == 0)
    }

    @Test func degenerateExtentIsRejectedWithoutRunningVision() {
        let image = CIImage(color: .white)
        let out = SubjectMask.apply(image, extent: .zero, quality: 0, feather: 0, expand: 0, invert: 0)
        #expect(out.extent.isInfinite)
    }

    @Test(arguments: [(0.0, SubjectMask.Quality.fast), (1.0, .balanced), (2.0, .subject), (7.0, .balanced)])
    func qualityParameterMapsToASegmentationLevel(param: Double, expected: SubjectMask.Quality) {
        #expect(SubjectMask.Quality(param: param) == expected)
    }

    private static func discFrame(extent: CGRect) -> CIImage {
        let background = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: extent)
        let subject = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: extent)
        let discMask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: extent.midX, y: extent.midY),
            "inputRadius0": extent.width * 0.29, "inputRadius1": extent.width * 0.3,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: extent)
        return subject.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: discMask, kCIInputBackgroundImageKey: background,
        ]).cropped(to: extent)
    }

    private static func luma(_ image: CIImage, x: CGFloat, y: CGFloat) -> UInt8 {
        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixel[0]
    }

    @Test func revealMatteStartsAtTheSubjectAndCoversTheFrameNearCompletion() throws {
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let frame = Self.discFrame(extent: extent)

        let early = try #require(SubjectMask.revealMatte(
            for: frame, extent: extent, quality: 2, feather: 0, progress: 0.05
        ))
        #expect(Self.luma(early, x: 256, y: 256) > 200)
        #expect(Self.luma(early, x: 5, y: 5) < 50)

        let late = try #require(SubjectMask.revealMatte(
            for: frame, extent: extent, quality: 2, feather: 0, progress: 0.99
        ))
        #expect(Self.luma(late, x: 5, y: 5) > 200)
    }

    @Test func revealMatteIsNilWithoutASubjectSoTheCompositorCanDissolve() {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let flat = CIImage(color: .gray).cropped(to: extent)
        #expect(SubjectMask.revealMatte(for: flat, extent: extent, quality: 0, feather: 0, progress: 0.5) == nil)
    }

    @Test func identicalInputReusesTheCachedMaskWithoutRerunningVision() {
        let extent = CGRect(x: 0, y: 0, width: 96, height: 96)
        let image = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 96, y: 96),
            "inputColor0": CIColor(red: 0.13, green: 0.57, blue: 0.29),
            "inputColor1": CIColor(red: 0.71, green: 0.03, blue: 0.88),
        ])!.outputImage!.cropped(to: extent)

        _ = SubjectMask.apply(image, extent: extent, quality: 1, feather: 0, expand: 0, invert: 0)
        let runsAfterFirst = SubjectMask.visionRunCount
        _ = SubjectMask.apply(image, extent: extent, quality: 1, feather: 0, expand: 0, invert: 0)
        #expect(SubjectMask.visionRunCount == runsAfterFirst)
    }
}
