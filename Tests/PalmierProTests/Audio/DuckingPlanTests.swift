import Foundation
import Testing
@testable import PalmierPro

@Suite("Ducking — plan math")
struct DuckingPlanTests {

    static func settings(
        depthDb: Double = -12, attackMs: Double = 150, releaseMs: Double = 400, holdMs: Double = 600
    ) -> TimelineDuckingSettings {
        TimelineDuckingSettings(
            enabled: true, depthDb: depthDb, attackMs: attackMs, releaseMs: releaseMs, holdMs: holdMs
        )
    }

    @Test func mergesOverlappingSpeechSpans() {
        let merged = DuckingPlan.mergedSpeech(
            [FrameRange(start: 100, end: 200), FrameRange(start: 150, end: 260)], bridgeFrames: 0
        )
        #expect(merged == [FrameRange(start: 100, end: 260)])
    }

    @Test func bridgesGapsUpToTheHoldWindowAndKeepsLongerOnesApart() {
        let spans = [FrameRange(start: 0, end: 50), FrameRange(start: 90, end: 140)]
        #expect(DuckingPlan.mergedSpeech(spans, bridgeFrames: 60) == [FrameRange(start: 0, end: 140)])
        #expect(DuckingPlan.mergedSpeech(spans, bridgeFrames: 30) == spans)
    }

    @Test func ignoresEmptySpans() {
        #expect(DuckingPlan.mergedSpeech([], bridgeFrames: 10).isEmpty)
        #expect(DuckingPlan.mergedSpeech([FrameRange(start: 10, end: 10)], bridgeFrames: 10).isEmpty)
    }

    @Test func buildsAttackAndReleaseRampsAroundSpeech() throws {
        let intervals = DuckingPlan.intervals(
            forSpeech: [FrameRange(start: 100, end: 200)],
            clipRange: FrameRange(start: 0, end: 400),
            attackFrames: 15,
            releaseFrames: 40
        )
        let interval = try #require(intervals.first)
        #expect(intervals.count == 1)
        #expect(interval == DuckInterval(attackStart: 85, fullStart: 100, fullEnd: 200, releaseEnd: 240))
    }

    @Test func clampsRampsToTheBedClipSpan() throws {
        let intervals = DuckingPlan.intervals(
            forSpeech: [FrameRange(start: 100, end: 400)],
            clipRange: FrameRange(start: 95, end: 220),
            attackFrames: 15,
            releaseFrames: 40
        )
        let interval = try #require(intervals.first)
        #expect(interval == DuckInterval(attackStart: 95, fullStart: 100, fullEnd: 220, releaseEnd: 220))
    }

    @Test func dropsSpeechOutsideTheBedClip() {
        #expect(DuckingPlan.intervals(
            forSpeech: [FrameRange(start: 0, end: 50)],
            clipRange: FrameRange(start: 100, end: 200),
            attackFrames: 15, releaseFrames: 40
        ).isEmpty)
    }

    @Test func refusesAZeroLengthClipRange() {
        #expect(DuckingPlan.intervals(
            forSpeech: [FrameRange(start: 0, end: 50)],
            clipRange: FrameRange(start: 10, end: 10),
            attackFrames: 15, releaseFrames: 40
        ).isEmpty)
    }

    @Test func mergesDucksWhoseRampsWouldCollide() throws {
        let intervals = DuckingPlan.intervals(
            forSpeech: [FrameRange(start: 100, end: 150), FrameRange(start: 170, end: 220)],
            clipRange: FrameRange(start: 0, end: 400),
            attackFrames: 15,
            releaseFrames: 40
        )
        #expect(intervals.count == 1)
        #expect(try #require(intervals.first)
            == DuckInterval(attackStart: 85, fullStart: 100, fullEnd: 220, releaseEnd: 260))
    }

    @Test func gainRidesFromUnityToDepthAndBack() {
        let depth = VolumeScale.linearFromDb(-12)
        let curve = DuckingCurve(
            intervals: [DuckInterval(attackStart: 100, fullStart: 120, fullEnd: 200, releaseEnd: 240)],
            depthGain: depth
        )
        #expect(curve.gain(atFrame: 0) == 1)
        #expect(curve.gain(atFrame: 100) == 1)
        #expect(abs(curve.gain(atFrame: 110) - (1 + (depth - 1) * 0.5)) < 0.0001)
        #expect(curve.gain(atFrame: 120) == depth)
        #expect(curve.gain(atFrame: 200) == depth)
        #expect(abs(curve.gain(atFrame: 220) - (depth + (1 - depth) * 0.5)) < 0.0001)
        #expect(curve.gain(atFrame: 240) == 1)
        #expect(curve.gain(atFrame: 5_000) == 1)
    }

    @Test func gainStaysUnityBetweenDucks() {
        let curve = DuckingCurve(
            intervals: [
                DuckInterval(attackStart: 0, fullStart: 10, fullEnd: 20, releaseEnd: 30),
                DuckInterval(attackStart: 100, fullStart: 110, fullEnd: 120, releaseEnd: 130),
            ],
            depthGain: 0.25
        )
        #expect(curve.gain(atFrame: 60) == 1)
        #expect(curve.gain(atFrame: 115) == 0.25)
    }

    // MARK: - Analyzer

    static func timeline(
        dialog: Clip, bed: Clip, settings: TimelineDuckingSettings, fps: Int = 100
    ) -> Timeline {
        var timeline = Fixtures.timeline(fps: fps, tracks: [
            Fixtures.audioTrack(clips: [dialog]),
            Fixtures.audioTrack(clips: [bed]),
        ])
        timeline.ducking = settings
        return timeline
    }

    static func speechClip(id: String, mediaRef: String, start: Int, duration: Int) -> Clip {
        Fixtures.clip(id: id, mediaRef: mediaRef, mediaType: .audio, start: start, duration: duration)
    }

    @Test func classifiesMostlySpeechMediaAsDialogAndTheRestAsBed() {
        let dialog = Self.speechClip(id: "d", mediaRef: "voice", start: 0, duration: 1000)
        let bed = Self.speechClip(id: "b", mediaRef: "music", start: 0, duration: 1000)
        let timeline = Self.timeline(dialog: dialog, bed: bed, settings: Self.settings())
        let analysis = DuckingAnalyzer.analyze(timeline: timeline, spansByMediaRef: [
            "voice": [VoiceActivity.Span(start: 1, end: 8)],
            "music": [VoiceActivity.Span(start: 0, end: 0.2)],
        ])
        #expect(analysis.rolesByClipId["d"] == .dialog)
        #expect(analysis.rolesByClipId["b"] == .bed)
    }

    @Test func explicitRoleOverridesTheAutomaticCall() {
        var bed = Self.speechClip(id: "b", mediaRef: "voice", start: 0, duration: 1000)
        bed.duckingRole = .bed
        var dialog = Self.speechClip(id: "d", mediaRef: "music", start: 0, duration: 1000)
        dialog.duckingRole = .dialog
        let timeline = Self.timeline(dialog: dialog, bed: bed, settings: Self.settings())
        let analysis = DuckingAnalyzer.analyze(timeline: timeline, spansByMediaRef: [
            "voice": [VoiceActivity.Span(start: 1, end: 8)],
            "music": [VoiceActivity.Span(start: 0, end: 0.2)],
        ])
        #expect(analysis.rolesByClipId["b"] == .bed)
        #expect(analysis.rolesByClipId["d"] == .dialog)
    }

    @Test func leavesAClipUnclassifiedWithoutSpeechAnalysis() {
        let dialog = Self.speechClip(id: "d", mediaRef: "voice", start: 0, duration: 1000)
        let bed = Self.speechClip(id: "b", mediaRef: "music", start: 0, duration: 1000)
        let timeline = Self.timeline(dialog: dialog, bed: bed, settings: Self.settings())
        let analysis = DuckingAnalyzer.analyze(timeline: timeline, spansByMediaRef: [:])
        #expect(analysis.rolesByClipId.isEmpty)
        #expect(analysis.unanalyzedMediaRefs == ["voice", "music"])
        #expect(DuckingAnalyzer.plan(timeline: timeline, analysis: analysis).isEmpty)
    }

    @Test func planDucksTheBedUnderDialogSpeech() throws {
        var dialog = Self.speechClip(id: "d", mediaRef: "voice", start: 200, duration: 500)
        dialog.duckingRole = .dialog
        var bed = Self.speechClip(id: "b", mediaRef: "music", start: 0, duration: 1000)
        bed.duckingRole = .bed
        let timeline = Self.timeline(dialog: dialog, bed: bed, settings: Self.settings())
        let analysis = DuckingAnalyzer.analyze(timeline: timeline, spansByMediaRef: [
            "voice": [VoiceActivity.Span(start: 1, end: 3)],
            "music": [],
        ])
        let plan = DuckingAnalyzer.plan(timeline: timeline, analysis: analysis)
        let curve = try #require(plan.curve(forClipId: "b"))
        #expect(plan.curve(forClipId: "d") == nil)
        #expect(curve.intervals == [DuckInterval(attackStart: 285, fullStart: 300, fullEnd: 500, releaseEnd: 540)])
        #expect(abs(curve.depthGain - VolumeScale.linearFromDb(-12)) < 0.0001)
    }

    @Test func planIsEmptyWhileDuckingIsOff() {
        var dialog = Self.speechClip(id: "d", mediaRef: "voice", start: 0, duration: 1000)
        dialog.duckingRole = .dialog
        var bed = Self.speechClip(id: "b", mediaRef: "music", start: 0, duration: 1000)
        bed.duckingRole = .bed
        var settings = Self.settings()
        settings.enabled = false
        let timeline = Self.timeline(dialog: dialog, bed: bed, settings: settings)
        let analysis = DuckingAnalyzer.analyze(timeline: timeline, spansByMediaRef: [
            "voice": [VoiceActivity.Span(start: 1, end: 3)],
        ])
        #expect(DuckingAnalyzer.plan(timeline: timeline, analysis: analysis).isEmpty)
    }

    @Test func mutedTracksNeitherDuckNorGetDucked() {
        var dialog = Self.speechClip(id: "d", mediaRef: "voice", start: 0, duration: 1000)
        dialog.duckingRole = .dialog
        var bed = Self.speechClip(id: "b", mediaRef: "music", start: 0, duration: 1000)
        bed.duckingRole = .bed
        var timeline = Self.timeline(dialog: dialog, bed: bed, settings: Self.settings())
        timeline.tracks[0].muted = true
        let analysis = DuckingAnalyzer.analyze(timeline: timeline, spansByMediaRef: [
            "voice": [VoiceActivity.Span(start: 1, end: 3)],
        ])
        #expect(analysis.rolesByClipId["d"] == nil)
        #expect(DuckingAnalyzer.plan(timeline: timeline, analysis: analysis).isEmpty)
    }

    @Test func settingsClampOutOfRangeAndNonFiniteValues() {
        let normalized = TimelineDuckingSettings(
            enabled: true, depthDb: 40, attackMs: -10, releaseMs: .nan, holdMs: 99_999
        ).normalized
        #expect(normalized.depthDb == DuckingLimits.depthDb.upperBound)
        #expect(normalized.attackMs == DuckingLimits.attackMs.lowerBound)
        #expect(normalized.releaseMs == DuckingLimits.releaseMsDefault)
        #expect(normalized.holdMs == DuckingLimits.holdMs.upperBound)
    }

    @Test func settingsSurviveAnEncodeDecodeRoundTrip() throws {
        var timeline = Fixtures.timeline()
        timeline.ducking = Self.settings(depthDb: -8, attackMs: 90, releaseMs: 300, holdMs: 400)
        let decoded = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(decoded.ducking == timeline.ducking)
    }
}

@Suite("Ducking — platform presets")
struct MixPlatformPresetTests {
    @Test(arguments: [
        (MixPlatformPreset.youtube, -14.0, -16.0, -28.0, -20.0, -1.0),
        (MixPlatformPreset.podcast, -16.0, -18.0, -30.0, -22.0, -1.0),
        (MixPlatformPreset.film, -23.0, -25.0, -37.0, -29.0, -2.0),
    ])
    func mapsToProgramDialogBedAndSfxTargets(
        preset: MixPlatformPreset,
        program: Double,
        dialog: Double,
        bed: Double,
        sfx: Double,
        ceiling: Double
    ) {
        #expect(preset.programLufs == program)
        #expect(preset.dialogLufs == dialog)
        #expect(preset.targetLufs(for: .dialog) == dialog)
        #expect(preset.targetLufs(for: .bed) == bed)
        #expect(preset.targetLufs(for: .sfx) == sfx)
        #expect(preset.targetLufs(for: .exempt) == nil)
        #expect(preset.truePeakCeilingDbtp == ceiling)
    }
}
