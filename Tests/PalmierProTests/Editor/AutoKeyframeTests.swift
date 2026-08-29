import Foundation
import Testing

@testable import PalmierPro

@Suite("Auto keyframe")
@MainActor
struct AutoKeyframeTests {
    private func harness(mediaType: ClipType = .video) -> ToolHarness {
        var clip = Fixtures.clip(id: "clip-1", mediaType: mediaType, start: 0, duration: 90)
        if mediaType == .text {
            clip.textContent = "Hello"
            clip.textStyle = TextStyle()
        }
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))
        harness.editor.undo.attach(UndoManager())
        return harness
    }

    @Test func offKeepsTheEditStatic() {
        let editor = harness().editor
        editor.autoKeyframeEnabled = false
        editor.seekToFrame(30)
        var moved = Transform()
        moved.centerX += 0.2
        editor.commitTransform(clipId: "clip-1", newTransform: moved)

        let clip = try! #require(editor.clipFor(id: "clip-1"))
        #expect(clip.positionTrack?.isActive != true)
        #expect(clip.transform.centerX == moved.centerX)
    }

    @Test func onStampsAPositionKeyframeAtThePlayhead() {
        let editor = harness().editor
        editor.autoKeyframeEnabled = true
        editor.seekToFrame(30)
        var moved = Transform()
        moved.centerX += 0.2
        editor.commitTransform(clipId: "clip-1", newTransform: moved)

        let clip = try! #require(editor.clipFor(id: "clip-1"))
        #expect(clip.keyframeFrames(for: .position) == [30])
        #expect(clip.scaleTrack?.isActive != true)
        #expect(clip.rotationTrack?.isActive != true)
    }

    @Test func onSkipsUnchangedPropertiesAndFramesOutsideTheClip() {
        let editor = harness().editor
        editor.autoKeyframeEnabled = true
        editor.seekToFrame(200)
        var moved = Transform()
        moved.centerX += 0.2
        editor.commitTransform(clipId: "clip-1", newTransform: moved)

        let clip = try! #require(editor.clipFor(id: "clip-1"))
        #expect(clip.positionTrack?.isActive != true)
        #expect(clip.transform.centerX == moved.centerX)
    }

    @Test func onAnimatesTextOpacity() {
        let editor = harness(mediaType: .text).editor
        editor.autoKeyframeEnabled = true
        editor.seekToFrame(45)
        editor.commitOpacity(clipId: "clip-1", value: 0.25)

        let clip = try! #require(editor.clipFor(id: "clip-1"))
        #expect(clip.keyframeFrames(for: .opacity) == [45])
        #expect(clip.opacity == 1)
    }

    @Test func resettingTextSizeStaysStaticWhileAutoKeyframeIsOn() {
        let editor = harness(mediaType: .text).editor
        editor.autoKeyframeEnabled = true
        editor.seekToFrame(45)
        editor.resetTextSize(clipIds: ["clip-1"], defaultSize: 96)

        let clip = try! #require(editor.clipFor(id: "clip-1"))
        #expect(clip.scaleTrack?.isActive != true)
    }

    @Test(arguments: [AnimatableProperty.position, .scale, .rotation, .opacity, .blur])
    func clearingATextKeyframeTrackLeavesTheStaticValue(property: AnimatableProperty) {
        let editor = harness(mediaType: .text).editor
        editor.seekToFrame(20)
        editor.stampKeyframe(clipId: "clip-1", property: property, frame: 20)
        #expect(editor.clipFor(id: "clip-1")?.hasActiveKeyframes(for: property) == true)

        editor.commitClipProperties(clipIds: ["clip-1"]) { $0.clearKeyframes(for: property) }
        #expect(editor.clipFor(id: "clip-1")?.hasActiveKeyframes(for: property) == false)
    }

    @Test func canvasKeyframeDragMovesTheExistingKeyframe() {
        let editor = harness().editor
        editor.seekToFrame(10)
        editor.stampKeyframe(clipId: "clip-1", property: .position, frame: 10)
        editor.applyPositionKeyframe(clipId: "clip-1", frame: 10, x: 0.4, y: 0.6)
        editor.commitMoveKeyframe(clipId: "clip-1")

        let clip = try! #require(editor.clipFor(id: "clip-1"))
        #expect(clip.keyframeFrames(for: .position) == [10])
        let topLeft = clip.topLeftAt(frame: 10)
        #expect(abs(topLeft.x - 0.4) < 0.0001)
        #expect(abs(topLeft.y - 0.6) < 0.0001)
    }
}
