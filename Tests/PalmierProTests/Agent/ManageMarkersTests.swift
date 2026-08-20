import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — manage_markers")
@MainActor
struct ManageMarkersTests {
    private func harness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 300)])
        ]))
    }

    @Test func addsMarkersAndReturnsStableIds() async throws {
        let h = harness()
        let json = try await h.runOK("manage_markers", args: ["add": [
            ["frame": 90, "name": "Setup", "kind": "chapter"],
            ["frame": 0, "name": "Intro", "kind": "chapter", "color": "green"],
        ]]) as? [String: Any]

        let markers = try #require(json?["markers"] as? [[String: Any]])
        #expect(markers.map { $0["frame"] as? Int } == [0, 90])
        #expect(markers.first?["name"] as? String == "Intro")
        #expect(markers.first?["color"] as? String == "green")
        #expect((json?["addedMarkerIds"] as? [String])?.count == 2)
        // Annotations never move the cut.
        #expect(json?["clips"] == nil)
        #expect(json?["shifted"] == nil)

        let id = try #require(markers.first?["markerId"] as? String)
        #expect(h.editor.timeline.markers.contains { $0.id.hasPrefix(id) })
    }

    @Test func listsMarkersWhenCalledWithNoArguments() async throws {
        let h = harness()
        _ = try await h.runOK("manage_markers", args: ["add": [["frame": 12, "name": "Note"]]])

        let json = try await h.runOK("manage_markers") as? [String: Any]
        #expect(json?["markerCount"] as? Int == 1)
        #expect(json?["totalFrames"] as? Int == 300)
        #expect((json?["markers"] as? [[String: Any]])?.first?["name"] as? String == "Note")
    }

    @Test func getTimelineReportsMarkersAndOmitsThemWhenEmpty() async throws {
        let h = harness()
        let empty = try await h.runOK("get_timeline") as? [String: Any]
        #expect(empty?["markers"] == nil)

        _ = try await h.runOK("manage_markers", args: ["add": [
            ["frame": 45, "name": "Fix", "kind": "todo", "done": true],
        ]])
        let json = try await h.runOK("get_timeline") as? [String: Any]
        let marker = try #require((json?["markers"] as? [[String: Any]])?.first)
        #expect(marker["kind"] as? String == "todo")
        #expect(marker["done"] as? Bool == true)
        #expect(marker["note"] == nil)
    }

    @Test func updatesByIdAndReportsUnchangedRequests() async throws {
        let h = harness()
        let added = try await h.runOK("manage_markers", args: ["add": [["frame": 10, "name": "Rough"]]]) as? [String: Any]
        let id = try #require((added?["markers"] as? [[String: Any]])?.first?["markerId"] as? String)

        let json = try await h.runOK("manage_markers", args: ["update": [
            ["markerId": id, "name": "Final", "frame": 120],
        ]]) as? [String: Any]
        #expect((json?["updatedMarkerIds"] as? [String])?.count == 1)
        #expect(h.editor.timeline.markers.first?.name == "Final")
        #expect(h.editor.timeline.markers.first?.frame == 120)

        let repeated = try await h.runOK("manage_markers", args: ["update": [
            ["markerId": id, "name": "Final"],
        ]]) as? [String: Any]
        #expect((repeated?["unchangedMarkerIds"] as? [String])?.count == 1)
        #expect(repeated?["updatedMarkerIds"] == nil)
        #expect((repeated?["notes"] as? [String])?.isEmpty == false)
    }

    @Test func removesMarkersAndReportsWhatWentAway() async throws {
        let h = harness()
        let added = try await h.runOK("manage_markers", args: ["add": [
            ["frame": 10, "name": "One"], ["frame": 20, "name": "Two"],
        ]]) as? [String: Any]
        let ids = try #require((added?["markers"] as? [[String: Any]])?.compactMap { $0["markerId"] as? String })

        let json = try await h.runOK("manage_markers", args: ["remove": [ids[0]]]) as? [String: Any]
        let removed = try #require(json?["removedMarkers"] as? [[String: Any]])
        #expect(removed.first?["name"] as? String == "One")
        #expect(h.editor.timeline.markers.map(\.name) == ["Two"])
    }

    @Test func rejectsInvalidRequestsWithoutChangingAnything() async throws {
        let h = harness()
        _ = try await h.runOK("manage_markers", args: ["add": [["frame": 10, "name": "Keep"]]])
        let existing = h.editor.timeline.markers

        for args: [String: Any] in [
            ["add": [["frame": 900]]],
            ["add": [["frame": -1]]],
            ["add": [["frame": 1.5]]],
            ["add": [["frame": 10, "kind": "sparkle"]]],
            ["add": [["frame": 10, "color": "chartreuse"]]],
            ["add": [["frame": 10, "done": true]]],
            ["add": [["name": "no frame"]]],
            ["add": [["frame": 10, "unknown": 1]]],
            ["update": [["markerId": "00000000-0000-0000-0000-000000000000", "name": "x"]]],
            ["remove": ["00000000-0000-0000-0000-000000000000"]],
        ] {
            let result = await h.runRaw("manage_markers", args: args)
            #expect(result.isError, "expected rejection for \(args)")
        }
        #expect(h.editor.timeline.markers == existing)
    }

    @Test func oneCallIsOneUndoStep() async throws {
        let h = harness()
        let manager = UndoManager()
        h.editor.undo.attach(manager)

        _ = try await h.runOK("manage_markers", args: ["add": [
            ["frame": 10, "name": "One"], ["frame": 20, "name": "Two"], ["frame": 30, "name": "Three"],
        ]])
        #expect(h.editor.timeline.markers.count == 3)

        #expect(h.editor.undo.undoLatest() == "Manage Markers (Agent)")
        #expect(h.editor.timeline.markers.isEmpty)
        #expect(!manager.canUndo)
    }

    @Test func chapterMarkersFromTheToolFeedTheSidecar() async throws {
        let h = harness()
        _ = try await h.runOK("manage_markers", args: ["add": [
            ["frame": 0, "name": "Intro", "kind": "chapter"],
            ["frame": 150, "name": "Body", "kind": "chapter"],
            ["frame": 200, "name": "Note", "kind": "standard"],
        ]])

        let text = ChapterSidecar.text(markers: h.editor.timeline.markers, fps: h.editor.timeline.fps)
        #expect(text == "00:00 Intro\n00:05 Body\n")
    }
}
