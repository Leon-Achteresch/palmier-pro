import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("Timeline markers")
struct TimelineMarkerTests {
    private func harness() -> (EditorViewModel, UndoManager) {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 300)])
        ])
        let manager = UndoManager()
        editor.undo.attach(manager)
        return (editor, manager)
    }

    @Test func addKeepsMarkersOrderedByFrame() {
        let (editor, _) = harness()
        editor.addMarker(atFrame: 200, name: "Late")
        editor.addMarker(atFrame: 10, name: "Early")
        editor.addMarker(atFrame: 120, kind: .chapter, name: "Middle")

        #expect(editor.timeline.markers.map(\.frame) == [10, 120, 200])
        #expect(editor.timeline.markers.map(\.name) == ["Early", "Middle", "Late"])
    }

    @Test func movingAMarkerRestoresFrameOrder() throws {
        let (editor, _) = harness()
        let first = try #require(editor.addMarker(atFrame: 10))
        editor.addMarker(atFrame: 120)

        #expect(editor.moveMarker(id: first.id, toFrame: 250))
        #expect(editor.timeline.markers.map(\.frame) == [120, 250])
        #expect(editor.timeline.markers.last?.id == first.id)
    }

    @Test(arguments: [-1, 301, 5_000])
    func rejectsFramesOutsideTheTimeline(frame: Int) throws {
        let (editor, _) = harness()
        #expect(editor.timeline.totalFrames == 300)
        #expect(editor.addMarker(atFrame: frame) == nil)
        #expect(editor.timeline.markers.isEmpty)

        let marker = try #require(editor.addMarker(atFrame: 0))
        #expect(editor.moveMarker(id: marker.id, toFrame: frame) == false)
        #expect(editor.timeline.marker(id: marker.id)?.frame == 0)
    }

    @Test func acceptsBothEndsOfTheTimeline() {
        let (editor, _) = harness()
        #expect(editor.addMarker(atFrame: 0) != nil)
        #expect(editor.addMarker(atFrame: 300) != nil)
        #expect(editor.timeline.markers.count == 2)
    }

    @Test func updateReportsNoChangeWhenValuesMatch() throws {
        let (editor, _) = harness()
        let marker = try #require(editor.addMarker(atFrame: 30, kind: .todo, name: "Fix audio"))

        #expect(editor.updateMarker(id: marker.id, .init(name: "Fix audio")) == false)
        #expect(editor.updateMarker(id: marker.id, .init()) == false)
        #expect(editor.updateMarker(id: "not-a-marker", .init(name: "x")) == false)
        #expect(editor.updateMarker(id: marker.id, .init(done: true)))
        #expect(editor.timeline.marker(id: marker.id)?.done == true)
    }

    @Test func leavingTodoClearsTheDoneFlag() throws {
        let (editor, _) = harness()
        let marker = try #require(editor.addMarker(atFrame: 30, kind: .todo, done: true))
        #expect(editor.timeline.marker(id: marker.id)?.done == true)

        #expect(editor.updateMarker(id: marker.id, .init(kind: .chapter)))
        #expect(editor.timeline.marker(id: marker.id)?.done == false)
    }

    @Test func removeClearsSelectionAndIsIdempotent() throws {
        let (editor, _) = harness()
        let marker = try #require(editor.addMarker(atFrame: 40))
        #expect(editor.selectedMarkerId == marker.id)

        #expect(editor.removeMarker(id: marker.id))
        #expect(editor.selectedMarkerId == nil)
        #expect(editor.removeMarker(id: marker.id) == false)
        #expect(editor.timeline.markers.isEmpty)
    }

    @Test func eachMarkerEditIsOneUndoStep() throws {
        let (editor, manager) = harness()
        let marker = try #require(editor.addMarker(atFrame: 40, name: "Rough"))
        #expect(editor.renameMarker(id: marker.id, to: "Final"))
        #expect(editor.moveMarker(id: marker.id, toFrame: 90))

        #expect(editor.undo.undoLatest() == "Move Marker")
        #expect(editor.timeline.marker(id: marker.id)?.frame == 40)
        #expect(editor.undo.undoLatest() == "Rename Marker")
        #expect(editor.timeline.marker(id: marker.id)?.name == "Rough")
        #expect(editor.undo.undoLatest() == "Add Marker")
        #expect(editor.timeline.markers.isEmpty)

        manager.redo()
        #expect(editor.timeline.markers.count == 1)
    }

    @Test func refusedEditsRegisterNoUndoStep() {
        let (editor, manager) = harness()
        editor.addMarker(atFrame: 400)
        #expect(!manager.canUndo)
        #expect(editor.timeline.markers.isEmpty)
    }

    @Test func markersSurviveEncodingAndStaySorted() throws {
        let (editor, _) = harness()
        editor.addMarker(atFrame: 120, kind: .chapter, name: "Two", note: "second", color: .green)
        editor.addMarker(atFrame: 10, name: "One")

        let data = try JSONEncoder().encode(editor.timeline)
        let decoded = try JSONDecoder().decode(Timeline.self, from: data)

        #expect(decoded.markers.map(\.frame) == [10, 120])
        #expect(decoded.markers.last?.kind == .chapter)
        #expect(decoded.markers.last?.color == .green)
        #expect(decoded.markers.last?.note == "second")
    }

    @Test func unknownKindAndColorDecodeToDefaults() throws {
        let json = Data(#"{"id":"m1","frame":12,"kind":"sparkle","color":"chartreuse"}"#.utf8)
        let marker = try JSONDecoder().decode(TimelineMarker.self, from: json)

        #expect(marker.kind == .standard)
        #expect(marker.color == .blue)
        #expect(marker.frame == 12)
    }

    @Test func frameRateChangeRescalesMarkers() throws {
        let (editor, _) = harness()
        let marker = try #require(editor.addMarker(atFrame: 60, kind: .chapter))

        editor.applyTimelineSettings(fps: 60, width: editor.timeline.width, height: editor.timeline.height)

        #expect(editor.timeline.marker(id: marker.id)?.frame == 120)
    }

    @Test func duplicatingATimelineGivesItsMarkersFreshIds() throws {
        let (editor, _) = harness()
        let marker = try #require(editor.addMarker(atFrame: 60, name: "Intro"))
        let copyId = try #require(editor.duplicateTimeline(editor.activeTimelineId))
        let copy = try #require(editor.timeline(for: copyId))

        #expect(copy.markers.count == 1)
        #expect(copy.markers[0].name == "Intro")
        #expect(copy.markers[0].id != marker.id)
    }

    @Test func ribbonHitTestingMatchesTheDrawnTag() throws {
        let markers = [
            TimelineMarker(id: "a", frame: 10),
            TimelineMarker(id: "b", frame: 400),
        ]
        let rulerRect = NSRect(x: 0, y: 0, width: 200, height: Layout.rulerHeight)
        let rect = TimelineMarkerRibbon.tagRect(
            frame: 10, in: rulerRect, pixelsPerFrame: 2, scrollOffsetX: 0
        )

        let hit = TimelineMarkerRibbon.hitTest(
            markers: markers, at: CGPoint(x: rect.midX, y: rect.midY),
            in: rulerRect, pixelsPerFrame: 2, scrollOffsetX: 0
        )
        #expect(hit == "a")

        let miss = TimelineMarkerRibbon.hitTest(
            markers: markers, at: CGPoint(x: rect.midX, y: rulerRect.minY),
            in: rulerRect, pixelsPerFrame: 2, scrollOffsetX: 0
        )
        #expect(miss == nil)
    }

    @Test func ribbonVisibleRangeSkipsOffscreenMarkers() {
        let markers = (0..<100).map { TimelineMarker(id: "m\($0)", frame: $0 * 100) }
        let rulerRect = NSRect(x: 0, y: 0, width: 300, height: Layout.rulerHeight)

        let range = TimelineMarkerRibbon.visibleRange(
            markers, in: rulerRect, pixelsPerFrame: 1, scrollOffsetX: 1_000
        )

        #expect(markers[range].allSatisfy { $0.frame >= 990 && $0.frame <= 1_310 })
        #expect(range.count == 4)
    }
}
