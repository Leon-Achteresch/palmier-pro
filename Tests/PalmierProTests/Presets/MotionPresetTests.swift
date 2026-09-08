import Testing
@testable import PalmierPro

@Suite("Motion presets")
struct MotionPresetTests {

    private func makeClip(duration: Int = 120) -> Clip {
        Clip(mediaRef: "m", mediaType: .video, startFrame: 50, durationFrames: duration)
    }

    private func apply(
        _ preset: MotionPreset,
        to clip: inout Clip,
        intensity: Double = 0.5,
        rampFrames: Int = 24,
        focusX: Double? = nil,
        focusY: Double? = nil,
        delayFrames: Int = 0
    ) -> MotionApplication.Receipt {
        MotionApplication(
            preset: preset, intensity: intensity, rampFrames: rampFrames,
            focusX: focusX, focusY: focusY, delayFrames: delayFrames
        ).apply(to: &clip)
    }

    @Test func entrancePresetAnimatesFromClipStartToNeutral() {
        var clip = makeClip()
        let receipt = apply(.focusIn, to: &clip)

        #expect(receipt.segment == 0...24)
        #expect(clip.scaleTrack?.keyframes.map(\.frame) == [0, 24])
        #expect(clip.scaleTrack?.keyframes.last?.value == AnimPair(a: 1, b: 1))
        #expect(clip.opacityTrack?.keyframes.first?.value == 0.3)
        #expect(clip.opacityTrack?.keyframes.last?.value == 1)
        #expect(clip.blurKeyframeTrack?.keyframes.last?.value == 0)
        #expect(clip.scaleTrack?.keyframes.first?.interpolationOut == .easeOut)
    }

    @Test func exitPresetAnchorsToClipEnd() {
        var clip = makeClip(duration: 120)
        let receipt = apply(.fadeDown, to: &clip)

        #expect(receipt.segment == 95...119)
        #expect(clip.opacityTrack?.keyframes.map(\.frame) == [95, 119])
        #expect(clip.opacityTrack?.keyframes.last?.value == 0)
    }

    @Test func emphasisSpansTheWholeClip() {
        var clip = makeClip(duration: 200)
        let receipt = apply(.kenBurns, to: &clip)

        #expect(receipt.segment == 0...199)
        #expect(clip.scaleTrack?.keyframes.map(\.frame) == [0, 199])
    }

    @Test func punchInKeepsFocusPointStationary() {
        var clip = makeClip()
        _ = apply(.punchIn, to: &clip, intensity: 1, focusX: 0.25, focusY: 0.75)

        let zoomed = clip.scaleTrack!.keyframes[1]
        #expect(zoomed.value.a == 2.0)
        let topLeft = clip.positionTrack!.keyframes[1].value
        let focusCanvasX = topLeft.a + 0.25 * zoomed.value.a
        let focusCanvasY = topLeft.b + 0.75 * zoomed.value.b
        #expect(abs(focusCanvasX - 0.25) < 1e-9)
        #expect(abs(focusCanvasY - 0.75) < 1e-9)
    }

    @Test func entranceAndExitCoexistOnOneClip() {
        var clip = makeClip(duration: 120)
        _ = apply(.popIn, to: &clip)
        _ = apply(.scaleBlurOut, to: &clip)

        let frames = clip.scaleTrack!.keyframes.map(\.frame)
        #expect(frames == [0, 24, 95, 119])
        #expect(clip.scaleTrack?.keyframes.first?.value.a.isApproximately(0.45) == true)
        #expect(clip.scaleTrack?.keyframes.last?.value.a.isApproximately(1.275) == true)
    }

    @Test func reapplyReplacesOnlyItsOwnSegment() {
        var clip = makeClip(duration: 120)
        _ = apply(.scaleBlurOut, to: &clip)
        _ = apply(.popIn, to: &clip, intensity: 1)
        _ = apply(.popIn, to: &clip, intensity: 0)

        #expect(clip.scaleTrack?.keyframes.map(\.frame) == [0, 24, 95, 119])
        #expect(clip.scaleTrack?.keyframes.first?.value.a == 0.6)
    }

    @Test func delayShiftsEntranceSegment() {
        var clip = makeClip(duration: 120)
        let receipt = apply(.slideUp, to: &clip, delayFrames: 30)
        #expect(receipt.segment == 30...54)
    }

    @Test func rampLongerThanClipIsClamped() {
        var clip = makeClip(duration: 10)
        let receipt = apply(.focusIn, to: &clip, rampFrames: 500)
        #expect(receipt.segment == 0...9)
    }

    @Test func scaleAndPositionShareFramesAndEasingSoCenterStaysPut() {
        var clip = makeClip()
        _ = apply(.pulse, to: &clip)

        let scaleFrames = clip.scaleTrack!.keyframes.map(\.frame)
        let positionFrames = clip.positionTrack!.keyframes.map(\.frame)
        #expect(scaleFrames == positionFrames)
        for (s, p) in zip(clip.scaleTrack!.keyframes, clip.positionTrack!.keyframes) {
            #expect(s.interpolationOut == p.interpolationOut)
            #expect(abs((p.value.a + s.value.a / 2) - 0.5) < 1e-9)
            #expect(abs((p.value.b + s.value.b / 2) - 0.5) < 1e-9)
        }
    }

    @Test(arguments: MotionPreset.allCases)
    func everyPresetEndsNeutralOrFullyOut(preset: MotionPreset) {
        var clip = makeClip()
        _ = apply(preset, to: &clip)

        for property in preset.affectedProperties {
            #expect(clip.hasActiveKeyframes(for: property))
        }
    }
}

private extension Double {
    func isApproximately(_ other: Double, tolerance: Double = 1e-9) -> Bool {
        abs(self - other) < tolerance
    }
}
