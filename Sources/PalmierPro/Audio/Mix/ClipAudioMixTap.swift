import AVFoundation
import MediaToolbox
import os

struct ClipAudioMixSegment: Sendable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let mix: ClipAudioMix
}

enum ClipAudioMixTap {
    static func segments(for clips: [Clip], fps: Int) -> [ClipAudioMixSegment] {
        guard fps > 0 else { return [] }
        let rate = Double(fps)
        return clips.compactMap { clip in
            guard clip.durationFrames > 0, let mix = clip.audioMix?.normalized else { return nil }
            return ClipAudioMixSegment(
                startSeconds: Double(clip.startFrame) / rate,
                endSeconds: Double(clip.endFrame) / rate,
                mix: mix
            )
        }
    }

    static func make(segments: [ClipAudioMixSegment]) -> MTAudioProcessingTap? {
        let usable = segments
            .filter { $0.endSeconds > $0.startSeconds && !$0.mix.isBypass }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !usable.isEmpty else { return nil }

        let state = TapState(segments: usable)
        let clientInfo = Unmanaged.passRetained(state).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: { _, clientInfo, tapStorageOut in tapStorageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.prepare(format: format.pointee)
            },
            unprepare: nil,
            process: { tap, requestedFrames, _, bufferListInOut, framesOut, flagsOut in
                var timeRange = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, requestedFrames, bufferListInOut, flagsOut, &timeRange, framesOut
                )
                guard status == noErr else {
                    framesOut.pointee = 0
                    return
                }
                let state = Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.process(
                    bufferList: bufferListInOut,
                    frameCount: Int(framesOut.pointee),
                    startSeconds: timeRange.start.isNumeric ? timeRange.start.seconds : nil
                )
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap
        )
        guard status == noErr, let tap else {
            Log.preview.error("clip audio mix tap creation failed status=\(status)")
            Unmanaged<TapState>.fromOpaque(clientInfo).release()
            return nil
        }
        return tap
    }
}

private final class TapState {
    private let gate = OSAllocatedUnfairLock()
    private let segments: [ClipAudioMixSegment]
    private var configurations: [ClipAudioProcessorConfiguration] = []
    private var processor = ClipAudioProcessorState()
    private var sampleRate: Double = 48_000
    private var channelCount = 0
    private var isInterleaved = false
    private var isFloat = false
    private var activeSegment: Int?
    private var cursorSeconds: Double = 0

    init(segments: [ClipAudioMixSegment]) {
        self.segments = segments
    }

    func prepare(format: AudioStreamBasicDescription) {
        gate.lock()
        defer { gate.unlock() }
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        channelCount = Int(format.mChannelsPerFrame)
        isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
        configurations = segments.map { ClipAudioProcessorConfiguration(mix: $0.mix, sampleRate: sampleRate) }
        processor.reset()
        activeSegment = nil
        cursorSeconds = 0
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int, startSeconds: Double?) {
        guard gate.lockIfAvailable() else { return }
        defer { gate.unlock() }
        guard isFloat, frameCount > 0, channelCount > 0, !configurations.isEmpty else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first?.mData else { return }
        let stride = isInterleaved ? channelCount : 1
        if !isInterleaved, buffers.count < channelCount { return }

        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: channelCount) { bases in
            if isInterleaved {
                let pointer = first.assumingMemoryBound(to: Float.self)
                for channel in 0..<channelCount { bases[channel] = pointer.advanced(by: channel) }
            } else {
                for channel in 0..<channelCount {
                    guard let data = buffers[channel].mData else { return }
                    bases[channel] = data.assumingMemoryBound(to: Float.self)
                }
            }
            withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: channelCount) { window in
                var frameOffset = 0
                var time = startSeconds ?? cursorSeconds
                while frameOffset < frameCount {
                    let (index, spanEnd) = segment(at: time)
                    let remaining = frameCount - frameOffset
                    let framesInSpan = spanEnd.isFinite
                        ? max(1, Int(((spanEnd - time) * sampleRate).rounded(.up)))
                        : remaining
                    let count = min(remaining, framesInSpan)
                    if index != activeSegment {
                        processor.reset()
                        activeSegment = index
                    }
                    if let index {
                        for channel in 0..<channelCount {
                            window[channel] = bases[channel].advanced(by: frameOffset * stride)
                        }
                        processor.process(
                            channels: window, stride: stride, frameCount: count, configuration: configurations[index]
                        )
                    }
                    frameOffset += count
                    time += Double(count) / sampleRate
                }
                cursorSeconds = time
            }
        }
    }

    private func segment(at time: Double) -> (index: Int?, spanEnd: Double) {
        for (index, segment) in segments.enumerated() {
            if time < segment.startSeconds { return (nil, segment.startSeconds) }
            if time < segment.endSeconds { return (index, segment.endSeconds) }
        }
        return (nil, .infinity)
    }
}
