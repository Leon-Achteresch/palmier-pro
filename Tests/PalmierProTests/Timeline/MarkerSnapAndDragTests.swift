import Foundation
import Testing
@testable import PalmierPro

@Suite("Markers — snapping and ruler drag")
@MainActor
struct MarkerSnapAndDragTests {

    @MainActor
    final class Harness {
        let editor = EditorViewModel()
        let undoManager = UndoManager()

        init() {
            editor.timeline = Fixtures.timeline(tracks: [
                Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 0, duration: 300)])
            ])
            editor.undo.attach(undoManager)
        }
    }

    @Test func markerFramesBecomeSnapTargets() {
        let markers = [
            TimelineMarker(frame: 42, color: .blue, kind: .standard),
            TimelineMarker(frame: 90, color: .red, kind: .chapter),
        ]
        let targets = SnapEngine.collectTargets(tracks: [], markers: markers)
        #expect(targets.map(\.frame) == [42, 90])
        #expect(targets.allSatisfy { $0.kind == .marker })
    }

    @Test func theDraggedMarkerIsNotASnapTargetForItself() {
        let marker = TimelineMarker(frame: 42, color: .blue, kind: .standard)
        let other = TimelineMarker(frame: 90, color: .blue, kind: .standard)
        let targets = SnapEngine.collectTargets(
            tracks: [], markers: [marker, other], excludeMarkerIds: [marker.id]
        )
        #expect(targets.map(\.frame) == [90])
    }

    @Test func aClipEdgeDragSnapsToANearbyMarker() {
        let track = Fixtures.videoTrack(clips: [Fixtures.clip(id: "drag", start: 0, duration: 50)])
        let marker = TimelineMarker(frame: 120, color: .blue, kind: .standard)
        let targets = SnapEngine.collectTargets(
            tracks: [track], excludeClipIds: ["drag"], markers: [marker]
        )
        var state = SnapEngine.SnapState()
        let snap = SnapEngine.findSnap(
            position: 119, targets: targets, state: &state, baseThreshold: 8, pixelsPerFrame: 4
        )
        #expect(snap?.frame == 120)
        #expect(snap?.probeOffset == 0)
    }

    @Test func draggingAMarkerCommitsOneUndoEntry() throws {
        let h = Harness()
        let editor = h.editor
        let marker = try #require(editor.addMarker(atFrame: 100))

        for frame in [104, 118, 130] {
            editor.previewMarkerFrame(id: marker.id, frame: frame)
        }
        #expect(editor.timeline.marker(id: marker.id)?.frame == 130)
        #expect(editor.commitMarkerDrag(id: marker.id, fromFrame: 100))

        #expect(editor.undo.undoLatest() == "Move Marker")
        #expect(editor.timeline.marker(id: marker.id)?.frame == 100)
        #expect(editor.undo.undoLatest() == "Add Marker")
        #expect(editor.timeline.markers.isEmpty)
    }

    @Test func aDragThatEndsWhereItStartedRegistersNothing() throws {
        let h = Harness()
        let editor = h.editor
        let marker = try #require(editor.addMarker(atFrame: 100))

        editor.previewMarkerFrame(id: marker.id, frame: 140)
        editor.previewMarkerFrame(id: marker.id, frame: 100)

        #expect(!editor.commitMarkerDrag(id: marker.id, fromFrame: 100))
        #expect(editor.undo.undoLatest() == "Add Marker")
    }

    @Test func aPreviewOutsideTheTimelineIsIgnored() throws {
        let h = Harness()
        let editor = h.editor
        let marker = try #require(editor.addMarker(atFrame: 100))

        editor.previewMarkerFrame(id: marker.id, frame: -5)
        editor.previewMarkerFrame(id: marker.id, frame: editor.markerFrameLimit + 1)
        #expect(editor.timeline.marker(id: marker.id)?.frame == 100)
    }

    @Test func markersStayFrameOrderedWhileDragging() throws {
        let h = Harness()
        let editor = h.editor
        let first = try #require(editor.addMarker(atFrame: 10))
        _ = editor.addMarker(atFrame: 120)

        editor.previewMarkerFrame(id: first.id, frame: 250)
        #expect(editor.timeline.markers.map(\.frame) == [120, 250])
    }
}
