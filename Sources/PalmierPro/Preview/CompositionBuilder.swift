import AVFoundation

struct TrackMapping: @unchecked Sendable {
    enum Kind {
        case timeline(trackIndex: Int, clipIds: Set<String>?)
        case nested(clips: [Clip], carrier: Clip, parentTrackIndex: Int)
        case blackBackground(range: CMTimeRange)
        /// Audio pulled past a cut so a video transition crossfades instead of hard-cutting.
        case transitionHandles(handles: [TransitionAudioHandle], trackIndex: Int)
    }
    let compositionTrack: AVMutableCompositionTrack
    let kind: Kind
    let naturalSize: CGSize   // zero for audio-only mappings
    let endTime: CMTime       // .zero for audio-only mappings
    let isVideo: Bool
    // Denoise blend: wet twin plays at strength volume, dry clip at 1-strength.
    var wetAudio = false
    var blendedClipIds: Set<String> = []
}

struct CompositionResult {
    let composition: AVMutableComposition
    let audioMix: AVMutableAudioMix
    let videoComposition: AVVideoComposition
    let trackMappings: [TrackMapping]
    let clipNaturalSizes: [String: CGSize]
    let clipTransforms: [String: CGAffineTransform]
    let offlineMediaRefs: Set<String>
    let unprocessableMediaRefs: Set<String>
    let mediaFingerprints: [String: String]
    let ducking: DuckingPlan
}

/// Builds an AVFoundation composition from a Timeline.
enum CompositionBuilder {

    struct InvalidTimelineError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Invalid timeline: \(reason)" }
    }

    static func build(
        timeline: Timeline,
        resolveURL: @escaping @Sendable (String) -> URL?,
        resolveVideoURL: @escaping @Sendable (String) -> URL? = { _ in nil },
        resolveSourceSize: @escaping @Sendable (String) -> CGSize? = { _ in nil },
        resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
        missingMediaRefs: Set<String> = [],
        renderSize: CGSize,
        makeAsset: @escaping @Sendable (URL) -> AVURLAsset = { AVURLAsset(url: $0) },
        loadTracks: @escaping @Sendable (AVURLAsset, AVMediaType) async throws -> [AVAssetTrack] = {
            try await $0.loadTracks(withMediaType: $1)
        }
    ) async throws -> CompositionResult {
        Log.preview.info("build fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height) tracks=\(timeline.tracks.count)")
        guard timeline.fps > 0, timeline.width > 0, timeline.height > 0 else {
            Log.preview.fault("build: invalid timeline fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
            throw InvalidTimelineError(reason: "fps=\(timeline.fps) size=\(timeline.width)x\(timeline.height)")
        }
        await MotionVideoGenerator.registerPendingBakes(
            timeline: timeline, resolveURL: resolveURL, resolveTimeline: resolveTimeline
        )
        let ctx = BuildContext(
            composition: AVMutableComposition(),
            timescale: CMTimeScale(timeline.fps),
            renderSize: renderSize,
            resolveURL: resolveURL,
            resolveVideoURL: resolveVideoURL,
            resolveSourceSize: resolveSourceSize,
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            makeAsset: makeAsset,
            loadTracks: loadTracks
        )

        let audioCrossfades = TransitionAudioExtension.crossfades(in: timeline)

        for (trackIdx, track) in timeline.tracks.enumerated() {
            // Text and adjustment layers are composited at render, not as tracks.
            let sortedClips = track.clips
                .sorted { $0.startFrame < $1.startFrame }
                .filter { !$0.mediaType.isSourcelessLayer }
            guard !sortedClips.isEmpty else { continue }
            if track.type == .audio {
                guard !track.muted else { continue }
                try await insertAudioLane(clips: sortedClips, parentTrackIndex: trackIdx, nest: nil, depth: 0, ctx: ctx)
                let handles = TransitionAudioExtension.handles(
                    forAudioTrackIndex: trackIdx, crossfades: audioCrossfades
                )
                if !handles.isEmpty {
                    try await insertAudioLane(
                        clips: handles.map(\.clip), parentTrackIndex: trackIdx, nest: nil, depth: 0,
                        ctx: ctx, transitionHandles: handles
                    )
                }
            } else {
                try await insertVideoLane(clips: sortedClips, parentTrackIndex: trackIdx, nestCarrier: nil, depth: 0, ctx: ctx)
                let handles = TransitionExtension.extensionClips(for: track)
                if !handles.isEmpty {
                    try await insertVideoLane(clips: handles, parentTrackIndex: trackIdx, nestCarrier: nil, depth: 0, ctx: ctx)
                }
            }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        // Opaque black background layer (bottommost) for full timeline
        let lastVideoEnd = ctx.trackMappings.filter(\.isVideo).map(\.endTime).max() ?? .zero
        let desiredDuration = max(CMTime(value: CMTimeValue(timeline.totalFrames), timescale: ctx.timescale), lastVideoEnd)
        if desiredDuration > .zero {
            if let mapping = try await insertBlackBackground(
                composition: ctx.composition,
                size: renderSize,
                range: CMTimeRange(start: .zero, duration: desiredDuration)
            ) {
                ctx.trackMappings.append(mapping)
            }
        }

        let ducking = await DuckingAnalyzer.cachedPlan(for: timeline, resolveURL: resolveURL)
        guard !Task.isCancelled else { throw CancellationError() }

        let (audioMix, videoComposition) = buildVisuals(
            timeline: timeline,
            trackMappings: ctx.trackMappings,
            clipNaturalSizes: ctx.clipNaturalSizes,
            clipTransforms: ctx.clipTransforms,
            resolveTimeline: resolveTimeline,
            compositionDuration: ctx.composition.duration,
            renderSize: renderSize,
            mediaFingerprints: ctx.mediaFingerprints,
            ducking: ducking
        )

        return CompositionResult(
            composition: ctx.composition,
            audioMix: audioMix,
            videoComposition: videoComposition,
            trackMappings: ctx.trackMappings,
            clipNaturalSizes: ctx.clipNaturalSizes,
            clipTransforms: ctx.clipTransforms,
            offlineMediaRefs: ctx.offlineMediaRefs,
            unprocessableMediaRefs: ctx.unprocessableMediaRefs,
            mediaFingerprints: ctx.mediaFingerprints,
            ducking: ducking
        )
    }

    /// Everything a build pass threads through insertion: inputs plus accumulators.
    private final class BuildContext {
        let composition: AVMutableComposition
        let timescale: CMTimeScale
        let renderSize: CGSize
        let resolveURL: @Sendable (String) -> URL?
        let resolveVideoURL: @Sendable (String) -> URL?
        let resolveSourceSize: @Sendable (String) -> CGSize?
        let resolveTimeline: @Sendable (String) -> Timeline?
        let missingMediaRefs: Set<String>
        let makeAsset: @Sendable (URL) -> AVURLAsset
        let loadTracks: @Sendable (AVURLAsset, AVMediaType) async throws -> [AVAssetTrack]
        var trackMappings: [TrackMapping] = []
        var clipNaturalSizes: [String: CGSize] = [:]
        var clipTransforms: [String: CGAffineTransform] = [:]
        var offlineMediaRefs: Set<String> = []
        var unprocessableMediaRefs: Set<String> = []
        var mediaFingerprints: [String: String] = [:]
        var sourceAssetsByURL: [URL: AVURLAsset] = [:]
        var trackLoadOutcomes: [TrackLoadKey: LoadOutcome] = [:]
        var videoURLsBySourceURL: [URL: URL] = [:]
        var loadOutcomesByMedia: [MediaLoadKey: LoadOutcome] = [:]

        init(
            composition: AVMutableComposition,
            timescale: CMTimeScale,
            renderSize: CGSize,
            resolveURL: @escaping @Sendable (String) -> URL?,
            resolveVideoURL: @escaping @Sendable (String) -> URL?,
            resolveSourceSize: @escaping @Sendable (String) -> CGSize?,
            resolveTimeline: @escaping @Sendable (String) -> Timeline?,
            missingMediaRefs: Set<String>,
            makeAsset: @escaping @Sendable (URL) -> AVURLAsset,
            loadTracks: @escaping @Sendable (AVURLAsset, AVMediaType) async throws -> [AVAssetTrack]
        ) {
            self.composition = composition
            self.timescale = timescale
            self.renderSize = renderSize
            self.resolveURL = resolveURL
            self.resolveVideoURL = resolveVideoURL
            self.resolveSourceSize = resolveSourceSize
            self.resolveTimeline = resolveTimeline
            self.missingMediaRefs = missingMediaRefs
            self.makeAsset = makeAsset
            self.loadTracks = loadTracks
        }

        private func sourceAsset(for url: URL) -> AVURLAsset {
            if let asset = sourceAssetsByURL[url] { return asset }
            let asset = makeAsset(url)
            sourceAssetsByURL[url] = asset
            return asset
        }

        func loadSource(for clip: Clip, mediaType: AVMediaType) async throws -> LoadOutcome {
            try Task.checkCancellation()
            let key = MediaLoadKey(mediaRef: clip.mediaRef, mediaType: mediaType)
            if let outcome = loadOutcomesByMedia[key] { return outcome }
            let outcome = try await prepareSource(for: clip, mediaType: mediaType)
            if case .loaded(let asset, _) = outcome, mediaType == .video,
               mediaFingerprints[clip.mediaRef] == nil {
                mediaFingerprints[clip.mediaRef] = await DiskCache.loadSizeMtimeTag(for: asset.url)
            }
            loadOutcomesByMedia[key] = outcome
            return outcome
        }

        private func prepareSource(for clip: Clip, mediaType: AVMediaType) async throws -> LoadOutcome {
            guard !missingMediaRefs.contains(clip.mediaRef) else { return .offline }
            guard let resolvedURL = resolveURL(clip.mediaRef) else { return .offline }

            let mediaURL: URL
            if clip.mediaType == .image {
                let imageSize = resolveSourceSize(clip.mediaRef)
                    ?? ImageVideoGenerator.imageNativeSize(url: resolvedURL)
                    ?? renderSize
                do {
                    mediaURL = try await ImageVideoGenerator.stillVideo(
                        for: resolvedURL,
                        mediaRef: clip.mediaRef,
                        size: imageSize
                    )
                } catch {
                    Log.preview.error("stillVideo failed mediaRef=\(clip.mediaRef) size=\(Int(imageSize.width))x\(Int(imageSize.height)): \(Log.detail(error))")
                    return FileManager.default.fileExists(atPath: resolvedURL.path) ? .unprocessable : .offline
                }
            } else if clip.mediaType == .lottie {
                let lottieSize = resolveSourceSize(clip.mediaRef) ?? renderSize
                do {
                    mediaURL = try await LottieVideoGenerator.lottieVideo(
                        for: resolvedURL,
                        mediaRef: clip.mediaRef,
                        size: lottieSize
                    )
                } catch {
                    Log.preview.error("lottieVideo failed mediaRef=\(clip.mediaRef) size=\(Int(lottieSize.width))x\(Int(lottieSize.height)): \(Log.detail(error))")
                    return FileManager.default.fileExists(atPath: resolvedURL.path) ? .unprocessable : .offline
                }
            } else if clip.mediaType == .motion || clip.sourceClipType == .motion {
                do {
                    mediaURL = try await MotionVideoGenerator.motionVideo(for: resolvedURL, mediaRef: clip.mediaRef)
                } catch {
                    Log.preview.error("motionVideo failed mediaRef=\(clip.mediaRef): \(Log.detail(error))")
                    return FileManager.default.fileExists(atPath: resolvedURL.path) ? .unprocessable : .offline
                }
            } else if mediaType == .video {
                let playbackURL = clip.mediaType == .video
                    ? (resolveVideoURL(clip.mediaRef) ?? resolvedURL)
                    : resolvedURL
                return try await loadVideo(at: playbackURL, clip: clip)
            } else if MonoStereoUpmixer.isNeeded(for: clip.audioMix) {
                do {
                    mediaURL = try await MonoStereoUpmixer.stereoAudio(for: resolvedURL, mediaRef: clip.mediaRef)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.preview.warning("mono upmix failed — pan stays centred. mediaRef=\(clip.mediaRef): \(Log.detail(error))")
                    mediaURL = resolvedURL
                }
            } else {
                mediaURL = resolvedURL
            }
            return try await loadTrack(at: mediaURL, mediaType: mediaType, clip: clip)
        }

        private func loadTrack(
            at url: URL,
            mediaType: AVMediaType,
            clip: Clip
        ) async throws -> LoadOutcome {
            try Task.checkCancellation()
            let key = TrackLoadKey(url: url, mediaType: mediaType)
            if let outcome = trackLoadOutcomes[key] { return outcome }
            let asset = sourceAsset(for: key.url)
            let outcome: LoadOutcome
            do {
                if let track = try await loadTracks(asset, mediaType).first {
                    outcome = .loaded(asset: asset, track: track)
                } else {
                    outcome = .offline
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.preview.warning(
                    "loadTracks failed — skipping clip. clipId=\(clip.id) mediaRef=\(clip.mediaRef): \(error.localizedDescription)"
                )
                return .offline
            }
            trackLoadOutcomes[key] = outcome
            return outcome
        }

        private func loadVideo(at url: URL, clip: Clip) async throws -> LoadOutcome {
            let sourceURL = url.standardizedFileURL
            let source = try await loadTrack(at: sourceURL, mediaType: .video, clip: clip)
            guard case .loaded(let asset, let track) = source else { return source }

            let videoURL: URL
            if let cachedURL = videoURLsBySourceURL[sourceURL] {
                videoURL = cachedURL
            } else {
                do {
                    let normalizedURL = try await AlphaVideoNormalizer.premultipliedVideo(
                        for: sourceURL,
                        mediaRef: clip.mediaRef,
                        asset: asset,
                        track: track
                    )
                    try Task.checkCancellation()
                    videoURL = (normalizedURL ?? sourceURL).standardizedFileURL
                    videoURLsBySourceURL[sourceURL] = videoURL
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.preview.warning(
                        "alpha premultiply unavailable mediaRef=\(clip.mediaRef): \(error.localizedDescription)"
                    )
                    return source
                }
            }
            guard videoURL != sourceURL else { return source }
            return try await loadTrack(at: videoURL, mediaType: .video, clip: clip)
        }
    }

    /// One lane of video clips → at most one composition track; sequence clips expand recursively.
    private static func insertVideoLane(
        clips: [Clip],
        parentTrackIndex: Int,
        nestCarrier: Clip?,
        depth: Int,
        ctx: BuildContext
    ) async throws {
        var compTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var inserted: [Clip] = []
        var previousEndFrame = Int.min
        for clip in clips {
            guard clip.durationFrames > 0, clip.startFrame >= previousEndFrame else { continue }
            if clip.mediaType.isSourcelessLayer { continue }   // rendered in instructions; nests render them in groups
            if clip.mediaType == .sequence {
                try await expandNestVideo(carrier: clip, parentTrackIndex: parentTrackIndex, depth: depth, ctx: ctx)
                previousEndFrame = clip.endFrame
                continue
            }
            let source: (asset: AVURLAsset, track: AVAssetTrack)
            switch try await ctx.loadSource(for: clip, mediaType: .video) {
            case .loaded(let asset, let track): source = (asset, track)
            case .offline: ctx.offlineMediaRefs.insert(clip.mediaRef); continue
            case .unprocessable: ctx.unprocessableMediaRefs.insert(clip.mediaRef); continue
            }
            if compTrack == nil {
                compTrack = ctx.composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track = compTrack else { continue }
            await recordSourceGeometry(for: clip, sourceTrack: source.track, ctx: ctx)
            if await insertClip(clip, sourceAsset: source.asset, sourceTrack: source.track,
                                into: track, cursor: &cursor, timescale: ctx.timescale) {
                inserted.append(clip)
                previousEndFrame = clip.endFrame
            }
        }
        guard let compTrack else { return }
        guard !inserted.isEmpty else {
            ctx.composition.removeTrack(compTrack)
            return
        }
        let naturalSize = (try? await compTrack.load(.naturalSize)).flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? ctx.renderSize
        let kind: TrackMapping.Kind = nestCarrier.map { .nested(clips: inserted, carrier: $0, parentTrackIndex: parentTrackIndex) }
            ?? .timeline(trackIndex: parentTrackIndex, clipIds: Set(inserted.map(\.id)))
        ctx.trackMappings.append(TrackMapping(
            compositionTrack: compTrack, kind: kind, naturalSize: naturalSize, endTime: cursor, isVideo: true
        ))
    }

    /// One lane of audio clips → at most one shared composition track (per-lane clips never overlap).
    private static func insertAudioLane(
        clips: [Clip],
        parentTrackIndex: Int,
        nest: (topCarrier: Clip, volumeScale: Double)?,
        depth: Int,
        ctx: BuildContext,
        transitionHandles: [TransitionAudioHandle]? = nil
    ) async throws {
        var compTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var inserted: [Clip] = []
        var blendedClipIds = Set<String>()
        var previousEndFrame = Int.min
        for var clip in clips {
            guard clip.durationFrames > 0, clip.startFrame >= previousEndFrame else { continue }
            previousEndFrame = clip.endFrame
            if clip.sourceClipType == .sequence {
                try await expandNestAudio(
                    carrier: clip,
                    topCarrier: nest?.topCarrier ?? clip,
                    volumeScale: nest.map { $0.volumeScale * clip.volume } ?? 1.0,
                    parentTrackIndex: parentTrackIndex, depth: depth, ctx: ctx
                )
                continue
            }
            if let nest { clip.volume *= nest.volumeScale }
            let source: (asset: AVURLAsset, track: AVAssetTrack)
            switch try await ctx.loadSource(for: clip, mediaType: .audio) {
            case .loaded(let asset, let track): source = (asset, track)
            case .offline: ctx.offlineMediaRefs.insert(clip.mediaRef); continue
            case .unprocessable: ctx.unprocessableMediaRefs.insert(clip.mediaRef); continue
            }
            if compTrack == nil {
                compTrack = ctx.composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track = compTrack else { continue }
            if await insertClip(clip, sourceAsset: source.asset, sourceTrack: source.track,
                                into: track, cursor: &cursor, timescale: ctx.timescale) {
                inserted.append(clip)
                if nest == nil, transitionHandles == nil,
                   await insertDenoisedTwin(clip, parentTrackIndex: parentTrackIndex, ctx: ctx) {
                    blendedClipIds.insert(clip.id)
                }
            }
        }
        guard let compTrack else { return }
        guard !inserted.isEmpty else {
            ctx.composition.removeTrack(compTrack)
            return
        }
        let kind: TrackMapping.Kind
        if let transitionHandles {
            let insertedIds = Set(inserted.map(\.id))
            kind = .transitionHandles(
                handles: transitionHandles.filter { insertedIds.contains($0.clip.id) },
                trackIndex: parentTrackIndex
            )
        } else if let nest {
            kind = .nested(clips: inserted, carrier: nest.topCarrier, parentTrackIndex: parentTrackIndex)
        } else {
            kind = .timeline(trackIndex: parentTrackIndex, clipIds: Set(inserted.map(\.id)))
        }
        ctx.trackMappings.append(TrackMapping(
            compositionTrack: compTrack, kind: kind, naturalSize: .zero, endTime: .zero, isVideo: false,
            blendedClipIds: blendedClipIds
        ))
    }

    private static func insertDenoisedTwin(_ clip: Clip, parentTrackIndex: Int, ctx: BuildContext) async -> Bool {
        guard let resolved = ctx.resolveURL(clip.mediaRef) else { return false }
        let cachedWetURL: URL?
        if clip.hasStudioVoiceEnabled {
            cachedWetURL = AudioEnhancer.cachedStudioURL(for: resolved, mediaRef: clip.mediaRef)
        } else if clip.hasDenoiseEnabled, clip.denoiseAmount > 0 {
            cachedWetURL = AudioEnhancer.cachedDenoisedURL(for: resolved, mediaRef: clip.mediaRef)
        } else {
            cachedWetURL = nil
        }
        guard let wetURL = cachedWetURL else { return false }
        let asset = AVURLAsset(url: wetURL)
        guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let compTrack = ctx.composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { return false }
        var cursor = CMTime.zero
        guard await insertClip(
            clip, sourceAsset: asset, sourceTrack: sourceTrack,
            into: compTrack, cursor: &cursor, timescale: ctx.timescale
        ) else {
            ctx.composition.removeTrack(compTrack)
            return false
        }
        ctx.trackMappings.append(TrackMapping(
            compositionTrack: compTrack,
            kind: .timeline(trackIndex: parentTrackIndex, clipIds: [clip.id]),
            naturalSize: .zero,
            endTime: .zero,
            isVideo: false,
            wetAudio: true
        ))
        return true
    }

    private static func recordSourceGeometry(for clip: Clip, sourceTrack: AVAssetTrack, ctx: BuildContext) async {
        guard let natSize = try? await sourceTrack.load(.naturalSize), natSize.width > 0, natSize.height > 0 else { return }
        // Store clip display size and transform with origin at (0,0)
        let pt = (try? await sourceTrack.load(.preferredTransform)) ?? .identity
        let box = CGRect(origin: .zero, size: natSize).applying(pt)
        ctx.clipNaturalSizes[clip.id] = CGSize(width: abs(box.width), height: abs(box.height))
        ctx.clipTransforms[clip.id] = pt.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    private enum LoadOutcome {
        case loaded(asset: AVURLAsset, track: AVAssetTrack)
        case offline
        case unprocessable
    }

    private struct MediaLoadKey: Hashable {
        let mediaRef: String
        let mediaType: AVMediaType
    }

    private struct TrackLoadKey: Hashable {
        let url: URL
        let mediaType: AVMediaType

        init(url: URL, mediaType: AVMediaType) {
            self.url = url.standardizedFileURL
            self.mediaType = mediaType
        }
    }

    private static func insertClip(
        _ clip: Clip,
        sourceAsset: AVURLAsset,
        sourceTrack: AVAssetTrack,
        into compTrack: AVMutableCompositionTrack,
        cursor: inout CMTime,
        timescale: CMTimeScale
    ) async -> Bool {
        let clipStart = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
        let trimStartFrame = clip.mediaType == .image ? max(0, clip.trimStartFrame) : clip.trimStartFrame
        let sourceTimescale = (try? await sourceTrack.load(.naturalTimeScale)) ?? timescale
        let startSeconds = Double(trimStartFrame) / Double(timescale)
        let trimStart = CMTime(seconds: startSeconds, preferredTimescale: sourceTimescale)
        let clipDuration = CMTime(value: CMTimeValue(clip.durationFrames), timescale: timescale)

        if clipStart > cursor {
            let gap = clipStart - cursor
            compTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: gap))
        }

        if let ramp = clip.speedRamp {
            let assetDuration = try? await sourceAsset.load(.duration)
            guard insertRampSegments(
                clip, ramp: ramp, sourceTrack: sourceTrack,
                assetDuration: assetDuration.flatMap { $0.isNumeric ? $0 : nil },
                into: compTrack, clipStart: clipStart,
                trimStart: trimStart, timescale: timescale, sourceTimescale: sourceTimescale
            ) else { return false }
            cursor = clipStart + clipDuration
            return true
        }

        let sourceFrames = clip.speed == 1.0
            ? clip.durationFrames
            : max(1, Int(Double(clip.durationFrames) * clip.speed))
        let durationSeconds = Double(sourceFrames) / Double(timescale)
        var sourceDuration = CMTime(seconds: durationSeconds, preferredTimescale: sourceTimescale)
        // Baked sources can be a hair shorter than the original; clamp instead of throwing.
        if let assetDuration = try? await sourceAsset.load(.duration), assetDuration.isNumeric {
            sourceDuration = CMTimeMinimum(sourceDuration, assetDuration - trimStart)
        }
        guard sourceDuration > .zero else { return false }
        let sourceRange = CMTimeRange(start: trimStart, duration: sourceDuration)

        do {
            try compTrack.insertTimeRange(sourceRange, of: sourceTrack, at: clipStart)
        } catch {
            let srcSeconds = (try? await sourceAsset.load(.duration).seconds) ?? 0
            Log.preview.error("""
                insertTimeRange failed — skipping clip. \
                clipId=\(clip.id) mediaRef=\(clip.mediaRef) \
                trimStart=\(clip.trimStartFrame)f durationFrames=\(clip.durationFrames)f \
                speed=\(clip.speed) sourceSeconds=\(String(format: "%.3f", srcSeconds)) \
                error=\(error.localizedDescription)
                """)
            return false
        }
        if clip.speed != 1.0 {
            compTrack.scaleTimeRange(CMTimeRange(start: clipStart, duration: sourceDuration), toDuration: clipDuration)
        }

        cursor = clipStart + clipDuration
        return true
    }

    private static func insertRampSegments(
        _ clip: Clip,
        ramp: SpeedRamp,
        sourceTrack: AVAssetTrack,
        assetDuration: CMTime?,
        into compTrack: AVMutableCompositionTrack,
        clipStart: CMTime,
        trimStart: CMTime,
        timescale: CMTimeScale,
        sourceTimescale: CMTimeScale
    ) -> Bool {
        var insertedTimelineFrames = 0
        for segment in ramp.segments {
            let segmentStart = clipStart + CMTime(value: CMTimeValue(segment.clipFrame), timescale: timescale)
            let segmentDuration = CMTime(value: CMTimeValue(segment.timelineFrames), timescale: timescale)
            let sourceStart = trimStart + CMTime(
                seconds: segment.sourceOffset / Double(timescale), preferredTimescale: sourceTimescale
            )
            var sourceDuration = CMTime(
                seconds: segment.sourceFrames / Double(timescale), preferredTimescale: sourceTimescale
            )
            if let assetDuration {
                sourceDuration = CMTimeMinimum(sourceDuration, assetDuration - sourceStart)
            }
            guard sourceDuration > .zero else { break }
            do {
                try compTrack.insertTimeRange(
                    CMTimeRange(start: sourceStart, duration: sourceDuration), of: sourceTrack, at: segmentStart
                )
            } catch {
                Log.preview.error("""
                    ramp insertTimeRange failed — skipping clip. \
                    clipId=\(clip.id) mediaRef=\(clip.mediaRef) \
                    segmentFrame=\(segment.clipFrame) segmentFrames=\(segment.timelineFrames) \
                    error=\(error.localizedDescription)
                    """)
                if insertedTimelineFrames > 0 {
                    compTrack.removeTimeRange(CMTimeRange(
                        start: clipStart,
                        duration: CMTime(value: CMTimeValue(insertedTimelineFrames), timescale: timescale)
                    ))
                }
                return false
            }
            compTrack.scaleTimeRange(
                CMTimeRange(start: segmentStart, duration: sourceDuration), toDuration: segmentDuration
            )
            insertedTimelineFrames = segment.clipEndFrame
        }
        guard insertedTimelineFrames > 0 else { return false }
        if insertedTimelineFrames < ramp.durationFrames {
            let holdStart = clipStart + CMTime(value: CMTimeValue(insertedTimelineFrames), timescale: timescale)
            let holdFrames = ramp.durationFrames - insertedTimelineFrames
            compTrack.insertEmptyTimeRange(CMTimeRange(
                start: holdStart, duration: CMTime(value: CMTimeValue(holdFrames), timescale: timescale)
            ))
            Log.preview.warning("""
                speed ramp exhausted source before the clip ended. \
                clipId=\(clip.id) mediaRef=\(clip.mediaRef) missingFrames=\(holdFrames)
                """)
        }
        return true
    }

    private static func insertBlackBackground(
        composition: AVMutableComposition,
        size: CGSize,
        range: CMTimeRange
    ) async throws -> TrackMapping? {
        let blackURL = try await ImageVideoGenerator.blackVideo(size: size)
        let asset = AVURLAsset(url: blackURL)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: range.duration),
            of: sourceTrack,
            at: range.start
        )
        return TrackMapping(
            compositionTrack: compTrack,
            kind: .blackBackground(range: range),
            naturalSize: size,
            endTime: range.end,
            isVideo: true
        )
    }

    private static func expandNestVideo(carrier: Clip, parentTrackIndex: Int, depth: Int, ctx: BuildContext) async throws {
        guard depth < NestFlattener.maxDepth else {
            Log.preview.warning("nest depth limit reached; skipping \(carrier.mediaRef.prefix(8))")
            return
        }
        guard let child = ctx.resolveTimeline(carrier.mediaRef) else {
            ctx.offlineMediaRefs.insert(carrier.mediaRef)
            return
        }
        let flat = NestFlattener.flatten(carrier: carrier, child: child, visual: true)
        for childTrack in flat.videoTracks {
            try await insertVideoLane(clips: childTrack.clips, parentTrackIndex: parentTrackIndex,
                                      nestCarrier: carrier, depth: depth + 1, ctx: ctx)
            let handles = TransitionExtension.extensionClips(for: childTrack)
            if !handles.isEmpty {
                try await insertVideoLane(clips: handles, parentTrackIndex: parentTrackIndex,
                                          nestCarrier: carrier, depth: depth + 1, ctx: ctx)
            }
        }
    }

    /// Static volumes fold down the chain; the top carrier's envelope multiplies at mix time.
    private static func expandNestAudio(
        carrier: Clip, topCarrier: Clip, volumeScale: Double,
        parentTrackIndex: Int, depth: Int, ctx: BuildContext
    ) async throws {
        guard depth < NestFlattener.maxDepth else {
            Log.preview.warning("nest depth limit reached; skipping \(carrier.mediaRef.prefix(8))")
            return
        }
        guard let child = ctx.resolveTimeline(carrier.mediaRef) else {
            ctx.offlineMediaRefs.insert(carrier.mediaRef)
            return
        }
        let flat = NestFlattener.flatten(carrier: carrier, child: child, visual: false)
        for trackClips in flat.audioTracks {
            try await insertAudioLane(clips: trackClips, parentTrackIndex: parentTrackIndex,
                                      nest: (topCarrier, volumeScale), depth: depth + 1, ctx: ctx)
        }
    }

    /// Rebuild only visual properties (transforms, opacity, volume)
    static func buildVisuals(
        timeline: Timeline,
        trackMappings: [TrackMapping],
        clipNaturalSizes: [String: CGSize] = [:],
        clipTransforms: [String: CGAffineTransform] = [:],
        resolveTimeline: @Sendable (String) -> Timeline? = { _ in nil },
        compositionDuration: CMTime,
        renderSize: CGSize,
        mediaFingerprints: [String: String] = [:],
        ducking: DuckingPlan = .empty
    ) -> (audioMix: AVMutableAudioMix, videoComposition: AVVideoComposition) {
        let timescale = CMTimeScale(timeline.fps)

        let crossfades = TransitionAudioExtension.crossfades(in: timeline)
        let crossfadesById = Dictionary(crossfades.map { ($0.transitionId, $0) }, uniquingKeysWith: { a, _ in a })
        var crossfadeCurvesByClipId: [String: [TransitionGainCurve]] = [:]
        for crossfade in crossfades {
            crossfadeCurvesByClipId[crossfade.outgoing.id, default: []]
                .append(TransitionGainCurve(window: crossfade.window, role: .outgoing))
            crossfadeCurvesByClipId[crossfade.incoming.id, default: []]
                .append(TransitionGainCurve(window: crossfade.window, role: .incoming))
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = trackMappings.filter { !$0.isVideo }.compactMap { mapping in
            switch mapping.kind {
            case .blackBackground:
                return nil
            case .transitionHandles(let handles, let trackIndex):
                guard timeline.tracks.indices.contains(trackIndex) else { return nil }
                let params = AVMutableAudioMixInputParameters(track: mapping.compositionTrack)
                if timeline.tracks[trackIndex].muted {
                    params.setVolume(0, at: .zero)
                    return params
                }
                var tappedClips: [Clip] = []
                for handle in handles {
                    // A handle whose transition changed shape since the build is no longer its lane.
                    guard let crossfade = crossfadesById[handle.transitionId], crossfade.window == handle.window else {
                        silence(params: params, clip: handle.clip, timescale: timescale)
                        continue
                    }
                    let sourceId = handle.role == .outgoing ? crossfade.outgoing.id : crossfade.incoming.id
                    emitVolumeEnvelope(
                        params: params, clip: handle.clip, timescale: timescale,
                        crossfades: [TransitionGainCurve(window: handle.window, role: handle.role)],
                        duck: ducking.curve(forClipId: sourceId)
                    )
                    tappedClips.append(handle.clip)
                }
                attachClipAudioMixTap(to: params, clips: tappedClips, fps: timeline.fps)
                return params
            case .nested(let clips, let carrier, let parentTrackIndex):
                let params = AVMutableAudioMixInputParameters(track: mapping.compositionTrack)
                guard timeline.tracks.indices.contains(parentTrackIndex) else { return params }
                let parentTrack = timeline.tracks[parentTrackIndex]
                if parentTrack.muted {
                    params.setVolume(0, at: .zero)
                    return params
                }
                // Prefer the live carrier so nest volume/fade edits apply on refresh.
                let liveCarrier = parentTrack.clips.first { $0.id == carrier.id } ?? carrier
                for clip in clips {
                    emitVolumeEnvelope(params: params, clip: clip, timescale: timescale, carrier: liveCarrier)
                }
                attachClipAudioMixTap(to: params, clips: clips, fps: timeline.fps)
                return params
            case .timeline(let trackIndex, let clipIds):
                guard timeline.tracks.indices.contains(trackIndex) else { return nil }
                let track = timeline.tracks[trackIndex]
                let params = AVMutableAudioMixInputParameters(track: mapping.compositionTrack)
                if track.muted {
                    params.setVolume(0, at: .zero)
                    return params
                }
                var prevEndFrame = Int.min
                var tappedClips: [Clip] = []
                for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) {
                    if let clipIds, !clipIds.contains(clip.id) { continue }
                    guard clip.durationFrames > 0, clip.startFrame >= prevEndFrame else { continue }
                    let strength: Float = clip.hasStudioVoiceEnabled
                        ? 1
                        : (clip.hasDenoiseEnabled ? Float(min(1, max(0, clip.denoiseAmount))) : 0)
                    let gain: Float = mapping.wetAudio
                        ? strength
                        : (mapping.blendedClipIds.contains(clip.id) ? 1 - strength : 1)
                    emitVolumeEnvelope(
                        params: params, clip: clip, timescale: timescale, gain: gain,
                        crossfades: crossfadeCurvesByClipId[clip.id] ?? [],
                        duck: ducking.curve(forClipId: clip.id)
                    )
                    tappedClips.append(clip)
                    prevEndFrame = clip.startFrame + clip.durationFrames
                }
                attachClipAudioMixTap(to: params, clips: tappedClips, fps: timeline.fps)
                return params
            }
        }

        var vcConfig = AVVideoComposition.Configuration()
        vcConfig.renderSize = renderSize
        vcConfig.frameDuration = CMTime(value: 1, timescale: timescale)

        vcConfig.customVideoCompositorClass = CustomVideoCompositor.self
        vcConfig.instructions = compositorInstructions(
            timeline: timeline,
            trackMappings: trackMappings,
            clipNaturalSizes: clipNaturalSizes,
            clipTransforms: clipTransforms,
            resolveTimeline: resolveTimeline,
            compositionDuration: compositionDuration,
            renderSize: renderSize,
            mediaFingerprints: mediaFingerprints
        )
        return (audioMix, AVVideoComposition(configuration: vcConfig))
    }

    /// One instruction per segment between clip boundaries, layers bottom → top.
    private static func compositorInstructions(
        timeline: Timeline,
        trackMappings: [TrackMapping],
        clipNaturalSizes: [String: CGSize],
        clipTransforms: [String: CGAffineTransform],
        resolveTimeline: @Sendable (String) -> Timeline? = { _ in nil },
        compositionDuration: CMTime,
        renderSize: CGSize,
        mediaFingerprints: [String: String]
    ) -> [CompositorInstruction] {
        let timescale = CMTimeScale(timeline.fps)
        func cmTime(_ frame: Int) -> CMTime { CMTime(value: CMTimeValue(frame), timescale: timescale) }
        struct Slot { let trackID: CMPersistentTrackID; let natSize: CGSize; let transform: CGAffineTransform }
        struct Entry { let start: CMTime; let end: CMTime; let plan: LayerPlan }

        // Resolve each inserted media clip to the composition track it lives on.
        var media: [String: Slot] = [:]
        for mapping in trackMappings where mapping.isVideo {
            let ids: Set<String>
            switch mapping.kind {
            case .timeline(let trackIndex, let clipIds):
                guard timeline.tracks.indices.contains(trackIndex) else { continue }
                ids = clipIds ?? Set(timeline.tracks[trackIndex].clips.filter { !$0.mediaType.isSourcelessLayer }.map(\.id))
            case .nested(let clips, _, _):
                ids = Set(clips.map(\.id))
            case .blackBackground, .transitionHandles:
                continue
            }
            for id in ids {
                media[id] = Slot(
                    trackID: mapping.compositionTrack.trackID,
                    natSize: clipNaturalSizes[id] ?? mapping.naturalSize,
                    transform: clipTransforms[id] ?? .identity
                )
            }
        }

        // Flatten is pure per carrier — memoize; segments reuse one result.
        var flattenCache: [String: NestFlattener.Flattened] = [:]
        func flattened(for carrier: Clip, depth: Int) -> NestFlattener.Flattened? {
            guard depth < NestFlattener.maxDepth else { return nil }
            if let cached = flattenCache[carrier.id] { return cached }
            guard let child = resolveTimeline(carrier.mediaRef) else { return nil }
            let flat = NestFlattener.flatten(carrier: carrier, child: child, visual: true)
            flattenCache[carrier.id] = flat
            return flat
        }

        // Resolving a track's transitions rescans its clips; nest groups ask per segment window.
        var resolvedTransitionCache: [String: [ResolvedTransition]] = [:]
        func resolvedTransitions(of track: Track) -> [ResolvedTransition] {
            if let cached = resolvedTransitionCache[track.id] { return cached }
            let resolved = track.resolvedTransitions
            resolvedTransitionCache[track.id] = resolved
            return resolved
        }

        func mediaLayer(_ slot: Slot, _ clip: Clip) -> LayerPlan {
            LayerPlan(
                source: .track(slot.trackID), clip: clip, natSize: slot.natSize,
                preferredTransform: slot.transform, mediaTag: mediaFingerprints[clip.mediaRef]
            )
        }

        func transitionEntries(_ resolved: ResolvedTransition) -> [Entry] {
            guard let fromSlot = media[resolved.from.id], let toSlot = media[resolved.to.id] else { return [] }
            let plan = TransitionPlan(
                style: resolved.transition.style,
                direction: resolved.transition.direction,
                window: resolved.window
            )
            // The outgoing clip carries the blend's pipeline, extended to the window so a nest
            // group — which gates its children by clip range — keeps the layer live past the cut.
            var carrier = TransitionExtension.renderClip(resolved.from)
            carrier.durationFrames = max(carrier.durationFrames, resolved.window.endFrame - carrier.startFrame)
            var out: [Entry] = []
            if resolved.window.headFrames > 0,
               let headSlot = media[TransitionExtension.headClipId(resolved.id)] {
                let source = LayerPlan.Source.transition(
                    from: mediaLayer(fromSlot, resolved.from),
                    to: mediaLayer(headSlot, TransitionExtension.renderClip(resolved.to)),
                    plan: plan
                )
                out.append(Entry(
                    start: cmTime(resolved.window.startFrame), end: cmTime(resolved.window.cutFrame),
                    plan: LayerPlan(source: source, clip: carrier, natSize: fromSlot.natSize, preferredTransform: .identity)
                ))
            }
            if resolved.window.tailFrames > 0,
               let tailSlot = media[TransitionExtension.tailClipId(resolved.id)] {
                let source = LayerPlan.Source.transition(
                    from: mediaLayer(tailSlot, TransitionExtension.renderClip(resolved.from)),
                    to: mediaLayer(toSlot, resolved.to),
                    plan: plan
                )
                out.append(Entry(
                    start: cmTime(resolved.window.cutFrame), end: cmTime(resolved.window.endFrame),
                    plan: LayerPlan(source: source, clip: carrier, natSize: fromSlot.natSize, preferredTransform: .identity)
                ))
            }
            return out
        }

        // One lane's layers, bottom→top: text, nested groups, media, and transition windows.
        // Top-level tracks and nest groups share it so both surfaces layer a cut the same way.
        func laneEntries(
            track: Track,
            textNatSize: CGSize,
            sequenceEntries: (Clip) -> [Entry]
        ) -> [Entry] {
            var out: [Entry] = []
            var prevEndFrame = Int.min
            var incoming: [String: ResolvedTransition] = [:]
            var outgoing: [String: ResolvedTransition] = [:]
            for resolved in resolvedTransitions(of: track) {
                let hasHead = resolved.window.headFrames == 0
                    || media[TransitionExtension.headClipId(resolved.id)] != nil
                let hasTail = resolved.window.tailFrames == 0
                    || media[TransitionExtension.tailClipId(resolved.id)] != nil
                guard hasHead, hasTail, media[resolved.from.id] != nil, media[resolved.to.id] != nil else { continue }
                incoming[resolved.to.id] = resolved
                outgoing[resolved.from.id] = resolved
            }
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) where clip.durationFrames > 0 {
                if clip.mediaType == .text {
                    guard !(clip.textContent ?? "").isEmpty else { continue }
                    out.append(Entry(
                        start: cmTime(clip.startFrame), end: cmTime(clip.endFrame),
                        plan: LayerPlan(source: .text, clip: clip, natSize: textNatSize, preferredTransform: .identity)
                    ))
                } else if clip.mediaType == .adjustment {
                    out.append(Entry(
                        start: cmTime(clip.startFrame), end: cmTime(clip.endFrame),
                        plan: LayerPlan(source: .adjustment, clip: clip, natSize: textNatSize, preferredTransform: .identity)
                    ))
                } else if clip.mediaType == .sequence {
                    guard clip.startFrame >= prevEndFrame else { continue }
                    prevEndFrame = clip.endFrame
                    out.append(contentsOf: sequenceEntries(clip))
                } else {
                    guard clip.startFrame >= prevEndFrame, let slot = media[clip.id] else { continue }
                    prevEndFrame = clip.endFrame
                    let visibleStart = incoming[clip.id].map { max(clip.startFrame, $0.window.endFrame) } ?? clip.startFrame
                    let visibleEnd = outgoing[clip.id].map { min(clip.endFrame, $0.window.startFrame) } ?? clip.endFrame
                    if visibleEnd > visibleStart {
                        out.append(Entry(
                            start: cmTime(visibleStart), end: cmTime(visibleEnd), plan: mediaLayer(slot, clip)
                        ))
                    }
                    if let resolved = outgoing[clip.id] {
                        out.append(contentsOf: transitionEntries(resolved))
                    }
                }
            }
            return out
        }

        // Group layer for one segment window; empty children still render (nest gaps are opaque black).
        func nestGroupPlan(carrier: Clip, depth: Int, window: Range<Int>) -> LayerPlan? {
            guard let flat = flattened(for: carrier, depth: depth) else { return nil }
            let windowStart = cmTime(window.lowerBound)
            let windowEnd = cmTime(window.upperBound)
            var children: [LayerPlan] = []
            for childTrack in flat.videoTracks.reversed() {
                let entries = laneEntries(track: childTrack, textNatSize: flat.childCanvas) { child in
                    guard child.startFrame < window.upperBound, child.endFrame > window.lowerBound else { return [] }
                    return nestGroupPlan(carrier: child, depth: depth + 1, window: window).map {
                        [Entry(start: cmTime(child.startFrame), end: cmTime(child.endFrame), plan: $0)]
                    } ?? []
                }
                for entry in entries where entry.start < windowEnd && entry.end > windowStart {
                    children.append(entry.plan)
                }
            }
            return LayerPlan(source: .group(children: children, canvas: flat.childCanvas),
                             clip: carrier, natSize: flat.childCanvas, preferredTransform: .identity)
        }

        // Child clip and transition boundaries: segments scope decoder demand to what's visible.
        func nestCutFrames(carrier: Clip, depth: Int) -> [Int] {
            guard let flat = flattened(for: carrier, depth: depth) else { return [] }
            var frames: [Int] = []
            for childTrack in flat.videoTracks {
                for clip in childTrack.clips {
                    frames.append(clip.startFrame)
                    frames.append(clip.endFrame)
                    if clip.mediaType == .sequence {
                        frames.append(contentsOf: nestCutFrames(carrier: clip, depth: depth + 1))
                    }
                }
                for resolved in resolvedTransitions(of: childTrack) {
                    frames.append(resolved.window.startFrame)
                    frames.append(resolved.window.endFrame)
                }
            }
            return frames.filter { $0 > carrier.startFrame && $0 < carrier.endFrame }
        }

        // Walk tracks in reverse to produce bottom→top entries. Text layers follow track order.
        var entries: [Entry] = []
        for track in timeline.tracks.reversed() where !track.hidden {
            entries.append(contentsOf: laneEntries(track: track, textNatSize: renderSize) { carrier in
                // One entry per child-boundary segment: each requires only the
                // source tracks visible in that segment.
                let bounds = ([carrier.startFrame, carrier.endFrame] + nestCutFrames(carrier: carrier, depth: 0))
                    .reduce(into: Set<Int>()) { $0.insert($1) }
                    .sorted()
                var out: [Entry] = []
                for i in 0..<(bounds.count - 1) {
                    let window = bounds[i]..<bounds[i + 1]
                    guard window.count > 0,
                          let group = nestGroupPlan(carrier: carrier, depth: 0, window: window) else { continue }
                    out.append(Entry(start: cmTime(window.lowerBound), end: cmTime(window.upperBound), plan: group))
                }
                return out
            })
        }

        var cutSet = Set<CMTime>()
        for e in entries {
            cutSet.insert(e.start)
            cutSet.insert(e.end)
        }
        let cuts = cutSet.filter { $0 > .zero && $0 < compositionDuration }.sorted()
        let bounds = [.zero] + cuts + [compositionDuration]

        var startsByTime: [CMTime: [Int]] = [:]
        var endsByTime: [CMTime: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            startsByTime[entry.start, default: []].append(index)
            endsByTime[entry.end, default: []].append(index)
        }

        var active: [Int] = []
        var activeSet = Set<Int>()

        func insertActive(_ index: Int) {
            guard activeSet.insert(index).inserted else { return }
            var low = 0
            var high = active.count
            while low < high {
                let mid = (low + high) / 2
                if active[mid] < index {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            active.insert(index, at: low)
        }

        func removeActive(_ index: Int) {
            guard activeSet.remove(index) != nil else { return }
            var low = 0
            var high = active.count
            while low < high {
                let mid = (low + high) / 2
                if active[mid] < index {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low < active.count, active[low] == index {
                active.remove(at: low)
            }
        }

        for (index, entry) in entries.enumerated() where entry.start < .zero && entry.end > .zero {
            insertActive(index)
        }

        var instructions: [CompositorInstruction] = []
        instructions.reserveCapacity(max(0, bounds.count - 1))
        for i in 0..<(bounds.count - 1) {
            let start = bounds[i]
            for index in endsByTime[start] ?? [] { removeActive(index) }
            for index in startsByTime[start] ?? [] { insertActive(index) }

            let range = CMTimeRange(start: bounds[i], end: bounds[i + 1])
            guard range.duration > .zero else { continue }
            let layers = active.map { entries[$0].plan }
            instructions.append(CompositorInstruction(
                timeRange: range, layers: layers, renderSize: renderSize, fps: timeline.fps
            ))
        }
        return instructions
    }

    /// Smooth-curve subdivision count for non-linear keyframe segments.
    static let smoothSegments = 8

    /// Interior subdivision offsets for a smooth ramp between two frames (excluding endpoints).
    static func smoothSubdivisions(from a: Int, to b: Int) -> [Int] {
        guard b > a else { return [] }
        let span = Double(b - a)
        let raw = (1..<smoothSegments).map { a + Int((span * Double($0) / Double(smoothSegments)).rounded()) }
        return Array(Set(raw)).sorted()
    }

    private static func attachClipAudioMixTap(
        to params: AVMutableAudioMixInputParameters, clips: [Clip], fps: Int
    ) {
        applyPitchAlgorithm(to: params, clips: clips)
        let segments = ClipAudioMixTap.segments(for: clips, fps: fps)
        guard !segments.isEmpty, let tap = ClipAudioMixTap.make(segments: segments) else { return }
        params.audioTapProcessor = tap
    }

    /// Flat 0 across a lane clip's span, for a handle lane whose transition no longer applies.
    private static func silence(
        params: AVMutableAudioMixInputParameters, clip: Clip, timescale: CMTimeScale
    ) {
        let start = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
        let end = CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale)
        guard end > start else { return }
        params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 0, timeRange: CMTimeRange(start: start, end: end))
    }

    private static func applyPitchAlgorithm(to params: AVMutableAudioMixInputParameters, clips: [Clip]) {
        guard clips.contains(where: \.hasSpeedRamp) else { return }
        params.audioTimePitchAlgorithm = .spectral
    }

    private static func emitVolumeEnvelope(
        params: AVMutableAudioMixInputParameters,
        clip: Clip,
        timescale: CMTimeScale,
        carrier: Clip? = nil,
        gain: Float = 1,
        crossfades: [TransitionGainCurve] = [],
        duck: DuckingCurve? = nil
    ) {
        let kfs = normalizedKeyframes(clip.volumeTrack?.keyframes ?? [], duration: clip.durationFrames)
        let hasFade = clip.fadeInFrames > 0 || clip.fadeOutFrames > 0
        let carrierVaries = carrier.map {
            ($0.volumeTrack?.isActive ?? false) || $0.fadeInFrames > 0 || $0.fadeOutFrames > 0
        } ?? false
        let crossfadeGainAt: (Int) -> Double = { absFrame in
            crossfades.reduce(1) { $0 * $1.gain(atFrame: absFrame) }
        }
        let gainAt: (Int) -> Double = { absFrame in
            (carrier.map { $0.volumeAt(frame: absFrame) } ?? 1)
                * crossfadeGainAt(absFrame)
                * (duck?.gain(atFrame: absFrame) ?? 1)
        }
        if kfs.isEmpty && !hasFade && !carrierVaries && crossfades.isEmpty && duck == nil {
            let volume = Float(clip.volumeAt(frame: clip.startFrame) * gainAt(clip.startFrame)) * gain
            let start = CMTime(value: CMTimeValue(clip.startFrame), timescale: timescale)
            let end = CMTime(value: CMTimeValue(clip.endFrame), timescale: timescale)
            guard volume.isFinite, end > start else { return }
            params.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: volume,
                timeRange: CMTimeRange(start: start, end: end)
            )
            return
        }

        var extraOffsets: [Int] = []
        if let carrier, carrierVaries {
            let toClipOffset: (Int) -> Int = { carrierOffset in
                carrier.startFrame + carrierOffset - clip.startFrame
            }
            if carrier.fadeInFrames > 0 {
                extraOffsets.append(toClipOffset(carrier.fadeInFrames))
                if carrier.fadeInInterpolation != .linear {
                    extraOffsets += smoothSubdivisions(from: 0, to: carrier.fadeInFrames).map(toClipOffset)
                }
            }
            if carrier.fadeOutFrames > 0 {
                let fadeStart = carrier.durationFrames - carrier.fadeOutFrames
                extraOffsets.append(toClipOffset(fadeStart))
                if carrier.fadeOutInterpolation != .linear {
                    extraOffsets += smoothSubdivisions(from: fadeStart, to: carrier.durationFrames).map(toClipOffset)
                }
            }
            for kf in carrier.volumeTrack?.keyframes ?? [] {
                extraOffsets.append(toClipOffset(kf.frame))
            }
            for (a, b) in zip(carrier.volumeTrack?.keyframes ?? [], carrier.volumeTrack?.keyframes.dropFirst() ?? [])
            where a.interpolationOut == .hold {
                extraOffsets.append(toClipOffset(b.frame) - 1)
            }
            extraOffsets = extraOffsets.filter { $0 > 0 && $0 < clip.durationFrames }
        }
        for curve in crossfades {
            extraOffsets += curve.breakpointFrames
                .map { $0 - clip.startFrame }
                .filter { $0 > 0 && $0 < clip.durationFrames }
        }
        if let duck {
            extraOffsets += duck.breakpointFrames
                .map { $0 - clip.startFrame }
                .filter { $0 > 0 && $0 < clip.durationFrames }
        }

        emitEnvelopeRamps(
            clip: clip,
            kfs: kfs,
            timescale: timescale,
            extraOffsets: extraOffsets,
            sampleAt: { Float(clip.volumeAt(frame: clip.startFrame + $0) * gainAt(clip.startFrame + $0)) * gain },
            emit: { start, end, range in
                params.setVolumeRamp(fromStartVolume: start, toEndVolume: end, timeRange: range)
            }
        )
    }

    /// Piecewise-linear envelope for the audio volume curve.
    private static func emitEnvelopeRamps(
        clip: Clip,
        kfs: [Keyframe<Double>],
        timescale: CMTimeScale,
        extraOffsets: [Int] = [],
        sampleAt: (Int) -> Float,
        emit: (Float, Float, CMTimeRange) -> Void
    ) {
        let dur = clip.durationFrames
        guard dur > 0 else { return }
        let kfs = normalizedKeyframes(kfs, duration: dur)

        var offsetSet: Set<Int> = [0, dur]
        offsetSet.formUnion(extraOffsets)
        for kf in kfs { offsetSet.insert(kf.frame) }
        for i in kfs.indices.dropLast() {
            let a = kfs[i], b = kfs[i + 1]
            switch a.interpolationOut {
            case .linear: break
            case .hold:   if b.frame - a.frame > 1 { offsetSet.insert(b.frame - 1) }
            default:      offsetSet.formUnion(smoothSubdivisions(from: a.frame, to: b.frame))
            }
        }
        if clip.fadeInFrames > 0 {
            let endOffset = min(dur, clip.fadeInFrames)
            offsetSet.insert(endOffset)
            if clip.fadeInInterpolation != .linear {
                offsetSet.formUnion(smoothSubdivisions(from: 0, to: endOffset))
            }
        }
        if clip.fadeOutFrames > 0 {
            let startOffset = max(0, dur - clip.fadeOutFrames)
            offsetSet.insert(startOffset)
            if clip.fadeOutInterpolation != .linear {
                offsetSet.formUnion(smoothSubdivisions(from: startOffset, to: dur))
            }
        }

        let offsets = offsetSet.sorted()
        for i in offsets.indices.dropLast() {
            let aOff = offsets[i], bOff = offsets[i + 1]
            guard bOff > aOff else { continue }
            let aT = CMTime(value: CMTimeValue(clip.startFrame + aOff), timescale: timescale)
            let bT = CMTime(value: CMTimeValue(clip.startFrame + bOff), timescale: timescale)
            guard bT > aT else { continue }
            emit(sampleAt(aOff), sampleAt(bOff), CMTimeRange(start: aT, end: bT))
        }
    }

    private static func normalizedKeyframes<V: Codable & Sendable & Equatable>(
        _ keyframes: [Keyframe<V>],
        duration: Int
    ) -> [Keyframe<V>] {
        var keyed: [Int: Keyframe<V>] = [:]
        for kf in keyframes where kf.frame >= 0 && kf.frame <= duration {
            keyed[kf.frame] = kf
        }
        return keyed.values.sorted { $0.frame < $1.frame }
    }

    /// Maps a clip's Transform (in normalized 0–1 canvas coordinates) to the
    /// CGAffineTransform an AVFoundation layer instruction expects.
    static func affineTransform(for t: Transform, natSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        let tl = t.topLeft
        let sx = (renderSize.width / natSize.width) * t.width * (t.flipHorizontal ? -1 : 1)
        let sy = (renderSize.height / natSize.height) * t.height * (t.flipVertical ? -1 : 1)
        let tx = (t.flipHorizontal ? tl.x + t.width : tl.x) * renderSize.width
        let ty = (t.flipVertical ? tl.y + t.height : tl.y) * renderSize.height
        let placed = CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return placed.concatenating(canvasRotationTransform(for: t, renderSize: renderSize))
    }

    static func canvasRotationTransform(for t: Transform, renderSize: CGSize) -> CGAffineTransform {
        guard t.rotation != 0 else { return .identity }
        let cx = t.centerX * renderSize.width
        let cy = t.centerY * renderSize.height
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: t.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
    }

}
