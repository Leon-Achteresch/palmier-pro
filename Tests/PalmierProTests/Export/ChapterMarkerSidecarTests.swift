import Foundation
import Testing
@testable import PalmierPro

@Suite("Chapter marker sidecar")
struct ChapterMarkerSidecarTests {

    @Test(arguments: [
        (0, 30, "00:00"),
        (45, 30, "00:01"),
        (30 * 62, 30, "01:02"),
        (30 * 3_599, 30, "59:59"),
        (30 * 3_600, 30, "1:00:00"),
        (24 * 3_723, 24, "1:02:03"),
        (25 * 36_000, 25, "10:00:00"),
    ])
    func formatsTimestampsWithHourRollover(frame: Int, fps: Int, expected: String) {
        #expect(ChapterSidecar.timestamp(frame: frame, fps: fps) == expected)
    }

    @Test func writesOneLinePerChapterMarkerInFrameOrder() {
        var timeline = Fixtures.timeline(fps: 30)
        timeline.upsertMarker(TimelineMarker(name: "Outro", startFrame: 30 * 3_601, kind: .chapter))
        timeline.upsertMarker(TimelineMarker(name: "Intro", startFrame: 0, kind: .chapter))
        timeline.upsertMarker(TimelineMarker(name: "Setup", startFrame: 30 * 90, kind: .chapter))
        timeline.upsertMarker(TimelineMarker(name: "Not a chapter", startFrame: 30 * 30, kind: .standard))

        let text = ChapterSidecar.text(markers: timeline.markers, fps: timeline.fps)

        #expect(text == "00:00 Intro\n01:30 Setup\n1:00:01 Outro\n")
    }

    @Test func unnamedChaptersFallBackToTheirNumberAndStayOnOneLine() {
        let markers = [
            TimelineMarker(name: "", startFrame: 0, kind: .chapter),
            TimelineMarker(name: "Two\nlines", startFrame: 60, kind: .chapter),
        ]

        #expect(ChapterSidecar.text(markers: markers, fps: 30) == "00:00 Chapter 1\n00:02 Two lines\n")
    }

    @Test func noChaptersOrInvalidFrameRateWritesNothing() {
        let standardOnly = [TimelineMarker(name: "Note", startFrame: 10, kind: .standard)]
        #expect(ChapterSidecar.text(markers: standardOnly, fps: 30) == nil)
        #expect(ChapterSidecar.text(markers: [], fps: 30) == nil)
        #expect(ChapterSidecar.text(markers: [TimelineMarker(name: "", startFrame: 0, kind: .chapter)], fps: 0) == nil)
    }

    @Test func sidecarSitsNextToTheExportedVideo() {
        let output = URL(fileURLWithPath: "/tmp/exports/My Cut.mp4")
        #expect(ChapterSidecar.url(nextTo: output).path == "/tmp/exports/My Cut.chapters.txt")
    }

    @Test func writesTheFileBesideTheOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chapters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("cut.mp4")

        let written = try await ChapterSidecar.write("00:00 Intro\n", nextTo: output)

        #expect(written == ChapterSidecar.url(nextTo: output))
        #expect(try String(contentsOf: written, encoding: .utf8) == "00:00 Intro\n")
    }
}
