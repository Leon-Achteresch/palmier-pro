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
            TimelineMarker(name: "A", startFrame: 42),
            TimelineMarker(name: "B", startFrame: 90, kind: .chapter),
        ]
        let targets = SnapEngine.collectTargets(tracks: [], markers: markers)
        #expect(targets.map(\.frame) == [42, 90])
        #expect(targets.allSatisfy { $0.kind == .marker })
    }

    @Test func theDraggedMarkerIsNotASnapTargetForItself() {
        let marker = TimelineMarker(name: "A", startFrame: 42)
        let other = TimelineMarker(name: "B", startFrame: 90)
        let targets = SnapEngine.collectTargets(
            tracks: [], markers: [marker, other], excludeMarkerIds: [marker.id]
        )
        #expect(targets.map(\.frame) == [90])
    }

    @Test func aClipEdgeDragSnapsToANearbyMarker() {
        let track = Fixtures.videoTrack(clips: [Fixtures.clip(id: "drag", start: 0, duration: 50)])
        let marker = TimelineMarker(name: "C", startFrame: 120)
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
}
