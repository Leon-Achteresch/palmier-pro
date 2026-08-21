import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Ducking — audio mix ramps")
@MainActor
struct DuckingMixTests {

    static let fps = 30

    static func timeline(bedVolume: Double = 1.0) -> Timeline {
        var dialog = Fixtures.clip(id: "d", mediaRef: "loud", mediaType: .audio, start: 0, duration: 120)
        dialog.duckingRole = .dialog
        var bed = Fixtures.clip(
            id: "b", mediaRef: "bed", mediaType: .audio, start: 0, duration: 120, volume: bedVolume
        )
        bed.duckingRole = .bed
        var timeline = Fixtures.timeline(fps: fps, tracks: [
            Fixtures.audioTrack(id: "a1", clips: [dialog]),
            Fixtures.audioTrack(id: "a2", clips: [bed]),
        ])
        timeline.width = 320
        timeline.height = 180
        timeline.ducking = TimelineDuckingSettings(
            enabled: true, depthDb: -12, attackMs: 500, releaseMs: 1000, holdMs: 600
        )
        return timeline
    }

    static func build(_ timeline: Timeline) async throws -> CompositionResult {
        let directory = try AudioFixtures.temporaryDirectory()
        let loud = directory.appendingPathComponent("loud.caf")
        let bed = directory.appendingPathComponent("bed.caf")
        try AudioFixtures.writeTone(dbfs: -12, seconds: 5, to: loud)
        try AudioFixtures.writeTone(dbfs: -20, seconds: 5, to: bed)
        let urls = ["loud": loud, "bed": bed]
        return try await CompositionBuilder.build(
            timeline: timeline, resolveURL: { urls[$0] }, renderSize: CGSize(width: 320, height: 180)
        )
    }

    static func plan(for timeline: Timeline) -> DuckingPlan {
        let analysis = DuckingAnalyzer.analyze(timeline: timeline, spansByMediaRef: [
            "loud": [VoiceActivity.Span(start: 1, end: 2)],
            "bed": [],
        ])
        return DuckingAnalyzer.plan(timeline: timeline, analysis: analysis)
    }

    static func parameters(
        _ result: CompositionResult, _ audioMix: AVMutableAudioMix, trackIndex: Int
    ) -> AVAudioMixInputParameters? {
        let mapping = result.trackMappings.first { mapping in
            guard case .timeline(let index, _) = mapping.kind else { return false }
            return !mapping.isVideo && index == trackIndex
        }
        guard let mapping else { return nil }
        return audioMix.inputParameters.first { $0.trackID == mapping.compositionTrack.trackID }
    }

    static func volume(_ params: AVAudioMixInputParameters, atFrame frame: Int) -> Float? {
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange.zero
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        guard params.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range) else {
            return nil
        }
        guard range.duration > .zero else { return start }
        let progress = (time - range.start).seconds / range.duration.seconds
        return start + Float(progress) * (end - start)
    }

    static func visuals(
        _ timeline: Timeline, _ result: CompositionResult, ducking: DuckingPlan
    ) -> AVMutableAudioMix {
        CompositionBuilder.buildVisuals(
            timeline: timeline,
            trackMappings: result.trackMappings,
            compositionDuration: result.composition.duration,
            renderSize: CGSize(width: timeline.width, height: timeline.height),
            ducking: ducking
        ).audioMix
    }

    @Test func bedRidesTheDuckWhileDialogStaysFlat() async throws {
        let timeline = Self.timeline()
        let result = try await Self.build(timeline)
        let plan = Self.plan(for: timeline)
        #expect(plan.curve(forClipId: "b")?.intervals
            == [DuckInterval(attackStart: 15, fullStart: 30, fullEnd: 60, releaseEnd: 90)])

        let mix = Self.visuals(timeline, result, ducking: plan)
        let bed = try #require(Self.parameters(result, mix, trackIndex: 1))
        let dialog = try #require(Self.parameters(result, mix, trackIndex: 0))
        let depth = Float(VolumeScale.linearFromDb(-12))

        #expect(try #require(Self.volume(bed, atFrame: 0)) == 1)
        #expect(try #require(Self.volume(bed, atFrame: 15)) == 1)
        #expect(abs(try #require(Self.volume(bed, atFrame: 45)) - depth) < 0.001)
        #expect(abs(try #require(Self.volume(bed, atFrame: 60)) - depth) < 0.001)
        #expect(abs(try #require(Self.volume(bed, atFrame: 90)) - 1) < 0.001)
        #expect(abs(try #require(Self.volume(bed, atFrame: 119)) - 1) < 0.001)

        let midAttack = try #require(Self.volume(bed, atFrame: 22))
        #expect(midAttack < 1 && midAttack > depth)

        for frame in [0, 30, 45, 90] {
            #expect(abs(try #require(Self.volume(dialog, atFrame: frame)) - 1) < 0.001)
        }
    }

    @Test func duckMultipliesTheClipVolumeInsteadOfReplacingIt() async throws {
        let timeline = Self.timeline(bedVolume: 0.5)
        let result = try await Self.build(timeline)
        let mix = Self.visuals(timeline, result, ducking: Self.plan(for: timeline))
        let bed = try #require(Self.parameters(result, mix, trackIndex: 1))
        let depth = Float(VolumeScale.linearFromDb(-12))
        #expect(abs(try #require(Self.volume(bed, atFrame: 0)) - 0.5) < 0.001)
        #expect(abs(try #require(Self.volume(bed, atFrame: 45)) - 0.5 * depth) < 0.001)
    }

    @Test func duckComposesWithAFadeOut() async throws {
        var timeline = Self.timeline()
        timeline.tracks[1].clips[0].fadeOutFrames = 120
        let result = try await Self.build(timeline)
        let mix = Self.visuals(timeline, result, ducking: Self.plan(for: timeline))
        let bed = try #require(Self.parameters(result, mix, trackIndex: 1))
        let depth = Float(VolumeScale.linearFromDb(-12))
        #expect(abs(try #require(Self.volume(bed, atFrame: 60)) - 0.5 * depth) < 0.01)
        #expect(abs(try #require(Self.volume(bed, atFrame: 0)) - 1) < 0.001)
    }

    @Test func anEmptyPlanLeavesTheMixUntouched() async throws {
        let timeline = Self.timeline()
        let result = try await Self.build(timeline)
        let ducked = Self.visuals(timeline, result, ducking: Self.plan(for: timeline))
        let plain = Self.visuals(timeline, result, ducking: .empty)
        let bedDucked = try #require(Self.parameters(result, ducked, trackIndex: 1))
        let bedPlain = try #require(Self.parameters(result, plain, trackIndex: 1))
        #expect(try #require(Self.volume(bedPlain, atFrame: 45)) == 1)
        #expect(try #require(Self.volume(bedDucked, atFrame: 45)) < 1)
    }

    @Test func buildSkipsTheSpeechCacheWhileDuckingIsOff() async throws {
        var timeline = Self.timeline()
        timeline.ducking.enabled = false
        let result = try await Self.build(timeline)
        #expect(result.ducking.isEmpty)
    }
}
