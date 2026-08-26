import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite("Marker sketches")
struct MarkerSketchTests {
    private let size = CGSize(width: 200, height: 100)

    @Test func arrowBarbsTrailBehindTheTip() {
        let stroke = MarkerStroke(points: [.init(x: 0.1, y: 0.5), .init(x: 0.6, y: 0.5)], arrow: true)
        let plain = MarkerStroke(points: stroke.points)
        let head = stroke.cgPath(in: size).boundingBox
        #expect(plain.cgPath(in: size).boundingBox.height == 0)
        #expect(head.height > 0)
        #expect(head.maxX == 120)
    }

    @Test(arguments: [
        [MarkerStroke.Point(x: 0, y: 0)],
        [MarkerStroke.Point(x: 0, y: 0), MarkerStroke.Point(x: .nan, y: 1)],
    ])
    func degenerateStrokesAreInvalid(_ points: [MarkerStroke.Point]) {
        #expect(!MarkerStroke(points: points).isValid)
    }

    @Test func sketchSurvivesCodableRoundTrip() throws {
        var marker = TimelineMarker(name: "Note", startFrame: 12)
        marker.sketch = [MarkerStroke(points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.4)], arrow: true)]
        let decoded = try JSONDecoder().decode(
            TimelineMarker.self, from: try JSONEncoder().encode(marker)
        )
        #expect(decoded == marker)
    }

    @Test func legacyMarkerWithoutSketchDecodesEmpty() throws {
        let json = Data(#"{"id":"m","name":"Note","startFrame":0,"durationFrames":0,"color":{"r":0,"g":0,"b":1,"a":1},"comment":""}"#.utf8)
        #expect(try JSONDecoder().decode(TimelineMarker.self, from: json).sketch.isEmpty)
    }

    @MainActor
    @Test func invalidStrokeIsRejectedAndLeavesNoUndoStep() {
        let editor = EditorViewModel()
        editor.undo.attach(UndoManager())
        var marker = TimelineMarker(name: "Note", startFrame: 0)
        marker.sketch = [MarkerStroke(points: [.init(x: 0, y: 0)])]
        #expect(throws: TimelineMarkerValidationError.invalidSketch) {
            try editor.changeTimelineMarkers(creates: [marker], actionName: "Sketch Note")
        }
        #expect(editor.timeline.markers.isEmpty)
    }

    @MainActor
    @Test func onlyMarkersCoveringTheFrameShowTheirSketch() {
        let editor = EditorViewModel()
        var point = TimelineMarker(id: "p", name: "Point", startFrame: 30)
        point.sketch = [MarkerStroke(points: [.init(x: 0, y: 0), .init(x: 1, y: 1)])]
        var range = point
        range.id = "r"
        range.startFrame = 10
        range.durationFrames = 15
        editor.timeline.markers = [point, range, TimelineMarker(id: "n", name: "No sketch", startFrame: 30)]
        #expect(editor.sketchedTimelineMarkers(at: 30).map(\.id) == ["p"])
        #expect(editor.sketchedTimelineMarkers(at: 24).map(\.id) == ["r"])
        #expect(editor.sketchedTimelineMarkers(at: 25).isEmpty)
    }
}
