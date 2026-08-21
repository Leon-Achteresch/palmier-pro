import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Transitions — audio crossfade")
@MainActor
struct TransitionAudioTests {

    static let fps = 30
    static let cutFrame = 60
    static let transitionFrames = 20

    static func transition(alignment: TransitionAlignment = .centered) -> ClipTransition {
        ClipTransition(
            id: "t1", style: .crossDissolve, direction: nil,
            durationFrames: transitionFrames, alignment: alignment,
            fromClipId: "a", toClipId: "b"
        )
    }

    /// Two adjacent video clips with linked audio, each with 30 frames of handle on both sides.
    static func timeline(_ transition: ClipTransition?, linked: Bool = true) -> Timeline {
        var videoA = Fixtures.clip(id: "a", mediaRef: "pattern", start: 0, duration: 60, trimStart: 30, trimEnd: 30)
        var videoB = Fixtures.clip(id: "b", mediaRef: "midtone", start: 60, duration: 60, trimStart: 30, trimEnd: 30)
        var audioA = Fixtures.clip(
            id: "aa", mediaRef: "loud", mediaType: .audio, start: 0, duration: 60, trimStart: 30, trimEnd: 30
        )
        var audioB = Fixtures.clip(
            id: "ab", mediaRef: "silent", mediaType: .audio, start: 60, duration: 60, trimStart: 30, trimEnd: 30
        )
        if linked {
            videoA.linkGroupId = "g1"
            audioA.linkGroupId = "g1"
            videoB.linkGroupId = "g2"
            audioB.linkGroupId = "g2"
        }
        var videoTrack = Fixtures.videoTrack(id: "v1", clips: [videoA, videoB])
        if let transition { videoTrack.transitions = [transition] }
        return CompositorFixtures.timeline([
            videoTrack,
            Fixtures.audioTrack(id: "a1", clips: [audioA, audioB]),
        ])
    }

    static func mediaURLs() async throws -> [String: URL] {
        let directory = try AudioFixtures.temporaryDirectory()
        let loud = directory.appendingPathComponent("loud.caf")
        let silent = directory.appendingPathComponent("silent.caf")
        try AudioFixtures.writeTone(dbfs: -12, seconds: 6, to: loud)
        try AudioFixtures.writeTone(dbfs: nil, seconds: 6, to: silent)
        return [
            "pattern": try await CompositorFixtures.patternVideoURL(),
            "midtone": try await CompositorFixtures.midtoneVideoURL(),
            "loud": loud,
            "silent": silent,
        ]
    }

    static func build(_ timeline: Timeline) async throws -> CompositionResult {
        let urls = try await mediaURLs()
        return try await CompositionBuilder.build(
            timeline: timeline, resolveURL: { urls[$0] }, renderSize: CompositorFixtures.renderSize
        )
    }

    static func parameters(
        _ result: CompositionResult, kind: (TrackMapping.Kind) -> Bool
    ) -> AVAudioMixInputParameters? {
        guard let mapping = result.trackMappings.first(where: { !$0.isVideo && kind($0.kind) }) else { return nil }
        return result.audioMix.inputParameters.first { $0.trackID == mapping.compositionTrack.trackID }
    }

    /// The mix's volume at a frame, interpolated inside whichever ramp covers it.
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

    // MARK: - Resolution

    @Test func equalPowerGainsSumToConstantPower() {
        let window = TransitionWindow(cutFrame: 60, startFrame: 50, durationFrames: 20)
        for frame in window.startFrame...window.endFrame {
            let out = TransitionAudioExtension.equalPowerGain(role: .outgoing, window: window, frame: frame)
            let incoming = TransitionAudioExtension.equalPowerGain(role: .incoming, window: window, frame: frame)
            #expect(abs(out * out + incoming * incoming - 1) < 0.0001)
        }
        #expect(TransitionAudioExtension.equalPowerGain(role: .outgoing, window: window, frame: 50) == 1)
        #expect(abs(TransitionAudioExtension.equalPowerGain(role: .incoming, window: window, frame: 70) - 1) < 0.0001)
        let midOut = TransitionAudioExtension.equalPowerGain(role: .outgoing, window: window, frame: 60)
        #expect(abs(midOut - 0.5.squareRoot()) < 0.0001)
    }

    @Test func crossfadeResolvesForLinkedNeighboursOnOneAudioTrack() throws {
        let crossfades = TransitionAudioExtension.crossfades(in: Self.timeline(Self.transition()))
        let crossfade = try #require(crossfades.first)
        #expect(crossfades.count == 1)
        #expect(crossfade.transitionId == "t1")
        #expect(crossfade.audioTrackIndex == 1)
        #expect(crossfade.outgoing.id == "aa")
        #expect(crossfade.incoming.id == "ab")
        #expect(crossfade.window.startFrame == 50)
        #expect(crossfade.window.endFrame == 70)
    }

    @Test func unlinkedNeighboursGetNoAudioCrossfade() {
        #expect(TransitionAudioExtension.crossfades(in: Self.timeline(Self.transition(), linked: false)).isEmpty)
    }

    @Test func audioWithoutHandleOnTheCutEdgeGetsNoCrossfade() {
        var timeline = Self.timeline(Self.transition())
        timeline.tracks[1].clips[0].trimEndFrame = 0
        #expect(TransitionAudioExtension.crossfades(in: timeline).isEmpty)
    }

    @Test func audioThatDoesNotMeetTheVideoCutGetsNoCrossfade() {
        var timeline = Self.timeline(Self.transition())
        timeline.tracks[1].clips[0].durationFrames = 50
        #expect(TransitionAudioExtension.crossfades(in: timeline).isEmpty)
    }

    @Test func aDenoisedNeighbourKeepsTheHardCutRatherThanFadingTheDrySource() {
        var timeline = Self.timeline(Self.transition())
        timeline.tracks[1].clips[0].effects = [
            Effect(type: Clip.denoiseEffectType, params: ["amount": EffectParam(value: 1)])
        ]
        #expect(TransitionAudioExtension.crossfades(in: timeline).isEmpty)
    }

    @Test func aFadeOnTheCutEdgeRefusesTheCrossfade() {
        var timeline = Self.timeline(Self.transition())
        timeline.tracks[1].clips[0].fadeOutFrames = 5
        #expect(TransitionAudioExtension.crossfades(in: timeline).isEmpty)
    }

    @Test func handleLanesCoverBothHalvesOfTheWindow() throws {
        let crossfades = TransitionAudioExtension.crossfades(in: Self.timeline(Self.transition()))
        let handles = TransitionAudioExtension.handles(forAudioTrackIndex: 1, crossfades: crossfades)
        #expect(handles.count == 2)
        let head = try #require(handles.first { $0.role == .incoming })
        let tail = try #require(handles.first { $0.role == .outgoing })
        #expect(head.clip.startFrame == 50)
        #expect(head.clip.durationFrames == 10)
        #expect(head.clip.trimStartFrame == 20)
        #expect(tail.clip.startFrame == 60)
        #expect(tail.clip.durationFrames == 10)
        #expect(tail.clip.trimStartFrame == 90)
    }

    // MARK: - Composition build

    @Test func theBuildAddsAHandleLaneAndRampsBothSidesEqualPower() async throws {
        let result = try await Self.build(Self.timeline(Self.transition()))

        let laneParams = try #require(Self.parameters(result) {
            if case .transitionHandles = $0 { return true }
            return false
        })
        let trackParams = try #require(Self.parameters(result) {
            if case .timeline(let index, _) = $0 { return index == 1 }
            return false
        })

        let root2 = Float(0.5.squareRoot())
        // Outgoing lives on the timeline lane until the cut, then on the handle lane.
        #expect(abs(try #require(Self.volume(trackParams, atFrame: 50)) - 1) < 0.01)
        #expect(abs(try #require(Self.volume(trackParams, atFrame: 60)) - root2) < 0.03)
        #expect(abs(try #require(Self.volume(laneParams, atFrame: 60)) - root2) < 0.03)
        #expect(try #require(Self.volume(laneParams, atFrame: 69)) < 0.15)
        // Incoming rides the handle lane before the cut and the timeline lane after it.
        #expect(try #require(Self.volume(laneParams, atFrame: 50)) < 0.05)
        #expect(abs(try #require(Self.volume(laneParams, atFrame: 59)) - 0.707) < 0.12)
        #expect(abs(try #require(Self.volume(trackParams, atFrame: 60)) - root2) < 0.03)
        #expect(abs(try #require(Self.volume(trackParams, atFrame: 70)) - 1) < 0.01)
    }

    @Test func withoutATransitionThereIsNoHandleLane() async throws {
        let result = try await Self.build(Self.timeline(nil))
        #expect(Self.parameters(result) {
            if case .transitionHandles = $0 { return true }
            return false
        } == nil)
    }

    // MARK: - Rendered audio

    static func truePeakDbtp(_ timeline: Timeline, frames: Range<Int>) async throws -> Double? {
        let result = try await build(timeline)
        for track in result.composition.tracks(withMediaType: .video) {
            result.composition.removeTrack(track)
        }
        let timescale = CMTimeScale(fps)
        let range = CMTimeRange(
            start: CMTime(value: CMTimeValue(frames.lowerBound), timescale: timescale),
            duration: CMTime(value: CMTimeValue(frames.count), timescale: timescale)
        )
        let measurement = try await LoudnessAnalyzer.measure(
            .init(asset: result.composition, audioMix: result.audioMix, timeRange: range)
        )
        return measurement.truePeakDbtp
    }

    @Test func theOutgoingClipKeepsPlayingPastTheCutInsteadOfStopping() async throws {
        let withTransition = try await Self.truePeakDbtp(Self.timeline(Self.transition()), frames: 60..<66)
        let hardCut = try await Self.truePeakDbtp(Self.timeline(nil), frames: 60..<66)

        let audible = try #require(withTransition)
        #expect(audible > -20 && audible < -13, "outgoing should continue near -15 dBTP: \(audible)")
        #expect(hardCut == nil || hardCut! < -60, "a hard cut leaves silence after the cut: \(String(describing: hardCut))")
    }

    @Test func theOutgoingClipIsFullyGoneOnceTheWindowCloses() async throws {
        let after = try await Self.truePeakDbtp(Self.timeline(Self.transition()), frames: 72..<90)
        #expect(after == nil || after! < -60, "past the window only the silent incoming clip remains: \(String(describing: after))")
    }
}
