import Foundation
import Testing
@testable import PalmierPro

@Suite("Export — chapter sidecar warnings")
struct ChapterSidecarWarningTests {

    private let markers = [
        TimelineMarker(name: "Intro", startFrame: 0, kind: .chapter),
        TimelineMarker(name: "Middle", startFrame: 90, kind: .chapter),
    ]

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("palmier-chapters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writingChaptersSucceedsSilently() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.mp4")

        let warning = await ChapterSidecar.writeIfNeeded(markers: markers, fps: 30, nextTo: output)
        #expect(warning == nil)
        #expect(FileManager.default.fileExists(atPath: ChapterSidecar.url(nextTo: output).path))
    }

    @Test func aTimelineWithoutChapterMarkersWritesNothingAndWarnsNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.mp4")

        let warning = await ChapterSidecar.writeIfNeeded(
            markers: [TimelineMarker(name: "", startFrame: 5, kind: .standard)], fps: 30, nextTo: output
        )
        #expect(warning == nil)
        #expect(!FileManager.default.fileExists(atPath: ChapterSidecar.url(nextTo: output).path))
    }

    @Test func anUnwritableDestinationComesBackAsAWarning() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("movie.mp4")
        // The sidecar path is taken by a directory, so the write cannot land.
        try FileManager.default.createDirectory(
            at: ChapterSidecar.url(nextTo: output), withIntermediateDirectories: true
        )

        let warning = await ChapterSidecar.writeIfNeeded(markers: markers, fps: 30, nextTo: output)
        #expect(warning?.hasPrefix("Chapters file could not be written") == true)
    }

    @Test func reportWarningsCountTowardsAJobsWarningCount() {
        let job = ExportJob(
            id: UUID(), projectID: "p1", filename: "movie.mp4", source: .agent,
            outputURL: URL(fileURLWithPath: "/tmp/movie.mp4"), createdAt: Date(),
            status: .completed, progress: 1, error: nil, warnings: [], palmierReport: nil
        )
        let clean = ExportRunReport(
            outputSize: .zero, offlineMediaRefs: [], unprocessableMediaRefs: [], warnings: []
        )
        let warned = ExportRunReport(
            outputSize: .zero, offlineMediaRefs: [], unprocessableMediaRefs: [],
            warnings: ["Chapters file could not be written next to the video: disk full"]
        )
        #expect(job.warningCount(clean) == 0)
        #expect(job.warningCount(warned) == 1)
    }
}
