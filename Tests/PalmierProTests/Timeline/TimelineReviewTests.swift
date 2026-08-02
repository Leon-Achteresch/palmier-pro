import Foundation
import Testing
@testable import PalmierPro

@Suite struct TimelineReviewTests {
    @Test func shotStatsComputesPacingAndLongestClip() throws {
        let clips = [
            Fixtures.clip(id: "a", start: 0, duration: 30),
            Fixtures.clip(id: "b", start: 30, duration: 60),
            Fixtures.clip(id: "c", start: 90, duration: 300),
        ]
        let stats = TimelineReview.shotStats(clips: clips, fps: 30, totalFrames: 390)
        let unwrapped = try #require(stats)
        #expect(unwrapped.pacing.shotCount == 3)
        #expect(abs(unwrapped.pacing.averageShotSeconds - 13.0 / 3.0) < 0.001)
        #expect(unwrapped.pacing.medianShotSeconds == 2.0)
        #expect(unwrapped.longestClipId == "c")
        #expect(unwrapped.longestSeconds == 10.0)
    }

    @Test func shotStatsIgnoresTextClipsAndEmptyInput() {
        let textOnly = [Fixtures.clip(mediaType: .text, start: 0, duration: 30)]
        #expect(TimelineReview.shotStats(clips: textOnly, fps: 30, totalFrames: 30) == nil)
        #expect(TimelineReview.shotStats(clips: [], fps: 30, totalFrames: 0) == nil)
    }

    @Test func gapsFindsLeadingAndInteriorHoles() {
        let clips = [
            Fixtures.clip(start: 10, duration: 20),
            Fixtures.clip(start: 50, duration: 10),
            Fixtures.clip(start: 60, duration: 10),
        ]
        let gaps = TimelineReview.gaps(in: clips)
        #expect(gaps.count == 2)
        #expect(gaps[0] == (0, 10))
        #expect(gaps[1] == (30, 50))
    }

    @Test func gapsHandlesOverlappingClips() {
        let clips = [
            Fixtures.clip(start: 0, duration: 100),
            Fixtures.clip(start: 20, duration: 30),
        ]
        #expect(TimelineReview.gaps(in: clips).isEmpty)
    }

    @Test func cutFramesSkipsFirstClipAndTextClips() {
        let clips = [
            Fixtures.clip(start: 0, duration: 30),
            Fixtures.clip(mediaType: .text, start: 15, duration: 30),
            Fixtures.clip(start: 30, duration: 30),
        ]
        #expect(TimelineReview.cutFrames(clips) == [30])
    }

    @Test(arguments: [
        ([30, 60, 90], [29, 61, 100], 2, 2.0 / 3.0),
        ([30], [200], 2, 0.0),
        ([30, 60], [30, 60], 2, 1.0),
    ] as [([Int], [Int], Int, Double)])
    func beatAlignmentMatchedFraction(cuts: [Int], beats: [Int], tolerance: Int, expected: Double) {
        let alignment = TimelineReview.beatAlignment(cutFrames: cuts, beatFrames: beats, toleranceFrames: tolerance)
        #expect(abs((alignment?.matchedFraction ?? -1) - expected) < 0.001)
    }

    @Test func beatAlignmentNilWithoutCutsOrBeats() {
        #expect(TimelineReview.beatAlignment(cutFrames: [], beatFrames: [10], toleranceFrames: 2) == nil)
        #expect(TimelineReview.beatAlignment(cutFrames: [10], beatFrames: [], toleranceFrames: 2) == nil)
    }

    @Test func primaryVideoTrackPicksMostVideoClips() {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(mediaType: .text, start: 0, duration: 10)]),
            Fixtures.videoTrack(clips: [
                Fixtures.clip(start: 0, duration: 10),
                Fixtures.clip(start: 10, duration: 10),
            ]),
            Fixtures.audioTrack(clips: [Fixtures.clip(mediaType: .audio, start: 0, duration: 10)]),
        ])
        #expect(TimelineReview.primaryVideoTrackIndex(timeline) == 1)
    }

    @Test func findingsFlagsGapsLongShotsAndSlowPacingAgainstReference() {
        let stats = TimelineShotStats(
            pacing: PacingStats(
                shotCount: 3,
                averageShotSeconds: 9,
                medianShotSeconds: 2,
                sectionAverageShotSeconds: [2, 2, 20]
            ),
            longestSeconds: 20,
            longestClipId: "long"
        )
        let reference = ReferenceProfile(
            id: "ref1",
            name: "Fast Reel",
            sourceFileName: "reel.mp4",
            createdDate: Date(),
            durationSeconds: 30,
            pacing: PacingStats(
                shotCount: 20,
                averageShotSeconds: 1.5,
                medianShotSeconds: 1.2,
                sectionAverageShotSeconds: [1, 1.5, 2]
            ),
            bpm: nil,
            audio: nil,
            look: nil
        )
        let findings = TimelineReview.findings(
            stats: stats,
            gaps: [(100, 130)],
            fps: 30,
            alignment: BeatAlignment(matchedFraction: 0.1, meanAbsOffsetFrames: 12),
            beatCount: 20,
            toleranceFrames: 2,
            reference: reference
        )
        #expect(findings.contains { $0.contains("frames 100–130") })
        #expect(findings.contains { $0.contains("long") && $0.contains("20.0s") })
        #expect(findings.contains { $0.contains("beat") })
        #expect(findings.contains { $0.contains("slower than reference 'Fast Reel'") })
    }

    @Test func findingsEmptyForCleanTimeline() {
        let stats = TimelineShotStats(
            pacing: PacingStats(
                shotCount: 10,
                averageShotSeconds: 2,
                medianShotSeconds: 2,
                sectionAverageShotSeconds: [2, 2, 2]
            ),
            longestSeconds: 3,
            longestClipId: "a"
        )
        let findings = TimelineReview.findings(
            stats: stats,
            gaps: [],
            fps: 30,
            alignment: BeatAlignment(matchedFraction: 0.9, meanAbsOffsetFrames: 1),
            beatCount: 20,
            toleranceFrames: 2,
            reference: nil
        )
        #expect(findings.isEmpty)
    }
}

@Suite struct ShotPacingTests {
    @Test func sectionsSplitByMidpointThirds() throws {
        let shots: [(midpoint: Double, seconds: Double)] = [
            (1, 2), (11, 2), (21, 4), (29, 6),
        ]
        let stats = try #require(ShotPacing.stats(shots: shots, duration: 30))
        #expect(stats.sectionAverageShotSeconds == [2, 2, 5])
        #expect(stats.shotCount == 4)
    }

    @Test func emptyShotsReturnNil() {
        #expect(ShotPacing.stats(shots: [], duration: 30) == nil)
        #expect(ShotPacing.stats(shots: [(1, 2)], duration: 0) == nil)
    }
}

@Suite struct ReferenceAnalyzerPacingTests {
    @Test func pacingFromShotStartsCoversFullDuration() throws {
        let pacing = try #require(ReferenceAnalyzer.pacing(shotStarts: [2, 5, 9], duration: 12))
        #expect(pacing.shotCount == 4)
        #expect(abs(pacing.averageShotSeconds - 3) < 0.001)
    }

    @Test func pacingDropsOutOfRangeBoundaries() throws {
        let pacing = try #require(ReferenceAnalyzer.pacing(shotStarts: [-1, 0, 6, 15], duration: 12))
        #expect(pacing.shotCount == 2)
    }
}

@Suite struct ReferenceLibraryTests {
    @MainActor
    @Test func addRemoveRoundTripsThroughDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("references.json")

        let profile = ReferenceProfile(
            id: "abc12345",
            name: "Test",
            sourceFileName: "test.mp4",
            createdDate: Date(),
            durationSeconds: 10,
            pacing: PacingStats(
                shotCount: 2,
                averageShotSeconds: 5,
                medianShotSeconds: 5,
                sectionAverageShotSeconds: [5, 5, 0]
            ),
            bpm: 120,
            audio: AudioStats(energyMean: 0.5, quietFraction: 0.1),
            look: LookStats(lumaMean: 0.4, saturationMean: 0.3, warmCoolBias: 0.05, hueHistogram: [1, 0, 0])
        )

        let library = ReferenceLibrary(fileURL: fileURL)
        try await library.add(profile)
        #expect(library.profiles.count == 1)

        let reloaded = ReferenceLibrary(fileURL: fileURL)
        let found = await reloaded.profile(id: "abc12345")
        #expect(found?.name == "Test")
        #expect(found?.pacing?.shotCount == 2)
        #expect(found?.look?.hueHistogram == [1, 0, 0])

        let removed = try await reloaded.remove(id: "abc12345")
        #expect(removed)
        let empty = ReferenceLibrary(fileURL: fileURL)
        await empty.ensureLoaded()
        #expect(empty.profiles.isEmpty)
    }

    @MainActor
    @Test func removeUnknownIdReturnsFalseWithoutWriting() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-library-\(UUID().uuidString).json")
        let library = ReferenceLibrary(fileURL: fileURL)
        let removed = try await library.remove(id: "missing")
        #expect(!removed)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
