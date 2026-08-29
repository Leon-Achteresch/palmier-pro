import Foundation
import Testing

@testable import PalmierPro

@Suite("set_keyframes — text clips")
@MainActor
struct TextKeyframeToolTests {
    private func harness() -> ToolHarness {
        var clip = Fixtures.clip(id: "text-1", mediaRef: "", mediaType: .text, start: 0, duration: 90)
        clip.textContent = "Motion"
        clip.textStyle = TextStyle()
        return ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))
    }

    @Test func animatesPositionAndOpacityTogether() async throws {
        let harness = harness()
        _ = try await harness.runOK("set_keyframes", args: [
            "clipId": "text-1",
            "tracks": [
                "position": [[0, 0.0, 0.5], [30, 0.4, 0.5, "easeOut"]],
                "opacity": [[0, 0.0], [30, 1.0]],
            ],
        ])

        let clip = try #require(harness.editor.clipFor(id: "text-1"))
        #expect(clip.keyframeFrames(for: .position) == [0, 30])
        #expect(clip.keyframeFrames(for: .opacity) == [0, 30])
        #expect(abs(clip.topLeftAt(frame: 30).x - 0.4) < 0.0001)
        #expect(clip.rawOpacityAt(frame: 0) == 0)
    }

    @Test func rejectsCropWhichTextDoesNotSupport() async throws {
        let harness = harness()
        let result = await harness.executor.execute(name: "set_keyframes", args: [
            "clipId": "text-1",
            "property": "crop",
            "keyframes": [[0, 0.1, 0.1, 0.1, 0.1]],
        ])
        #expect(result.isError == true)
    }
}
