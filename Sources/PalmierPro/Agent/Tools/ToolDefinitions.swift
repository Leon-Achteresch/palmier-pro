import Foundation
import MCP

enum ToolName: String, CaseIterable, Sendable {
    // Projects
    case manageProject = "manage_project"

    // Timelines
    case getTimeline = "get_timeline"
    case inspectTimeline = "inspect_timeline"
    case createTimeline = "create_timeline"
    case setActiveTimeline = "set_active_timeline"
    case setProjectSettings = "set_project_settings"
    case exportProject = "export_project"
    case manageExports = "manage_exports"

    // Media library
    case getMedia = "get_media"
    case inspectMedia = "inspect_media"
    case searchMedia = "search_media"
    case searchStockMedia = "search_stock_media"
    case importMedia = "import_media"
    case captureFrame = "capture_frame"
    case organizeMedia = "organize_media"

    // Clips
    case manageTracks = "manage_tracks"
    case addClips = "add_clips"
    case insertClips = "insert_clips"
    case moveClips = "move_clips"
    case removeClips = "remove_clips"
    case splitClips = "split_clips"
    case rippleDeleteRanges = "ripple_delete_ranges"
    case setClipProperties = "set_clip_properties"
    case setKeyframes = "set_keyframes"
    case applyLayout = "apply_layout"
    case syncClips = "sync_clips"
    case trimClips = "trim_clips"
    case duplicateClips = "duplicate_clips"
    case copyAttributes = "copy_attributes"
    case linkClips = "link_clips"
    case manageNest = "manage_nest"
    case swapClipMedia = "swap_clip_media"
    case relinkMedia = "relink_media"
    case cutoutSubject = "cutout_subject"
    case manageMarkers = "manage_markers"
    case undo = "undo"

    // Multicam
    case manageMulticam = "manage_multicam"
    case changeCam = "change_cam"
    case getMulticam = "get_multicam"

    // Transcript
    case getTranscript = "get_transcript"
    case removeWords = "remove_words"
    case removeSilence = "remove_silence"
    case detectBeats = "detect_beats"

    // Text & captions
    case addTexts = "add_texts"
    case updateText = "update_text"
    case addCaptions = "add_captions"

    // Motion graphics
    case manageMotionScene = "manage_motion_scene"

    // Color & effects
    case applyColor = "apply_color"
    case applyEffect = "apply_effect"
    case inspectColor = "inspect_color"
    case denoiseAudio = "denoise_audio"

    // Generation
    case listModels = "list_models"
    case generateVideo = "generate_video"
    case generateTransition = "generate_transition"
    case generateImage = "generate_image"
    case generateAudio = "generate_audio"
    case upscaleMedia = "upscale_media"

    // Review
    case reviewTimeline = "review_timeline"
    case manageReferences = "manage_references"

    // Meta
    case sendFeedback = "send_feedback"
    case readSkill = "read_skill"
    case readProjectContext = "read_project_context"
}

struct AgentTool: @unchecked Sendable {
    let name: ToolName
    let description: String
    let inputSchema: [String: Any]
}

enum ToolDefinitions {
    static let all: [AgentTool] = [
        AgentTool(
            name: .getTimeline,
            description: "Always call at the start of a session. Returns project settings (fps, resolution, totalFrames, durationSeconds), tracks with a stable trackId, their current index (what every trackIndex parameter takes), type, and clips, plus canGenerate (if false, generation/upscale tools will fail — tell the user to sign in to Palmier and subscribe, or to add their own OpenRouter/ElevenLabs API key in Settings, before attempting them). When the project has a linked source/brand folder, linkedContext reports its path — explore it with read_project_context. Clip ids are accepted by clip mutation tools; trackId is accepted by manage_tracks. A timeline with markers also reports markers: [{markerId, frame, kind, color, name?, note?, done?}] — the notes pinned to a frame, edited with manage_markers.\n\nEvery clip occupies frames: [start, end) — timeline frames, end exclusive, duration = end − start. gaps on a track lists its empty [start, end) spans; no gaps key means contiguous. A video clip's linked audio partner is folded into it as audio: {id, track, …} carrying only what deviates (volumeDb, effects, differing trims); the partner is not repeated on its own track, which instead reports linkedClips (its folded count). Address the audio side by its nested id.\n\nFields equal to their defaults are omitted: mediaType 'video', sourceClipType = mediaType, speed 1, volumeDb 0, opacity 1, edgeRounding 0, edgeSoftness 0, trims/fades 0, identity transform/crop, default textStyle, track muted/hidden false. Text clips never report trims. Keyframe tracks that animate nothing are shown as what they are: identity tracks are dropped, constant ones appear as the static field (e.g. crop: {left: 0.31}). A graded clip carries `color` — its grade in apply_color's own vocabulary, pasteable to other clips via apply_color's color parameter. Other effects appear as effects: [{type, params}], the exact shape apply_effect accepts.\n\nCaption clips (sharing a captionGroupId) come back per track as captionGroups summaries: clipCount, frameRange, shared style, and a textPreview — individual caption clips and their ids are NOT listed. That summary is all you need to restyle (update_text with captionGroupId) or judge coverage; the spoken words live in get_transcript. Only when you must touch individual caption clips (retime one, delete one, fix one word's style), re-read with captionDetail:true — ideally windowed — to get [clipId, startFrame, endFrame, text] rows, capped at 200 per group. Caption clips whose properties deviate from the group always appear individually in clips.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Window start (inclusive); only clips intersecting [startFrame, endFrame) are returned. Tracks report totalClips when the window hides some."],
                    "endFrame": ["type": "integer", "description": "Optional. Window end (exclusive)."],
                    "captionDetail": ["type": "boolean", "description": "Optional. true expands captionGroups into per-clip [clipId, startFrame, endFrame, text] rows. Combine with a window; only needed to edit individual caption clips."],
                ]
            )
        ),
        AgentTool(
            name: .readProjectContext,
            description: "Read the project's linked source/brand folder (set in the Inspector under Context). Use this when get_timeline reports linkedContext — to pull product copy, design tokens, colors, typography, component structure, logos, and other corporate-design cues before generating or styling. action='list' walks a relative path (default '.') up to maxDepth; skips junk like node_modules/.git. action='read' returns text for source/token files or the image bytes for common image formats. Paths are relative to the linked root and cannot escape it.",
            inputSchema: objectSchema(
                properties: [
                    "action": ["type": "string", "enum": ["list", "read"], "description": "list directories/files, or read one file."],
                    "path": ["type": "string", "description": "Relative path under the linked folder. Optional for list (default '.'). Required for read."],
                    "maxDepth": ["type": "integer", "description": "list only. Directory depth to walk (default 2, max 6)."],
                ],
                required: ["action"]
            )
        ),
        AgentTool(
            name: .inspectTimeline,
            description: "See the composited timeline — what the user actually sees in the preview at a given frame: all video tracks stacked with their transforms, opacity, crop, edge softness, edge rounding, and keyframes applied, plus text and caption overlays baked in. Use this to verify your edits landed (a PIP's position, a title's placement, layer order) — inspect_media shows the raw source asset, not the cut.\n\nFrames are project frames (from get_timeline). Pass a single startFrame for one composited frame; add endFrame to sample maxFrames evenly across [startFrame, endFrame) for a transition or sequence. Frames past content render black. Each image carries its frame number burned into the top-left (f157), and the metadata lists, per rendered frame, the clip ids visible on screen top-down (caption clips as their captionGroupId) — so what you see maps straight back to the clips to edit.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Project frame to render (default 0). With no endFrame, a single frame is returned."],
                    "endFrame": ["type": "integer", "description": "Optional. Sample maxFrames evenly across [startFrame, endFrame) instead of one frame."],
                    "maxFrames": ["type": "integer", "description": "Frames to sample when endFrame is set (default 6, max 12)."],
                ]
            )
        ),
        AgentTool(
            name: .createTimeline,
            description: "Creates a timeline and switches to it — every read and edit tool now targets it. Without 'from', the new timeline is empty and inherits fps/resolution from the previously active one. With 'from', it's a full copy of that timeline — the versioning primitive: copy, then edit the copy (\"a tighter cut\", \"a 9:16 version\") while the original stays intact; every clip and track id in the copy is NEW, so re-read get_timeline before editing. Undoable.\n\nUse timelines to organize a project: alternate versions, sections assembled separately, or reusable groups. A timeline can be placed inside another as a single clip (add_clips with the timelineId as mediaRef); it then appears as a clip with mediaType 'sequence'.",
            inputSchema: objectSchema(
                properties: [
                    "name": ["type": "string", "description": "Optional display name. Defaults to 'Timeline N', or '<source> copy' when duplicating."],
                    "from": ["type": "string", "description": "Optional timelineId to duplicate instead of creating empty."],
                ]
            )
        ),
        AgentTool(
            name: .setActiveTimeline,
            description: "Switches the active timeline — the one every read and edit tool targets and the one the user sees. get_media lists the project's timelines (with timelineId). Always re-read get_timeline after switching; clip and track ids from the previous timeline are no longer valid targets.\n\nTo edit the contents of a nested timeline (a clip with mediaType 'sequence'), switch to its mediaRef.",
            inputSchema: objectSchema(
                properties: [
                    "timelineId": ["type": "string", "description": "Timeline id from get_media's timelines list (or a sequence clip's mediaRef)."],
                ],
                required: ["timelineId"]
            )
        ),
        AgentTool(
            name: .setProjectSettings,
            description: "Change the project's frame rate, resolution, or aspect ratio. Pass fps, explicit width+height, aspectRatio, or quality. aspectRatio accepts presets or a custom width:height value and preserves the current short-edge resolution unless quality is also supplied. Explicit width/height can't be combined with aspectRatio or quality. The timeline's existing clips are re-fitted automatically: auto-fit transforms recalculate for the new canvas size, and all frame positions/durations rescale when fps changes. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "fps": ["type": "integer", "description": "Frame rate in frames per second. Common values: 24, 25, 30, 48, 50, 60."],
                    "width": ["type": "integer", "description": "Canvas width in pixels. Requires height for an exact resolution. Mutually exclusive with aspectRatio and quality."],
                    "height": ["type": "integer", "description": "Canvas height in pixels. Requires width for an exact resolution. Mutually exclusive with aspectRatio and quality."],
                    "aspectRatio": ["type": "string", "description": "Canvas aspect ratio as width:height, such as '16:9', '3:2', or '2.39:1'. Preserves the current short edge, or uses quality when supplied. Mutually exclusive with width/height."],
                    "quality": ["type": "string", "enum": ["720p", "1080p", "2K", "4K"], "description": "Resolution quality preset — scales the short edge to the target while preserving the current (or specified) aspect ratio."],
                ]
            )
        ),
        AgentTool(
            name: .exportProject,
            description: "Queues an export from the current project using the same modes as the Export dialog. mode defaults to video. video renders H.264, H.265, or ProRes; xml writes XMEML timeline XML; fcpxml writes FCPXML; palmier writes a self-contained .palmier project package. For timeline interchange, pick the format by the target editor: Premiere Pro -> xml; DaVinci Resolve or Final Cut Pro -> fcpxml (fcpxml also carries text, transforms, crop, opacity, and keyframes that xml cannot). Video exports render edge softness and edge rounding, Palmier project exports preserve them, and xml/fcpxml interchange omits them. Omit outputPath to write a unique file to ~/Downloads. Existing direct outputPath files are overwritten by default to match the UI save flow; pass overwrite=false to refuse. Every mode returns status=started or status=queued with a jobId and destination path. Use manage_exports to check progress, warnings/results, or cancel by jobId; agent exports post a system notification on completion or failure.",
            inputSchema: objectSchema(
                properties: [
                    "mode": ["type": "string", "enum": ["video", "xml", "fcpxml", "palmier"], "description": "Optional. Default video. Use xml for Premiere Pro, fcpxml for DaVinci Resolve or Final Cut Pro."],
                    "codec": ["type": "string", "enum": ["H.264", "H.265", "ProRes"], "description": "Video mode only. Optional. Default H.264."],
                    "resolution": ["type": "string", "enum": ["720p", "1080p", "2K", "4K", "Match Timeline"], "description": "Video mode only. Optional. Default Match Timeline."],
                    "outputPath": ["type": "string", "description": "Optional. Absolute destination path. If omitted, a unique project-named file is written to ~/Downloads. If no extension is provided, the mode's extension is appended."],
                    "overwrite": ["type": "boolean", "description": "Optional. Default true, matching the UI save flow. false refuses when outputPath already exists."],
                    "fcpxmlTarget": ["type": "string", "enum": ["resolve", "fcp"], "description": "fcpxml mode only. Optional, default resolve. Davinci Resolve and Final Cut interpret crop and position values differently; pick the app the file will be imported into."],
                    "timelineId": ["type": "string", "description": "Optional. Timeline to export (from get_timeline's timelines list). Defaults to the active timeline. Not valid for palmier mode, which packages every timeline."],
                ]
            )
        ),
        AgentTool(
            name: .manageExports,
            description: "Lists or cancels exports for the current project. action=list returns newest first with jobId, filename, path, status, progress percent, and any warnings/result. action=cancel requires the exact jobId returned by export_project or list; a waiting job is removed from the queue and an active job begins canceling. Cancel only when the user asks, or to undo an export just queued with incorrect settings. Never infer that an export is stuck from elapsed time alone.",
            inputSchema: objectSchema(
                properties: [
                    "action": ["type": "string", "enum": ["list", "cancel"], "description": "list reports every queued/running/finished export job with progress and warnings; cancel stops the job named by jobId."],
                    "jobId": ["type": "string", "description": "Required for cancel. Exact jobId from export_project or manage_exports list."],
                ],
                required: ["action"]
            )
        ),
        AgentTool(
            name: .getMedia,
            description: "The library inventory: media assets, folders, and timelines. Call before referencing any asset — every mediaRef in other tools comes from the asset ids returned here. Assets report name, type, durationSeconds, width/height/fps, hasAudio, folder path, and (for AI-generated assets) the generation prompt as a content hint. generationStatus appears only while an async generation/import is unresolved (preparing | generating | downloading | failed) — its absence means the asset is ready.\n\nFilters: ids (poll specific placeholders cheaply), folder (a path; includes subfolders), pending:true (only unresolved generations/imports). Filtered reads return just the matching assets; unfiltered reads also include folders (as paths) and timelines.",
            inputSchema: objectSchema(
                properties: [
                    "ids": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Optional. Return only these asset ids — the cheap way to poll a generation placeholder.",
                    ],
                    "folder": ["type": "string", "description": "Optional folder path filter, e.g. 'B-roll/Sunset'. Includes subfolders."],
                    "pending": ["type": "boolean", "description": "Optional. true returns only assets with an unresolved generationStatus."],
                ]
            )
        ),
        AgentTool(
            name: .inspectMedia,
            description: "Look at a media asset before referencing or editing it. Images: the image plus dimensions and EXIF. Video: sample frames plus a transcription of the audio track. Audio: transcription. Lottie: frames sampled evenly across the animation (over gray), plus framerate and duration — use this to verify a Lottie you wrote looks and moves right. Transcription is sentence-level segments — [text, start, end] tuples, capped at 400 — in source seconds, or project frames when clipId is set. When capped, pass the returned nextStartSeconds as startSeconds for the next page.\n\nLong media: pass overview=true for a one-image storyboard, read the segments, then re-call with startSeconds/endSeconds to zoom — windowed calls only transcribe that span, so they are fast.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Asset ID from get_media."],
                    "clipId": ["type": "string", "description": "Optional. A clip referencing this mediaRef; transcript times come back as project frames for that clip (out-of-range entries dropped)."],
                    "maxFrames": ["type": "integer", "description": "Video and Lottie. Sample frame count (default 6, max 12)."],
                    "startSeconds": ["type": "number", "description": "Video/audio. Source-time window start; scopes frames and transcription."],
                    "endSeconds": ["type": "number", "description": "Video/audio. Window end (default: asset duration)."],
                    "wordTimestamps": ["type": "boolean", "description": "Video/audio. Add word-level [text, start, end] tuples (capped at 10000 — most clips return all words at once; narrow with startSeconds/endSeconds only for very long media). Use for word-boundary edits like filler-word removal."],
                    "overview": ["type": "boolean", "description": "Video only. One storyboard grid of visually distinct, timestamped moments instead of frames — far more coverage per token; few tiles means static footage. maxFrames ignored."],
                    "language": ["type": "string", "description": "Optional BCP-47 language tag of the spoken audio (e.g. 'es', 'fr', 'ja', 'zh-Hans'). Defaults to the system language. Specify when the spoken language differs from the system locale — on-device models are language-specific and will produce garbled output if the wrong language is used."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .searchMedia,
            description: "Search the media library by content: what's on screen (visual) and what's said (spoken). Visual matching is semantic and on-device — phrase the query like an image caption ('a wide shot of a harbor at sunset'), not keywords; covers videos and stills. Spoken matching layers exact keywords over on-device semantic matching of transcript segments — quote the words said, or paraphrase them; transcripts are created automatically while indexing (and by inspect_media and add_captions), so coverage grows as indexing completes. The two groups rank independently and are never blended. Scores are uncalibrated — use them for ordering only.\n\nHits are source-second ranges (image hits have no time range). To place exactly that moment, pass [startSeconds, endSeconds] straight to add_clips as source — no unit conversion.\n\nAn `index` object appears only while it can explain missing results (status: indexing | modelNotInstalled | downloadingModel | preparing | disabled | failed, with indexedAssets vs indexableAssets). When present, moments may be incomplete — report that instead of concluding the footage doesn't exist, and don't poll in a loop. No index key means visual search was complete. Spoken results work regardless.",
            inputSchema: objectSchema(
                properties: [
                    "query": ["type": "string", "description": "What to find. Visual: a caption-style scene description. Spoken: the words to match."],
                    "scope": ["type": "string", "enum": ["visual", "spoken", "both"], "description": "Optional. Default both."],
                    "mediaRef": ["type": "string", "description": "Optional. Restrict the search to one asset from get_media."],
                    "limit": ["type": "integer", "description": "Optional. Max hits per group (default 10, max 50)."],
                ],
                required: ["query"]
            )
        ),
        AgentTool(
            name: .importMedia,
            description: "Imports external media into the project's library — the bridge for assets coming from other MCP servers (stock libraries, music services, web search) or local files the user already has. The 'source' object must set exactly one of: url (HTTPS only — downloaded in the background, the dominant case; max 1 GB), path (absolute local file path — referenced in place and not copied into the project; may also be a directory, which is imported recursively, mirroring its subfolder structure as media folders), bytes (base64-encoded inline data — max ~15 MB of base64 ≈ 11 MB binary; use url/path for anything larger), or matte (a generated solid-color PNG). For url, type is inferred from the URL path's file extension unless source.mimeType is set as an override (needed for signed URLs whose path has no usable extension). For bytes, source.mimeType is required.\n\nSupported types and extensions: video (mov, mp4, m4v), audio (mp3, wav, aac, m4a, aiff, aifc, caf, flac), image (png, jpg, jpeg, tiff, heic). Anything else is rejected — the caller must transcode externally.\n\nURL imports run in the background and return {mediaRef, status:'downloading'} — poll get_media with ids:[mediaRef] until generationStatus clears, then the asset is usable in add_clips. Path, directory, bytes, and matte imports finish inline with status:'ready'. Costs nothing.",
            inputSchema: objectSchema(
                properties: [
                    "source": [
                        "type": "object",
                        "description": "Exactly one of url, path, bytes, or matte must be set. mimeType is required when bytes is set; for url it acts as a type-inference override.",
                        "properties": [
                            "url": ["type": "string", "description": "HTTPS URL. Pre-signed URLs are fine but must not expire mid-download."],
                            "path": ["type": "string", "description": "Absolute local file or directory path, readable by the Palmier process. Files are referenced in place and must remain available. A directory is imported recursively and its folder structure is replicated as media folders."],
                            "bytes": ["type": "string", "description": "Base64-encoded media data. Prefer url or path for anything over ~10MB."],
                            "matte": [
                                "type": "object",
                                "description": "Generates a solid-color PNG matte instead of importing a file.",
                                "properties": [
                                    "hex": ["type": "string", "description": "Hex color, e.g. '#000000' or '#FFFFFF'."],
                                    "aspectRatio": [
                                        "type": "string",
                                        "enum": ["Project", "16:9", "9:16", "1:1", "4:3", "9:14", "2.4:1"],
                                        "description": "Defaults to Project (timeline resolution). Other values use the project's short edge.",
                                    ],
                                ],
                                "required": ["hex"],
                            ],
                            "mimeType": ["type": "string", "description": "Required when bytes is set. Optional override for url when its path has no usable extension (e.g. signed URLs). Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, image/png, image/jpeg, image/tiff, image/heic."],
                        ],
                    ],
                    "name": ["type": "string", "description": "Display name in the library. Defaults to the filename derived from url/path, or 'Imported asset' for bytes."],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'B-roll/Sunset'. Created if missing. Omit for the project root."],
                ],
                required: ["source"]
            )
        ),
        AgentTool(
            name: .searchStockMedia,
            description: "Search free, royalty-free stock photos and videos on Pexels and Pixabay (both licensed for commercial use without attribution). Use this when the user asks for stock footage, B-roll, background images, or filler media they don't have in their library — search_media only covers media already imported. Requires a free Pexels or Pixabay API key in Settings → Models; the error names the missing key if none is configured.\n\nReturns items with a downloadUrl — nothing is imported yet. To bring a result into the project, pass its downloadUrl to import_media as source.url (add source.mimeType 'image/jpeg' or 'video/mp4' if the URL has no usable extension), then poll get_media until the download finishes. Results are page-based; increase page for more. Videos are mp4, photos jpg, sized for editing (largest available rendition).",
            inputSchema: objectSchema(
                properties: [
                    "query": ["type": "string", "description": "What to find, keyword-style ('drone shot beach sunset', 'office teamwork')."],
                    "kind": ["type": "string", "enum": ["photo", "video"], "description": "Search photos or videos."],
                    "provider": ["type": "string", "enum": ["pexels", "pixabay"], "description": "Optional. Defaults to the first provider with a configured API key (Pexels preferred). The receipt lists configuredProviders."],
                    "page": ["type": "integer", "description": "Optional. 1-based results page (default 1)."],
                    "perPage": ["type": "integer", "description": "Optional. Results per page (default 20, max 80)."],
                ],
                required: ["query", "kind"]
            )
        ),
        AgentTool(
            name: .captureFrame,
            description: "Capture one video frame as a full-resolution PNG media asset. Use timelineFrame to capture the active timeline's final composited image, including transforms, crop, edge softness, edge rounding, color, effects, text, and captions. Use mediaRef with sourceSeconds to capture an unedited frame directly from a source video instead. Pass the asset's durationSeconds as sourceSeconds to capture its final decodable frame. Exactly one mode is allowed. The returned mediaRef is ready for add_clips, generate_video startFrameMediaRef/endFrameMediaRef, generate_image references, or inspect_media. Every call creates one new undoable media asset.",
            inputSchema: objectSchema(
                properties: [
                    "timelineFrame": ["type": "integer", "description": "Project frame in the active timeline. Use this alone for the composited timeline image."],
                    "mediaRef": ["type": "string", "description": "Video asset ID from get_media. Use with sourceSeconds for a raw source frame."],
                    "sourceSeconds": ["type": "number", "description": "Source time in seconds for mediaRef. May equal durationSeconds to select the final decodable frame."],
                    "name": ["type": "string", "description": "Optional media-library name for the captured PNG."],
                ]
            )
        ),
        AgentTool(
            name: .organizeMedia,
            description: "Reorganizes the library in one undoable action: create folders, move items into folders, rename items, delete items. An item is a media asset id (from get_media), a timelineId, or a folder path like 'B-roll/Sunset' — the tool tells them apart. Folders are always addressed by path, never by id; destination paths are created if missing. Arrays apply in order (createFolders, moves, renames, deletes), but item references resolve against the library as it was before the call — only 'into' destinations may name folders the same call creates.\n\nDeleting an asset also removes every clip referencing it (reported as clipsRemoved). Deleting a folder deletes its subfolders and assets; timelines inside move to the root instead. Deleting a timeline leaves nest clips referencing it rendering black (a warning reports how many); the last remaining timeline can't be deleted. Returns only what actually happened — createdFolders, moved, renamed, deleted, clipsRemoved, warnings.",
            inputSchema: objectSchema(
                properties: [
                    "createFolders": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Folder paths to ensure exist, e.g. ['Hero shots/Takes']. Existing folders are left alone. Rarely needed — moves and generation 'folder' params create folders on their own.",
                    ],
                    "moves": [
                        "type": "array",
                        "description": "Each entry files items into one destination folder.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "items": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Asset ids, timeline ids, and/or folder paths to move.",
                                ],
                                "into": ["type": "string", "description": "Destination folder path; created if missing. Omit to move to the project root."],
                            ],
                            "required": ["items"],
                        ],
                    ],
                    "renames": [
                        "type": "array",
                        "description": "Display renames, applied after moves. Each item is {item, name}.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "item": ["type": "string", "description": "Asset id, timeline id, or folder path."],
                                "name": ["type": "string", "description": "New display name (a name, not a path — renaming never moves)."],
                            ],
                            "required": ["item", "name"],
                        ],
                    ],
                    "deletes": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Asset ids, timeline ids, and/or folder paths to delete.",
                    ],
                ]
            )
        ),
        AgentTool(
            name: .addClips,
            description: "Places one or more media assets on the timeline as a single undoable action. Each entry's asset type must be compatible with its target track (video/image are interchangeable across video/image tracks; audio requires an audio track). When a video asset with audio is placed on a video track, a linked audio clip is automatically created on an audio track (an existing one if available, otherwise a new one). The whole batch is one undo step.\n\ntrackIndex is optional. Omit it on all entries and the tool auto-creates the needed tracks — one shared video track for visual entries (above existing visuals) and one shared audio track for audio entries (appended below existing audio, so linked dialogue on A1 stays put and music/VO land on A2+). To target existing tracks, set trackIndex on every entry. Mixing (some entries specify, others omit) is rejected — split into two calls.\n\nTracks work as layers: clips on the SAME track are sequential — if a new clip's range overlaps an existing clip on that track, the existing clip is trimmed/split/removed to make room, matching the UI's drag-onto-track overwrite behavior.\n\nNESTING: mediaRef may also be a timelineId — the timeline is placed as a single live nested clip (mediaType 'sequence'), with a linked audio clip when the child has audio. Duration defaults to the child's full length; source and endFrame work as for video. Cycles (a timeline containing itself) and empty timelines are rejected.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Clips to add. Each entry is validated up front; one bad entry rejects the whole call with no partial state.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "ID of the media asset from get_media"],
                                "trackIndex": ["type": "integer", "description": "Optional. Track index (0-based). Omit on every entry to auto-create one shared track per asset zone (video/audio)."],
                                "startFrame": ["type": "integer", "description": "Timeline frame position to place the clip (project frames)."],
                                "endFrame": ["type": "integer", "description": "Optional. Occupy timeline frames [startFrame, endFrame) — a gap from get_timeline copies straight in. For stills and frame-exact fills. Mutually exclusive with source."],
                                "source": ["type": "array", "items": ["type": "number"], "description": "Optional. [startSeconds, endSeconds] — which span of the source to use, in the source seconds search_media hits and inspect_media segments speak. For stills this is the display length in seconds. Omit both for the whole asset. Mutually exclusive with endFrame."],
                            ],
                            "required": ["mediaRef", "startFrame"],
                        ],
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .insertClips,
            description: "Inserts one or more media assets at a single point and RIPPLES: every clip at or after atFrame is pushed right to open a gap, so nothing is overwritten. This is the non-destructive counterpart to add_clips (which clears the landing region, trimming/splitting/removing whatever's there). Use insert_clips to splice footage in without losing existing clips; use add_clips to fill empty space or deliberately overwrite.\n\nEntries are laid end-to-end starting at atFrame on the target track (entry[0] at atFrame, entry[1] immediately after, ...). The push equals the sum of the entries' durations and is applied to the target track, every sync-locked track, AND the audio track any auto-created linked audio lands on — so a clip and its linked audio stay aligned. As in add_clips, a video asset with audio spawns a linked audio clip. One undoable action; one bad entry rejects the whole call with no partial state.\n\ntrackIndex is required — ripple needs an existing track to push. For placement into empty space, use add_clips.\n\nAs in add_clips, mediaRef may be a timelineId to splice in a nested timeline.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndex": ["type": "integer", "description": "Track index (0-based, from get_timeline) to insert into and ripple."],
                    "atFrame": ["type": "integer", "description": "Timeline frame (project frames) where insertion begins. Every clip at or after this frame on rippled tracks shifts right by the total inserted duration."],
                    "entries": [
                        "type": "array",
                        "description": "Clips to insert, placed sequentially from atFrame. Validated up front; one bad entry rejects the whole call.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "mediaRef": ["type": "string", "description": "ID of the media asset from get_media."],
                                "source": ["type": "array", "items": ["type": "number"], "description": "Optional. [startSeconds, endSeconds] — which span of the source to use, in source seconds; for stills, the display length. Omit for the whole asset. Mutually exclusive with durationFrames."],
                                "durationFrames": ["type": "integer", "description": "Optional. Exact length in project frames (entries stack end-to-end, so they have lengths, not positions). Mutually exclusive with source."],
                            ],
                            "required": ["mediaRef"],
                        ],
                    ],
                ],
                required: ["trackIndex", "atFrame", "entries"]
            )
        ),
        AgentTool(
            name: .moveClips,
            description: "Moves one or more clips to a new track and/or frame position. Single undoable action. Each move specifies the clip ID and at least one of toTrack (must be compatible with the clip's media type) and toFrame. Overlap on the destination is resolved as in add_clips (existing clips on the destination track are trimmed/split/removed). Linked partners follow the named clip: startFrame propagates as a delta to preserve l-cut / j-cut offsets; tracks stay with the named clip. Multicam clips must move as a whole group; partial group moves and camera lane changes are refused.",
            inputSchema: objectSchema(
                properties: [
                    "moves": [
                        "type": "array",
                        "description": "Per-clip move requests. At least one of toTrack or toFrame is required per entry.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "clipId": ["type": "string", "description": "The clip ID to move."],
                                "toTrack": ["type": "integer", "description": "Destination track index (0-based). Omit to keep the clip on its current track."],
                                "toFrame": ["type": "integer", "description": "Destination start frame. Omit to keep the clip at its current start."],
                            ],
                            "required": ["clipId"],
                        ],
                    ],
                ],
                required: ["moves"]
            )
        ),
        AgentTool(
            name: .removeClips,
            description: "Removes one or more clips by ID as a single undoable action. Any clip that belongs to a link group (e.g. a video with its paired audio) takes its whole group with it, matching the UI's linked-delete behavior.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "description": "Clip IDs to remove.",
                        "items": ["type": "string"],
                    ],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .manageTracks,
            description: "Reorders, configures, or removes tracks in one undoable action. Prefer stable trackId selectors; numeric indexes use the order at call time. Index 0 renders on top, and reorder destinations must stay within the track's video/audio zone. Arrays run reorder → set → remove. Returns receipts and the resulting track order. Tracks holding multicam clips can't be removed or sync-unlocked.",
            inputSchema: objectSchema(
                properties: [
                    "reorder": [
                        "type": "array",
                        "description": "Moves, applied in order. Use to fix stacking, e.g. bring a PIP inset's track to index 0.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "trackId": ["type": "string", "description": "Stable track ID from get_timeline."],
                                "index": ["type": "integer", "description": "Track to move (0-based, current order)."],
                                "to": ["type": "integer", "description": "Exact destination index in the same type zone."],
                            ],
                            "required": ["to"],
                        ],
                    ],
                    "set": [
                        "type": "array",
                        "description": "Per-track state changes (muted, hidden, syncLocked). Select each track by trackId or index.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "trackId": ["type": "string", "description": "Stable track ID from get_timeline."],
                                "index": ["type": "integer", "description": "Track to change (0-based, current order)."],
                                "muted": ["type": "boolean", "description": "Silence/unsilence the track's audio."],
                                "hidden": ["type": "boolean", "description": "Exclude/include a video track in the render."],
                                "syncLocked": ["type": "boolean", "description": "Whether ripple edits shift this track along."],
                            ],
                        ],
                    ],
                    "remove": [
                        "type": "array",
                        "description": "Tracks to remove with all their clips. Prefer {trackId}; bare integers are legacy current indexes.",
                        "items": ["type": ["integer", "object"], "properties": ["trackId": ["type": "string"]]],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .manageMarkers,
            description: "Reads and edits the active timeline's markers — the notes a filmmaker pins to a frame: standard markers for review notes, chapter markers for the export chapter list, todo markers for open work (done tracks whether it's handled). Markers annotate the timeline; they never change the cut, so no clip moves.\n\nCall with no arguments to list every marker with its stable markerId. add/update/remove run in that order as ONE undoable action, and one call is the whole change: pass every marker at once rather than one call per marker. frame is a project frame within [0, totalFrames]; an out-of-range frame, an unknown markerId, or an unknown kind/color rejects the whole call and changes nothing. name is what a chapter list or review note shows; note carries the longer text.\n\nChapter markers drive a YouTube-style '<timestamp> <name>' sidecar written next to a video export, so building a chapter list means adding chapter markers before export_project — name them, and start at frame 0 for a valid list. Returns the resulting marker set plus per-request receipts; an update that matches the marker's current state is reported as unchanged instead of as an edit.",
            inputSchema: objectSchema(
                properties: [
                    "add": [
                        "type": "array",
                        "description": "Markers to create at project frames.",
                        "items": objectSchema(
                            properties: [
                                "frame": ["type": "integer", "description": "Project frame, 0…totalFrames."],
                                "name": ["type": "string", "description": "Short label, e.g. a chapter title."],
                                "note": ["type": "string", "description": "Longer text for the marker."],
                                "kind": ["type": "string", "enum": MarkerKind.allCases.map(\.rawValue), "description": "Default standard. chapter feeds the export chapters sidecar."],
                                "color": ["type": "string", "enum": MarkerColor.allCases.map(\.rawValue), "description": "Default blue."],
                                "done": ["type": "boolean", "description": "todo markers only — whether the task is handled."],
                            ],
                            required: ["frame"]
                        ),
                    ],
                    "update": [
                        "type": "array",
                        "description": "Changes to existing markers. Only the fields passed change.",
                        "items": objectSchema(
                            properties: [
                                "markerId": ["type": "string", "description": "Stable marker id from get_timeline or this tool."],
                                "frame": ["type": "integer", "description": "New project frame, 0…totalFrames."],
                                "name": ["type": "string"],
                                "note": ["type": "string"],
                                "kind": ["type": "string", "enum": MarkerKind.allCases.map(\.rawValue)],
                                "color": ["type": "string", "enum": MarkerColor.allCases.map(\.rawValue)],
                                "done": ["type": "boolean", "description": "todo markers only."],
                            ],
                            required: ["markerId"]
                        ),
                    ],
                    "remove": [
                        "type": "array",
                        "description": "Marker ids to delete.",
                        "items": ["type": "string"],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .splitClips,
            description: "Splits clips into two at one or more cut points, all in a single undoable action. A split only inserts a boundary — it never trims media or moves clips, so unlike ripple_delete_ranges nothing shifts and there's no gap to close.\n\nTwo modes — pass exactly one:\n• splits: an array of {clipId, atFrame} (project frames). Use when you know the clip IDs.\n• trackIndex + frames: cut one track at the given project frames; each frame is matched to whichever clip on that track contains it. Pairs naturally with get_transcript / get_timeline project frames.\n\nEvery frame must fall strictly between a clip's start and end. Multiple cuts on the SAME clip are allowed — pass all the frames at once and each is resolved against the current sub-clips. Duplicate cut points are ignored. Linked audio/video partners are split at the same frame so A/V stays in sync, and the right halves are regrouped into their own link pair. One bad cut point rejects the whole call with no partial state.",
            inputSchema: objectSchema(
                properties: [
                    "splits": [
                        "type": "array",
                        "description": "Explicit cuts. Each item is {clipId, atFrame}.",
                        "items": objectSchema(
                            properties: [
                                "clipId": ["type": "string", "description": "The clip ID to split"],
                                "atFrame": ["type": "integer", "description": "Project frame to split at (strictly between clip start and end)"],
                            ],
                            required: ["clipId", "atFrame"]
                        ),
                    ],
                    "trackIndex": ["type": "integer", "description": "Track to cut (use with 'frames')"],
                    "frames": [
                        "type": "array",
                        "description": "Project frames to cut on trackIndex; each is matched to the clip containing it.",
                        "items": ["type": "integer"],
                    ],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .rippleDeleteRanges,
            description: "Cuts one or more ranges out and closes the gaps in one undoable action — the fast path for filler-word/dead-air removal. Replaces hand-cranked split_clips → remove_clips → move_clips loops: pass every range at once.\n\nTwo modes — pass exactly one of clipId or trackIndex:\n• trackIndex (preferred for transcript-driven cuts): ranges are PROJECT frames and may span any number of clips on that track. get_transcript returns a clips array with nested words in project frames — collect every cut across the whole timeline and pass them in ONE call, no per-clip splitting and no re-reading the timeline between cuts. units must be 'frames'.\n• clipId: ranges are cut within that single clip only, clamped to its visible span. Allows units 'seconds' (source-media seconds, e.g. inspect_media WITHOUT a clipId or search_media hits); 'frames' = project frames. Use when you already have one clip's per-word timestamps.\n\nOverlapping ranges merge. Linked audio/video partners of every touched clip are cut on the same span so A/V stays in sync. Remaining clips shift left to close every gap; sync-locked tracks shift along to preserve alignment (their content isn't cut). Refuses without changing anything if a sync-locked track can't absorb the shift (e.g. it would move past frame 0). The refusal names the blocking track (e.g. \"V2\") — map it to its index via get_timeline and pass that index in ignoreSyncLockedTracks to cut anyway, leaving that track's clips in place. Returns the anchor track's post-cut layout (clip ids/frames) so you don't need to re-read.",
            inputSchema: objectSchema(
                properties: [
                    "trackIndex": ["type": "integer", "description": "Cut project-frame ranges spanning every clip they cross on this track, in one call. From get_transcript's clips array. Mutually exclusive with clipId; requires units 'frames'."],
                    "clipId": ["type": "string", "description": "Cut ranges within this single clip only, clamped to its visible span. Mutually exclusive with trackIndex."],
                    "ranges": [
                        "type": "array",
                        "description": "Ranges to remove, each a [start, end] pair (end > start). In the unit given by 'units'.",
                        "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                    ],
                    "units": ["type": "string", "enum": ["seconds", "frames"], "description": "Interpretation of range values. 'frames' (default) = project/timeline frames, matching get_transcript and inspect_media-with-clipId. 'seconds' = source-media seconds (clipId mode only)."],
                    "ignoreSyncLockedTracks": [
                        "type": "array",
                        "items": ["type": "integer"],
                        "description": "Track indices to exempt from sync-lock for this call only. Their clips stay put instead of shifting to close the gap. Use to get past a refusal naming a sync-locked overlay track (e.g. a text track that can't absorb the shift) when the cut doesn't touch that track's content.",
                    ],
                ],
                required: ["ranges"]
            )
        ),
        AgentTool(
            name: .setClipProperties,
            description: "Apply the same generic clip property values to one or more clips in a single undoable action. Pass any combination of durationFrames, trimStartFrame, trimEndFrame, speed, volumeDb, opacity, fades, edgeRounding, edgeSoftness, transform, or blendMode (video/image clips only). For text content, typography, captions, and text animation, use update_text.\n\nNOT for preview layout — split screen, picture-in-picture, grid, sidebar, and any multi-clip canvas arrangement belong to apply_layout, which sets transform and crop together. Do not use transform here (or set_keyframes position/scale/crop) to build those layouts.\n\nAll values apply to every clip in clipIds; for per-clip differences, make separate calls. trimStartFrame/trimEndFrame are offsets from the source media, not the timeline. speed 1.0 is normal, <1.0 slows (clip gets longer on the timeline), >1.0 speeds up. volumeDb is −60 through +15 dB; 0 dB keeps source level and −60 dB is mute. opacity is 0.0–1.0. fadeInFrames/fadeOutFrames are clip-relative lengths; 0 clears that fade, and their sum must fit within the resulting clip duration. Fades multiply existing opacity or volume keyframes instead of replacing them: visual/text clips fade opacity, while audio clips fade gain. Fades are per-clip and don't propagate to linked media — include both the visual clip id and its nested audio.id from get_timeline to fade picture and sound together. edgeRounding and edgeSoftness are 0.0–1.0, where 1 reaches half the shorter visible edge. transform is for rare single-clip tweaks only — 0–1 normalized canvas coords, partial merge; rotation is clockwise degrees; flipHorizontal/flipVertical mirror across the axis.\n\nFor moves and start-frame changes, use move_clips. For animated values (keyframes), use set_keyframes — setting volumeDb, opacity, or transform.rotation here clears any existing keyframe track on that property.\n\nTiming changes (durationFrames, trimStartFrame, trimEndFrame, speed) on a linked clip carry over to its linked partner so audio/video stay in sync — same as the timeline UI. Per-clip fields (volumeDb, opacity, fades, edgeRounding, edgeSoftness, transform, blendMode) don't propagate. trim and speed are skipped for text partners.\n\nTiming fields (trims, durationFrames, speed) are refused on multicam clips — they would slip the clip out of sync; property fields stay editable, and angle changes go through change_cam.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": [
                        "type": "array",
                        "description": "Clip IDs to update. The property values below apply to every clip in this list.",
                        "items": ["type": "string"],
                    ],
                    "durationFrames": ["type": "integer", "description": "New duration in frames."],
                    "trimStartFrame": ["type": "integer", "description": "SOURCE-media offset, NOT a timeline frame: frames trimmed off the start of the source — measured in PROJECT frames (the timeline's fps, same units as startFrame/durationFrames; never the source's own fps). To turn a get_transcript project frame P into this clip's source offset, use trimStartFrame + (P − startFrame) × speed; setting trimStartFrame to that value makes the clip begin at P's source content."],
                    "trimEndFrame": ["type": "integer", "description": "SOURCE-media offset, NOT a timeline frame: frames trimmed off the end of the source, in PROJECT frames. Maps the same way as trimStartFrame via startFrame/speed."],
                    "speed": ["type": "number", "description": "Playback speed multiplier (default 1.0). >1 speeds up, <1 slows down. The clip's timeline length is rescaled to keep the same source content (2x speed → half the frames), unless you also pass durationFrames to set the length explicitly."],
                    "volumeDb": [
                        "type": "number",
                        "minimum": VolumeScale.floorDb,
                        "maximum": VolumeScale.ceilingDb,
                        "description": "Volume in decibels from −60 through +15. 0 dB keeps source level; −60 dB is mute. Clears existing volume keyframes.",
                    ],
                    "opacity": ["type": "number", "description": "Opacity 0.0-1.0. Clears any existing opacity keyframes."],
                    "fadeInFrames": ["type": "integer", "minimum": 0, "description": "Fade length from the clip's first frame. 0 clears it. Multiplies existing opacity/volume keyframes."],
                    "fadeOutFrames": ["type": "integer", "minimum": 0, "description": "Fade length ending at the clip's last frame. 0 clears it. fadeInFrames + fadeOutFrames must not exceed the resulting clip duration."],
                    "fadeInInterpolation": ["type": "string", "enum": ["linear", "smooth"], "description": "Curve for the fade in. Omit to keep the current curve."],
                    "fadeOutInterpolation": ["type": "string", "enum": ["linear", "smooth"], "description": "Curve for the fade out. Omit to keep the current curve."],
                    "edgeRounding": ["type": "number", "minimum": 0, "maximum": 1, "description": "Video, image, Lottie, and nested timeline clips only. Uniform edge rounding from 0 (square) to 1 (half the shorter visible edge)."],
                    "edgeSoftness": ["type": "number", "minimum": 0, "maximum": 1, "description": "Video, image, Lottie, and nested timeline clips only. Edge feathering from 0 (crisp) to 1 (half the shorter visible edge)."],
                    "transform": [
                        "type": "object",
                        "description": "Single-clip only — not for split screen, PIP, or grid (use apply_layout). Partial transform; omitted fields keep current values. Static rotation uses clockwise degrees and clears rotation keyframes.",
                        "properties": [
                            "centerX": ["type": "number"],
                            "centerY": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"],
                            "rotation": ["type": "number", "description": "Clockwise degrees."],
                            "flipHorizontal": ["type": "boolean", "description": "Mirror across the vertical axis."],
                            "flipVertical": ["type": "boolean", "description": "Mirror across the horizontal axis."],
                        ],
                    ],
                    "blendMode": [
                        "type": "string",
                        "enum": BlendMode.allCases.map(\.rawValue),
                        "description": "Video/image clips only. How the clip composites over the tracks below it (Premiere/Photoshop blend modes). 'normal' is the default (source-over) and clears any blend. Rejected on text/audio clips.",
                    ],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .setKeyframes,
            description: "Set animated keyframes on clips — the tool for animation: moves, pushes-in, spins, fades, reveals, ducking. By default replaces the existing keyframe track for each property you pass (empty array clears it); properties you don't pass are untouched. mode 'merge' instead upserts the given rows into the existing track — use it to adjust or add single keyframes without resending the whole animation.\n\nAnimate several properties at once with `tracks` ({property: rows}) — one atomic, single-undo action, so a push-in that ramps scale, position, and opacity together is ONE call, not three. `property`+`keyframes` still sets a single track. Target one clip with `clipId` or give the same animation to several with `clipIds`; add `stagger` (frames) to offset each subsequent clip's keyframes for cascading, wave-like motion across layers.\n\nProperties and their value layouts:\n  • volumeDb `[frame, decibels]` — −60 through +15 dB; 0 dB keeps source level and −60 dB is mute\n  • opacity `[frame, value]` — value 0.0–1.0\n  • rotation `[frame, degrees]` — clockwise degrees\n  • position `[frame, topLeftX, topLeftY]` — TOP-LEFT corner in 0–1 normalized canvas coords. NOT the center. (Default static transform centers a full-canvas clip, so top-left of the static is (0, 0); a centered half-size clip has top-left (0.25, 0.25).)\n  • scale `[frame, width, height]` — clip's normalized width and height in 0–1 canvas coords (1.0 = fills the canvas axis). NOT a scale factor.\n  • crop `[frame, top, right, bottom, left]` — side insets in 0–1 of the source media.\nMotion keyframes (position/scale/rotation) override the static `transform` value when active.\n\nFrames are CLIP-RELATIVE offsets (0 = first frame of the clip), so keyframes follow the clip when it moves. Rows are sorted by frame internally and the LAST row for any duplicate frame wins. Values must be finite numbers. Each row is `[frame, ...values, ease?]` where ease describes the curve OUT of that keyframe (the segment it starts). It accepts a named easing, a cubic-bezier array, or an easing object — the same vocabulary as motion.js:\n  • named — smooth (default; symmetric in-out, natural drifts and Ken Burns), easeOut (decelerating arrival; THE default for elements entering or moving to a target), easeIn (accelerating exit), easeInOut, linear (mechanical moves, volume ramps, continuous spins), hold (freeze until the next keyframe), sineIn/sineOut/sineInOut (gentlest curves), circIn/circOut/circInOut, expoIn/expoOut (sharpest; the modern motion-design standard for punchy reveals)/expoInOut, backIn/backOut (overshoot and settle; snappy pops)/backInOut, elasticIn/elasticOut (springy oscillation)/elasticInOut, bounceIn/bounceOut/bounceInOut, anticipate (pulls back, then shoots forward), spring (bounce 0.25), steps (4 steps)\n  • [x1, y1, x2, y2] — custom cubic bezier with CSS semantics (x1/x2 within 0–1, y unbounded for overshoot/undershoot), e.g. [0.32, 0, 0.67, 0]\n  • {type: 'spring', bounce: 0–1} — physical spring resolved over the segment's duration; bounce 0 glides in critically damped, 1 is maximally bouncy. Motion.js physics form {type: 'spring', stiffness, damping, mass} is accepted and mapped onto the segment duration.\n  • {type: 'steps', count: 1–100} — stepped/typewriter motion\n  • {type: 'cubicBezier', points: [x1, y1, x2, y2]} — object form of the bezier array\n  • {type: 'back', overshoot: 0–10, direction: 'in'|'out'|'inOut'} — back easing with adjustable overshoot (default direction 'out', default overshoot 1.70158 ≈ 10% past the target; 3 ≈ 20%)\n  • {type: 'elastic', amplitude: 1–5, period: 0.05–2, direction: 'in'|'out'|'inOut'} — elastic with adjustable strength (amplitude) and oscillation wavelength (period, default 0.3; smaller = more wobbles)\n  • {out: …, in: …} — SPLIT EASE, the After-Effects model: the segment departs on the 'out' curve and blends into the 'in' curve at the next keyframe. Each side takes any form above (except 'hold' for in). Example: {out: 'easeIn', in: {type: 'back', overshoot: 2.5}} accelerates away and overshoots into the landing. Either side may be omitted (defaults to smooth).\n\nrepeat unrolls the given rows into baked cycles before writing: {count: 2–50, type: 'loop' | 'reverse' | 'mirror', gapFrames?}. 'loop' restarts each cycle from the first value (with a 1-frame jump when gapFrames is 0); 'reverse' and 'mirror' ping-pong back and forth with time-mirrored easing (identical once baked). gapFrames adds rest between cycles. The result is ordinary keyframes, individually editable afterwards. Requires mode 'replace' and applies to every passed track.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip to animate. Use clipIds instead to give several clips the same animation."],
                    "clipIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Several clips receiving the same animation in one undoable action; combine with stagger for cascaded timing.",
                    ],
                    "mode": [
                        "type": "string",
                        "enum": ["replace", "merge"],
                        "description": "replace (default) swaps each passed property's whole track; merge upserts the given rows into the existing track (adjust single keyframes without resending the rest). Empty rows are only valid with replace.",
                    ],
                    "stagger": [
                        "type": "integer",
                        "description": "Frame offset added per clip in clipIds order (clip N shifts by N×stagger). Cascades one animation across layers — titles flying in one after another, grid tiles popping in a wave. Needs at least 2 clipIds.",
                    ],
                    "repeat": [
                        "type": "object",
                        "description": "Unroll the given rows into repeated cycles: {count: 2–50, type: 'loop'|'reverse'|'mirror', gapFrames?}. loop restarts from the first value each cycle; reverse/mirror ping-pong with time-mirrored easing. Requires mode 'replace'.",
                        "properties": [
                            "count": ["type": "integer", "description": "Total cycles including the first (2–50)."],
                            "type": ["type": "string", "enum": ["loop", "reverse", "mirror"]],
                            "gapFrames": ["type": "integer", "description": "Rest frames between cycles (default 0)."],
                        ],
                        "required": ["count", "type"],
                    ],
                    "tracks": [
                        "type": "object",
                        "description": "Animate several properties at once: {property: keyframe rows}, keys from volumeDb, opacity, rotation, position, scale, crop. An empty array clears that property's track. Mutually exclusive with property/keyframes. \(keyframeRowShapes)",
                        "additionalProperties": ["type": "array", "items": ["type": "array"]],
                    ],
                    "property": [
                        "type": "string",
                        "enum": ["volumeDb", "opacity", "rotation", "position", "scale", "crop"],
                        "description": "Single-track form: which property's keyframe track to set.",
                    ],
                    "keyframes": [
                        "type": "array",
                        "description": "Single-track form: replacement keyframe rows for 'property'. Empty array clears the track. \(keyframeRowShapes)",
                        "items": ["type": "array"],
                    ],
                ]
            )
        ),
        AgentTool(
            name: .trimClips,
            description: "Trim one clip by dragging an edge or sliding its source range — the three edits a timeline offers that set_clip_properties' absolute trims can't express.\n\nmode:\n• normal (default) — moves the edge and leaves the surrounding clips alone, so trimming a right edge shorter opens a gap.\n• ripple — moves the edge and shifts everything after it on that track and on sync-locked tracks, so the cut closes up with no gap. This is how you tighten or extend a scene without re-positioning every later clip by hand.\n• slip — keeps the clip's position and length and slides WHICH part of the source plays (needs unused head/tail material). Use it to re-frame a take that's timed right but starts on the wrong moment. Don't pass 'edge' for a slip.\n\ndeltaFrames is in timeline frames and always signed by direction: positive moves the edge (or the source window) to the RIGHT, negative to the LEFT. So a right edge with +30 makes the clip 30 frames longer; a left edge with +30 makes it start 30 frames later (30 frames shorter).\n\nEdits are clamped to available source material, to a 1-frame minimum length, and to room on sync-locked tracks; the receipt says exactly how many frames were applied and notes any clamping. Linked audio follows by default (propagateToLinked). Multicam clips are refused — their timing is owned by the group. Nothing to change returns a no-op receipt instead of a fake success.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "The clip to trim (from get_timeline)."],
                    "mode": [
                        "type": "string",
                        "enum": ["normal", "ripple", "slip"],
                        "description": "Default 'normal'. 'ripple' closes/opens the gap by shifting later clips; 'slip' slides the source range inside a fixed slot.",
                    ],
                    "edge": [
                        "type": "string",
                        "enum": ["left", "right"],
                        "description": "Which edge to move. Required for normal/ripple, must be omitted for slip.",
                    ],
                    "deltaFrames": ["type": "integer", "description": "Signed timeline frames; positive moves right, negative left. Must not be 0."],
                    "propagateToLinked": ["type": "boolean", "description": "Default true — linked audio/video trim together, as in the timeline UI."],
                ],
                required: ["clipId", "deltaFrames"]
            )
        ),
        AgentTool(
            name: .duplicateClips,
            description: "Copy existing clips to new positions, keeping everything about them — trims, speed, volume, fades, transform, crop, effects, grade, and keyframes. This is the tool for repeating a treated clip (a stinger on every beat, a lower third on each speaker, a B-roll insert reused later); add_clips only places raw media and would lose all of that.\n\nEach placement is {clipId, toFrame, toTrack?}; toTrack defaults to the clip's own track. Copies OVERWRITE what they land on, exactly like add_clips — check the gaps in get_timeline (or insert with insert_clips first) if you need to keep what's there. Linked audio comes along at the same offset unless includeLinked is false. Copies are independent: they get new ids (returned as newClipIds) and never rejoin the original's multicam group. One undoable action for the whole batch.",
            inputSchema: objectSchema(
                properties: [
                    "placements": [
                        "type": "array",
                        "description": "Where each copy lands. Validated up front; one bad entry rejects the whole call.",
                        "items": objectSchema(
                            properties: [
                                "clipId": ["type": "string", "description": "Clip to copy."],
                                "toFrame": ["type": "integer", "description": "Project frame where the copy starts."],
                                "toTrack": ["type": "integer", "description": "Optional destination track index; defaults to the source clip's track."],
                            ],
                            required: ["clipId", "toFrame"]
                        ),
                    ],
                    "includeLinked": ["type": "boolean", "description": "Default true — a video clip's linked audio is copied at the same offset."],
                ],
                required: ["placements"]
            )
        ),
        AgentTool(
            name: .copyAttributes,
            description: "Paste one clip's look onto other clips — the 'make these match' tool. Copies only the attributes you name; timing, media, track, and position are never touched.\n\nattributes defaults to the full look: transform, crop, opacity, volume, fades, edges, effects, color, keyframes, blendMode. Pass a subset to be surgical (e.g. ['color'] to spread a grade, ['keyframes'] to reuse an animation, ['transform','crop'] to repeat a framing). 'textStyle' is opt-in and needs text clips on both sides. Attribute groups: transform (position/scale/rotation/flip), crop, opacity (static), volume (static), fades (lengths + interpolation, clamped to each target's length), edges (rounding + softness), effects (non-color stack), color (the grade), keyframes (all six animation tracks, trimmed to each target's length), blendMode, textStyle (style + fill mode + text animation).\n\nUse this instead of re-sending the same apply_color/apply_effect/set_keyframes payload per clip: it's one undoable action and it can't drift between clips. The source clip is skipped if it appears in toClipIds.",
            inputSchema: objectSchema(
                properties: [
                    "fromClipId": ["type": "string", "description": "The clip to copy from."],
                    "toClipIds": ["type": "array", "items": ["type": "string"], "description": "Clips that receive the attributes."],
                    "attributes": [
                        "type": "array",
                        "items": ["type": "string", "enum": copyableClipAttributes],
                        "description": "Which attribute groups to copy. Omit for the full look (everything except textStyle).",
                    ],
                ],
                required: ["fromClipId", "toClipIds"]
            )
        ),
        AgentTool(
            name: .linkClips,
            description: "Links clips so they move, trim, and slip together, or unlinks them so they can be edited apart. Imported video and its audio are linked from the start.\n\nUnlink is what makes a J/L-cut possible: unlink the pair, then move or trim the audio past the picture cut so sound leads or lags the image. Link is for binding elements that should travel as one — a title with its background bar, music with the montage it was cut to.\n\naction 'unlink' always covers the whole link group of every id you pass (reported in the receipt), so you never end up with half a group linked. 'link' needs at least two clips and refuses multicam clips, whose sync is owned by their group.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clips to link, or any member(s) of the groups to unlink."],
                    "action": ["type": "string", "enum": ["link", "unlink"], "description": "'link' binds them into one group; 'unlink' frees the whole group."],
                ],
                required: ["clipIds", "action"]
            )
        ),
        AgentTool(
            name: .manageNest,
            description: "Packs clips into a nested timeline (a compound clip) or unpacks one back onto the timeline.\n\nNesting turns a run of clips into ONE clip you can move, trim, grade, fade, animate, and reuse as a unit — the way to treat a built sequence (an intro, a montage, a multi-layer composite) as a single element without re-doing the arrangement. The clips leave the timeline and live in a new child timeline; linked video/audio carrier clips take their place at the same frames. Edit the contents later with set_active_timeline on the returned timelineId — changes there show up in every carrier.\n\ndecompose does the reverse for one nest clip: the child's clips are laid back out in place. Group-level looks applied to the carrier (its opacity, crop, effects, fades, keyframes) have no per-clip equivalent and are dropped, so decompose after grading a nest loses that grade — undo restores it.\n\nCaption clips and multicam clips are refused; both depend on staying on the top-level timeline.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clips to pack into a new nested timeline. Mutually exclusive with 'decompose'."],
                    "decompose": ["type": "string", "description": "Id of a nest clip (mediaType 'sequence') to unpack in place. Mutually exclusive with 'clipIds'."],
                ]
            )
        ),
        AgentTool(
            name: .swapClipMedia,
            description: "Points existing clips at different source media while keeping every edit decision — position, length, trims, speed, volume, fades, transform, crop, effects, grade, and keyframes all stay. Use it to swap a take for a better one, replace a placeholder or generated clip with the final asset, or push a re-render through a composite that's already built.\n\nThe replacement must be the same media kind as the clip (video for video, audio for audio, image for image). Trims are kept by default, so a shorter replacement can leave the tail reading empty — the receipt warns when that happens; pass resetTrim:true to start the clip at the new source's first frame instead. A clip's linked partner sharing the same media is repointed with it. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clips whose source media should change."],
                    "mediaRef": ["type": "string", "description": "Replacement media asset id from get_media."],
                    "resetTrim": ["type": "boolean", "description": "Default false (keep trims). true starts the clip at the new source's first frame."],
                ],
                required: ["clipIds", "mediaRef"]
            )
        ),
        AgentTool(
            name: .relinkMedia,
            description: "Reconnects offline media — assets whose file moved, was renamed, or lives on a volume that wasn't mounted. get_media marks these; until they're relinked, they render black/silent and export incomplete.\n\nTwo modes: 'mediaRef'+'filePath' repoints one asset at an exact file, or 'searchFolder' walks a folder recursively and matches every offline asset by filename (the bulk fix after moving a footage folder). The replacement must be the same media kind.\n\nThis edits the project's media library, NOT the timeline: clips, edits, and effects are untouched, and it is NOT undoable. To point a clip at DIFFERENT footage on purpose, use swap_clip_media.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Offline asset id from get_media. Use with filePath."],
                    "filePath": ["type": "string", "description": "Absolute path (~ allowed) of the relocated file."],
                    "searchFolder": ["type": "string", "description": "Folder to scan recursively, matching offline assets by filename. Mutually exclusive with mediaRef/filePath."],
                ]
            )
        ),
        AgentTool(
            name: .cutoutSubject,
            description: "Cuts the subject out of a clip — the person (or the salient foreground object) stays, everything else becomes transparent so lower tracks show through. No green screen needed; the mask comes from on-device segmentation, per frame, and follows the subject as it moves.\n\nThis is the entry point for compositing a shot: cut the subject out, put something else behind them, then animate. Pass 'background' and the tool also drops that media on a new track below, spanning the same frames, in the SAME undoable action — one call for the whole 'replace the background' move. Without 'background', whatever already sits on lower tracks shows through.\n\nAfter cutting out, treat the clip like any other layer:\n• set_keyframes position/scale/rotation to push in, drift, or parallax the subject against the new background\n• apply_effect with animated params (blur, glow, grain, vignette) for the cinematic pass — blur the background clip, not the subject, to fake depth of field\n• copy_attributes to give every shot in the sequence the same treatment\n\nquality trades speed for accuracy: 'fast' and 'balanced' (default) use people segmentation and stay editable in real time; 'subject' uses the heavy any-object model — much better edges on non-people, but far too slow for playback, so switch to it right before export. feather softens the cut edge (0–1), expand grows (+) or shrinks (−) the mask to fix haloing or clipped hair. keep:'background' inverts the whole thing: the subject is removed and the background survives.\n\nFrames where the model finds nothing are left untouched rather than turning transparent, so a missed detection never blanks the shot — check the result with inspect_timeline. Pass remove:true to strip the key again. The key is a normal effect ('key.subject') in the clip's stack, so apply_effect can animate feather/expand afterwards.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Video or image clips to cut the subject out of."],
                    "quality": [
                        "type": "string",
                        "enum": ["fast", "balanced", "subject"],
                        "description": "Default 'balanced'. 'fast'/'balanced' = people, real-time. 'subject' = any foreground object, high quality, too slow for playback.",
                    ],
                    "feather": ["type": "number", "description": "Edge softness 0–1 (default 0.15). Raise to blend a hard cut into the new background."],
                    "expand": ["type": "number", "description": "Mask grow (+) or shrink (−), −1 to 1. Positive rescues clipped hair; negative removes a background halo."],
                    "keep": [
                        "type": "string",
                        "enum": ["subject", "background"],
                        "description": "Default 'subject'. 'background' inverts the mask — the subject is cut OUT of the shot instead.",
                    ],
                    "background": [
                        "type": "object",
                        "description": "Optional background placed on a new track below, spanning the same frames. Exactly one of mediaRef or colorHex.",
                        "properties": [
                            "mediaRef": ["type": "string", "description": "Video or image asset id from get_media (or from generate_image/generate_video)."],
                            "colorHex": ["type": "string", "description": "Solid color plate, e.g. '#101014'. Needs a saved project."],
                        ],
                    ],
                    "remove": ["type": "boolean", "description": "true strips the subject key from the clips again. Ignores the other parameters."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .applyLayout,
            description: "Arrange multiple clips into a common multi-video layout (split screen, picture-in-picture, grid) in one undoable action — the fast path for composing several videos in one frame. Use this instead of hand-setting transforms and screenshot-checking alignment with inspect_timeline.\n\nYou pick a named layout and assign a clip to each of its slots; the tool computes every transform and crop so each clip FILLS its region edge-to-edge WITHOUT stretching — the source is cropped to the slot's shape (cover), like a layout template the videos are dropped into. Pass fit='fit' to letterbox the whole source inside its slot instead (no crop, may leave bars) — use only when the full frame must stay visible (e.g. a screen recording).\n\nThe crop is centered by default. When that chops off something important (a face cropped at the forehead, a subject off to one side), bias which part survives: 'anchor' is a coarse shortcut ('top' keeps the top, etc.), while anchorX/anchorY (0–1) give continuous control for in-between framing — e.g. anchorY 0.35 moves the crop only slightly toward the top, not all the way. To nudge framing after the fact, call apply_layout again with adjusted anchorX/anchorY (clipIds mode re-crops in place).\n\nTwo modes (don't mix across slots):\n• Place new clips: give each slot a 'mediaRef' (from get_media) plus top-level startFrame (default 0) and endFrame. Creates one stacked video track per slot at that time range; for PIP the inset is placed on top automatically. Video clips bring their linked audio.\n• Re-layout existing clips: give each slot 'clipIds' — one or more existing clips, all framed into that slot (handy when a track holds several sequential takes). Only transforms/crop change — timing and tracks are untouched (so existing track order decides stacking).\n\nEvery slot of the chosen layout must be filled. Layouts and their slot names:\n  • full — main\n  • side_by_side — left, right\n  • top_bottom — top, bottom\n  • pip_bottom_right / pip_bottom_left / pip_top_right / pip_top_left — main, inset\n  • grid_2x2 / grid_3x3 / grid_4x4 — equal cells named rNcN, counting from the TOP-LEFT: row 1 is the top row, column 1 is the left column. So r1c1 is top-left, a 3x3's middle is r2c2, and a 3x3's bottom-right is r3c3\n  • main_sidebar — main (70%), sidebar (30%)\n  • three_up — left, center, right",
            inputSchema: objectSchema(
                properties: [
                    "layout": [
                        "type": "string",
                        "enum": VideoLayout.allCases.map(\.rawValue),
                        "description": "Which layout template to apply.",
                    ],
                    "slots": [
                        "type": "array",
                        "description": "One entry per slot of the chosen layout. Each entry names a 'slot' and gives exactly one of 'mediaRef' (place a new clip) or 'clipIds' (re-layout existing clip(s) into that slot). Don't mix placement (mediaRef) with re-layout (clipIds) across slots.",
                        "items": objectSchema(
                            properties: [
                                "slot": ["type": "string", "description": "Slot name for the chosen layout. Slots per layout — full: main; side_by_side: left, right; top_bottom: top, bottom; pip_*: main, inset; grid_2x2/3x3/4x4: rNcN counted from the top-left (r1c1 is top-left, r2c2 a 3x3's center); main_sidebar: main, sidebar; three_up: left, center, right. Every slot of the layout must be filled."],
                                "mediaRef": ["type": "string", "description": "Asset ID from get_media to place into this slot. Use this OR clipIds."],
                                "clipIds": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                    "description": "Existing clip(s) to frame into this slot — every listed clip gets this slot's transform/crop (pass one id for a single clip, or several when a track holds sequential takes). Use this OR mediaRef. Clips sharing a slot may sit on the same track; clips in DIFFERENT slots still must not overlap on one track.",
                                ],
                                "anchor": [
                                    "type": "string",
                                    "enum": ["center", "top", "bottom", "left", "right", "top_left", "top_right", "bottom_left", "bottom_right"],
                                    "description": "Coarse shortcut for which part of the source to keep when cover-cropping (default center). For in-between framing use anchorX/anchorY instead — the named values are just shortcuts for them.",
                                ],
                                "anchorX": ["type": "number", "description": "Fine horizontal framing, 0–1: 0 keeps the left edge, 0.5 centers (default), 1 keeps the right. Only affects slots cropped horizontally. Overrides anchor's x."],
                                "anchorY": ["type": "number", "description": "Fine vertical framing, 0–1: 0 keeps the top (e.g. a forehead), 0.5 centers (default), 1 keeps the bottom. Nudge by small amounts (e.g. 0.35) to move the crop gradually. Only affects slots cropped vertically. Overrides anchor's y."],
                            ],
                            required: ["slot"]
                        ),
                    ],
                    "startFrame": ["type": "integer", "description": "Placement mode only (mediaRef slots). Project frame where the layout begins. Default 0."],
                    "endFrame": ["type": "integer", "description": "Placement mode only (mediaRef slots). The placed clips occupy [startFrame, endFrame). Required when placing new clips."],
                    "fit": [
                        "type": "string",
                        "enum": [LayoutFit.fill.rawValue, LayoutFit.fit.rawValue],
                        "description": "How each clip fills its slot. 'fill' (default) covers the slot and center-crops the source (no stretch). 'fit' letterboxes the whole source inside the slot.",
                    ],
                ],
                required: ["layout", "slots"]
            )
        ),
        AgentTool(
            name: .syncClips,
            description: "Align one or more clips to a reference clip by shifting targets on the timeline — use for dual-system sound (camera + external audio) or multicam. Default mode 'auto' aligns by embedded source timecode when both files carry one (exact, confidence 1.0), falling back to audio cross-correlation otherwise (seeded by capture dates when present); force a method with mode. referenceClipId stays put unless a target would land before frame 0, in which case the whole group shifts right together (reported as shiftedFrames). Returns offsetFrames, confidence (0–1), and method (timecode|audio) per target; refuses weak audio matches. Refused on multicam clips — a group's members are already aligned by its sync maps (manage_multicam).",
            inputSchema: objectSchema(
                properties: [
                    "referenceClipId": ["type": "string", "description": "Clip the others align to. Stays put."],
                    "targetClipId": ["type": "string", "description": "Single clip to align. Use targetClipIds for several."],
                    "targetClipIds": ["type": "array", "items": ["type": "string"], "description": "Clips to align with the reference."],
                    "mode": ["type": "string", "enum": ["auto", "audio", "timecode"], "description": "auto (default): timecode when available, else audio. audio/timecode force that method."],
                    "searchWindowSeconds": ["type": "number", "description": "Optional max ± offset to search in seconds. Omit to search the full feasible overlap."],
                    "minConfidence": ["type": "number", "description": "Minimum audio correlation confidence 0–1 (default 0.5)."],
                ],
                required: ["referenceClipId"]
            )
        ),
        AgentTool(
            name: .manageMulticam,
            description: "Create or ungroup a multicam group. create syncs session media into ordinary stamped timeline clips: one program video track, one audio track per mic, and angle switches through change_cam. Use member kind angle for scratch-camera audio, mic for program audio, and both for a camera whose audio should play. Pin offsetSeconds when correlation cannot align a member. ungroup strips stamps and leaves clips in place.",
            inputSchema: objectSchema(
                properties: [
                    "create": objectSchema(
                        properties: [
                            "members": [
                                "type": "array",
                                "description": "Session source files, at least two.",
                                "items": objectSchema(
                                    properties: [
                                        "mediaRef": ["type": "string", "description": "Media asset id from get_media."],
                                        "kind": ["type": "string", "enum": ["angle", "mic", "both"], "description": "angle = camera scratch audio, mic = audio in the mix, both = camera plus program audio."],
                                        "angleLabel": ["type": "string", "description": "Handle used by change_cam. Default: file name."],
                                        "offsetSeconds": ["type": "number", "description": "Pin this member's group-clock offset instead of correlating."],
                                    ],
                                    required: ["mediaRef", "kind"]
                                ),
                            ],
                            "name": ["type": "string", "description": "Group name. Default: Multicam N."],
                            "master": ["type": "string", "description": "angleLabel or mediaRef whose audio clock defines the group. Default: first mic/both member."],
                            "startFrame": ["type": "integer", "description": "Timeline frame to place the group. Default: timeline end."],
                            "searchWindowSeconds": ["type": "number", "description": "Max ± audio sync search window, seconds (default 240)."],
                        ],
                        required: ["members"],
                        description: "Build a new multicam group from session media. Pass exactly one of create or ungroup."
                    ),
                    "ungroup": objectSchema(
                        properties: [
                            "groupId": ["type": "string", "description": "Group to dissolve; its clips stay put, unstamped."],
                        ],
                        required: ["groupId"],
                        description: "Dissolve an existing multicam group. Pass exactly one of create or ungroup."
                    ),
                ]
            )
        ),
        AgentTool(
            name: .changeCam,
            description: "Switch a multicam group's camera angle over timeline frame ranges, full-frame or in a multi-angle layout. Batched entries are one undo step. Ranges where an angle was not recording clamp or skip. Returns switched count, optional clamps/skips/overlayClipIds, and program rows over the touched span.\n\nEach entry is EITHER {range, angle} — full-frame switch — or {range, layout, angles} — PiP/split/grid: angles fill the layout's slots in order (first = the full-frame program slot; fewer angles than slots leaves cells empty), extra angles land as synced overlay clips above the program. A later full-frame entry over the same range clears the layout. Overlay clips are ordinary group clips — restyle with set_clip_properties/apply_layout, remove with remove_clips.",
            inputSchema: objectSchema(
                properties: [
                    "groupId": ["type": "string", "description": "The multicam group (from manage_multicam create or get_timeline's multicamGroups). Or pass clipId."],
                    "clipId": ["type": "string", "description": "Any clip of the group on the active timeline."],
                    "entries": [
                        "type": "array",
                        "description": "Switches to apply, in order. Later entries win on overlap.",
                        "items": objectSchema(
                            properties: [
                                "range": ["type": "array", "items": ["type": "integer"], "description": "[startFrame, endFrame) in timeline frames."],
                                "angle": ["type": "string", "description": "angleLabel to show full-frame. Omit when using layout."],
                                "layout": [
                                    "type": "string",
                                    "enum": VideoLayout.allCases.filter { $0 != .full }.map(\.rawValue),
                                    "description": "Multi-angle layout. Grid cells are rNcN counting from the top-left (r1c1 is top-left, row 1 is the top row); shaped layouts name slots by role.",
                                ],
                                "angles": ["type": "array", "items": ["type": "string"], "description": "angleLabels in slot order for layout; [0] is the program slot."],
                            ],
                            required: ["range"]
                        ),
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .getMulticam,
            description: "Read a multicam group: members (angleLabel, kind, offsetSeconds, confidence, which is master), the current program cut as run-length [angle, startFrame, endFrame) rows in timeline frames, and the track indexes the group occupies. Use it to learn angle labels before change_cam, or to review the cut as one program instead of piecing it together from get_timeline's clips. Window long timelines with startFrame/endFrame.",
            inputSchema: objectSchema(
                properties: [
                    "groupId": ["type": "string", "description": "The multicam group id. Or pass clipId."],
                    "clipId": ["type": "string", "description": "Any clip of the group on the active timeline."],
                    "startFrame": ["type": "integer", "description": "Optional window start for program rows."],
                    "endFrame": ["type": "integer", "description": "Optional window end (exclusive)."],
                ]
            )
        ),
        AgentTool(
            name: .undo,
            description: "Reverts the latest action from the editor's shared undo history, whether the user or agent made it. Call only when that latest action should be reversed. For example, verify a cut with get_transcript, then undo if it overshot and retry with corrected ranges. After undoing, ids and frames returned by the reverted action may be invalid; re-read with get_timeline or get_transcript before editing again. Takes no arguments.",
            inputSchema: objectSchema()
        ),
        AgentTool(
            name: .getTranscript,
            description: "Returns the spoken transcript of the CURRENT timeline in project frames — the post-edit caption track in one call. Unlike inspect_media (which transcribes one source asset in isolation, in source seconds), this walks every audio/video clip on the timeline, maps each word through that clip's trim/speed/position, and concatenates in timeline order. Deleted ranges are gone by construction, so after cuts this always reflects what's actually audible — no stale results, no per-clip frame math. The app chooses cloud only when the signed-in account has enough credits for the uncached request; otherwise it uses local transcription and reports the resolved transcriptionSource in the response.\n\nReturns clips in timeline order, each with its words as compact [index, text, startFrame] rows (a word runs to the next word's start; the last word to its clip's end). Speakers, when identified, arrive as run-length turns: speakers = [[firstWordIndex, name], ...]. The index is a stable, global, 0-based position in timeline order; pass it straight to remove_words to cut that word (the intuitive path for text-based editing). Indices stay global even when scoped with clipId or paged with a window. Capped at 10000 words; page with startFrame/endFrame using nextStartFrame.\n\nFor comprehension rather than cutting — summarizing, finding a topic, take selection on long media — pass granularity='segments': sentence rows [firstWordIndex, text, start, end] at a fraction of the tokens, whose firstWordIndex jumps you back into word mode for the cut window.\n\nUse for transcript-driven edits (filler-word / dead-air removal, locating a quote, take selection) and to verify what remains after cutting. To cut, prefer remove_words (give it the indices); drop to ripple_delete_ranges only for non-word-aligned spans.",
            inputSchema: objectSchema(
                properties: [
                    "startFrame": ["type": "integer", "description": "Optional. Only return words ending after this project frame. Use with the returned nextStartFrame to page a long timeline."],
                    "endFrame": ["type": "integer", "description": "Optional. Only return words starting before this project frame."],
                    "clipId": ["type": "string", "description": "Scope the transcript to a single clip — returns only what that clip says, in project frames. Answers \"what's in clip X?\" without scanning the whole timeline."],
                    "granularity": ["type": "string", "enum": ["words", "segments"], "description": "words (default) for cutting with remove_words; segments for cheap sentence-level reading — rows carry firstWordIndex to drill back into words."],
                    "language": ["type": "string", "description": "Optional BCP-47 speech language. Applies to local only; cloud auto-detects."],
                ]
            )
        ),
        AgentTool(
            name: .removeWords,
            description: "Cut speech by the word, Descript-style — the primary tool for text-based editing (filler words, flubbed sentences, dropped retakes, tightening a ramble). Pass words for precise get_transcript indices/ranges, or matches for exact filler tokens like \"um\" and \"uh\". This resolves them to frames, removes the surrounding pause so survivors don't end up double-spaced, merges adjacent removals, cuts linked A/V partners, and closes the gaps. You never deal in frame numbers — that's the whole point versus ripple_delete_ranges.\n\nWorkflow: call get_transcript, read it as prose, then pass the indices of the words to drop. Omit language by default; remove_words reuses the previous get_transcript source so cloud/local word indices stay aligned. Words across multiple clips on ONE track are handled in a single undoable action, and any linked A/V partner (e.g. the video paired with this audio) is cut automatically. Edit one track at a time: if your indices span multiple unlinked tracks (e.g. two separate mics), the call is refused — cut each track in its own call, or link the tracks into one unit first. After it runs, indices have shifted — re-read get_transcript before another remove_words.\n\nWhen to use which: words for selective edits after reading the transcript; matches for removing every exact filler token; ripple_delete_ranges only for spans that aren't word-aligned. Verify reworded retakes and sub-frame seam fragments against the word list, not a summary.",
            inputSchema: objectSchema(
                properties: [
                    "words": [
                        "type": "array",
                        "description": "Words to remove, by get_transcript index. Each element is either a single index (e.g. 42) or an inclusive [startIndex, endIndex] span (e.g. [12, 18]). Mutually exclusive with matches. Re-read after any edit.",
                        "items": ["type": ["integer", "array"]],
                    ],
                    "matches": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Exact single-word tokens to remove everywhere, case-insensitive with surrounding punctuation ignored, e.g. [\"um\", \"uh\", \"hmm\"]. Mutually exclusive with words. Avoid broad words like \"like\" unless the user explicitly wants every occurrence removed.",
                    ],
                    "cutAggressiveness": [
                        "type": "string",
                        "enum": ["tight", "balanced", "loose"],
                        "description": "How much silence to leave between the words on either side of a cut. 'tight' butts them close (snappy, can feel clipped), 'balanced' (default) keeps a natural beat, 'loose' leaves more breathing room. The removed words' own frames always go regardless.",
                    ],
                    "language": ["type": "string", "description": "Optional BCP-47 speech language for local transcription. Omit to reuse the previous get_transcript language."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .removeSilence,
            description: "Remove dead air — quiet, speech-free sections — from the timeline's audio, ripple-closing the gaps. Sections come from on-device speech detection (the same spans marked red on waveforms): non-speech runs whose level sits well below the recording's own speech level, so music beds and loud ambience are never cut, and speech-boundary slop keeps the cuts from feeling clipped. Cuts linked A/V partners and honors sync lock; the whole pass is one undoable action.\n\nUse this to tighten pacing (long pauses, dead space between takes) before or instead of word-level edits: remove_silence handles pauses, remove_words handles fillers and flubbed lines. No transcript needed. If it reports no dead air, speech analysis may still be running in the background — wait a moment and retry. Takes no arguments.",
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        AgentTool(
            name: .detectBeats,
            description: "Detect musical beats and downbeats in a media asset's audio, on-device. Returns beats and downbeats in SOURCE seconds (multiply by fps for frame values, same convention as search_media hits) plus estimated bpm. Downbeats mark bar starts — cut on downbeats for edits that land musically; beats are fine for faster montage rhythms.\n\nUse for beat-synced editing: snapping cuts to a music bed, building montages where clip boundaries hit the beat, or timing text/caption entrances to the bar. To place a cut at a beat B on a clip, the timeline frame is startFrame + (B × fps − trimStartFrame) / speed. Works on music; speech or ambience returns few or no beats. Runs locally — no subscription needed.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "Audio or video asset id from get_media."],
                    "startSeconds": ["type": "number", "description": "Optional. Return only beats at or after this source-media second. The whole file is analyzed once and cached; windowing trims the response, not the work."],
                    "endSeconds": ["type": "number", "description": "Optional. Return only beats at or before this source-media second."],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .addTexts,
            description: "Adds text clips as timeline layers. Omit trackIndex on every entry to create one new top video track; otherwise set trackIndex on every entry. Transform is normalized text-box center/size; center-only auto-fits, all four fields override the box. Use the nested style object for typography, outline, shadow, and background. fillMode 'footage' stencils layers below through the letter shapes. Use add_captions for spoken audio captions. Unknown fields are rejected.",
            inputSchema: objectSchema(
                properties: [
                    "entries": [
                        "type": "array",
                        "description": "Text clips to add.",
                        "items": [
                            "type": "object",
                            "properties": mergedProperties([
                                "trackIndex": ["type": "integer", "description": "Existing non-audio track. Omit on all entries to create a new top track."],
                                "startFrame": ["type": "integer", "description": "Timeline start frame."],
                                "endFrame": ["type": "integer", "description": "Occupy timeline frames [startFrame, endFrame) — copy a clip's frames pair to title exactly that span."],
                                "content": ["type": "string", "description": "Text. Supports \\n."],
                                "transform": [
                                    "type": "object",
                                    "description": "Text box. Omit for centered auto-fit; rotation alone rotates an auto-fit box; center only auto-fits size; all four override.",
                                    "properties": textBoxTransformProperties(),
                                ],
                            ], textStyleProperties(detailed: false), [
                                "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Animation preset; off clears."],
                                "highlightColor": ["type": "string", "description": "Active-word hex."],
                                "fillMode": ["type": "string", "enum": ["color", "footage"], "description": "color = solid typography (default). footage = stencil layers below through the letter shapes."],
                            ]),
                            "required": ["startFrame", "endFrame", "content"],
                        ],
                    ],
                ],
                required: ["entries"]
            )
        ),
        AgentTool(
            name: .updateText,
            description: "Updates text clips or a captionGroupId. The nested style object is a partial patch: omitted values stay unchanged. Use it for typography, color, outline, shadow, and background. fillMode 'footage' stencils layers below through the glyphs. Content and layout-affecting style changes auto-fit the box unless transform includes box geometry; rotation alone keeps auto-fit. Static rotation uses clockwise degrees and clears rotation keyframes. Unknown fields are rejected.",
            inputSchema: objectSchema(
                properties: mergedProperties([
                    "clipIds": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Text clip IDs. Optional if captionGroupId is given.",
                    ],
                    "captionGroupId": ["type": "string", "description": "Caption group id from get_timeline."],
                    "content": ["type": "string", "description": "Replacement text. Supports \\n."],
                    "transform": [
                        "type": "object",
                        "description": "Partial text-box transform; omitted fields keep current values.",
                        "properties": textBoxTransformProperties(),
                    ],
                ], textStyleProperties(detailed: true), [
                    "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Animation preset; off clears."],
                    "highlightColor": ["type": "string", "description": "Active-word hex."],
                    "fillMode": ["type": "string", "enum": ["color", "footage"], "description": "color = solid typography. footage = stencil layers below through the letter shapes."],
                ]),
                required: []
            )
        ),
        AgentTool(
            name: .addCaptions,
            description: "Transcribes the timeline's spoken audio and creates styled caption text clips on their own track — no targeting needed; it finds the spoken content itself. The app uses cloud only when the signed-in account has enough credits for the uncached request; otherwise it uses local transcription. Cloud auto-detects language. Per-word animations are timed from the transcript. Returns the caption group summary (captionGroupId, clipCount, frameRange, shared style, textPreview) — restyle it later with update_text and that captionGroupId.",
            inputSchema: objectSchema(
                properties: mergedProperties([
                    "language": ["type": "string", "description": "BCP-47 speech language. Applies to local only; cloud auto-detects."],
                    "transform": [
                        "type": "object",
                        "description": "Caption box position; size is auto-fit per caption.",
                        "properties": [
                            "centerX": ["type": "number", "description": "0-1 horizontal center."],
                            "centerY": ["type": "number", "description": "0-1 vertical center."],
                        ],
                    ],
                    "censorProfanity": ["type": "boolean", "description": "Mask profanity."],
                    "maxWords": ["type": "integer", "description": "Max words per caption."],
                ], textStyleProperties(detailed: false), [
                    "animation": ["type": "string", "enum": TextAnimation.Preset.agentValues, "description": "Caption animation preset."],
                    "highlightColor": ["type": "string", "description": "Active-word hex."],
                ])
            )
        ),
        AgentTool(
            name: .manageMotionScene,
            description: "Author animated motion graphics as React code and render them into the media library as an alpha video clip. Use this for animated titles, lower thirds, kinetic typography, logo reveals, UI/product demos, dashboards, chart animations, and anything that should look like a real app interface moving — especially when combined with a device mockup via apply_layout. Do NOT use it for plain static captions or simple text overlays; add_texts is cheaper and editable in the Inspector.\n\nThe scene is a single TSX module that must `export default` a React component. Animate with Motion (`import { motion } from \"motion/react\"`) — its declarative props (initial/animate/transition, variants, stagger) all render frame-accurately because rendering drives a virtual clock rather than wall time. The full shadcn/ui set is importable (`import { Button } from \"@/components/ui/button\"`, also card, dialog, table, chart, badge, tabs, progress, sidebar, …) plus `lucide-react` icons and any Tailwind utility class including arbitrary values like `w-[347px]`. `PalmierMotion.useSceneTime()` returns seconds and `PalmierMotion.useSceneFrame()` the frame index, for values you must compute per frame such as counters. Give the root element a transparent or explicit background: the render preserves alpha, so anything you do not paint stays see-through over the clips beneath.\n\nThe scene is rendered before it is saved, so a syntax error, a bad import or a component that throws comes back as a tool error and nothing is added to the project. Rendering is deterministic — Math.random and Date are seeded — so the same source always yields the same frames. action='create' returns a mediaRef to place with add_clips; action='update' re-renders in place and every clip already on the timeline picks up the new version. Read a scene back (source plus sampled frames) with inspect_media.\n\nThe 'web' runtime also ships a large prebuilt animation library (remocn): typewriters and kinetic type, animated line-drawn icons, cursors and carets, animated UI (dialogs, menus, toasts, sliders, charts), chat/terminal/product mock flows, WebGL shader backdrops, and film-style transitions. Import them by module, e.g. `import { Typewriter } from \"@/components/remocn/typewriter\"`. Call action='components' FIRST when you plan to use one — it returns the full catalog as module path → exported component names; guessing names fails the render. These components are authored against the Remotion API, which this runtime implements: `import { useCurrentFrame, useVideoConfig, interpolate, spring, Easing, AbsoluteFill, Sequence } from \"remotion\"` works, and `@/lib/remocn-ui` (useTypewriter, easings, springs, color helpers) is importable too. Google-font imports resolve to the system stack instead of downloading.",
            inputSchema: objectSchema(
                properties: [
                    "action": ["type": "string", "enum": ["create", "update", "components"], "description": "'create' adds a new scene to the media library. 'update' replaces an existing one in place and re-renders it. 'components' takes no other parameters and returns the prebuilt remocn animation catalog for the 'web' runtime."],
                    "mediaRef": ["type": "string", "description": "Required for action='update'. The scene asset to replace."],
                    "name": ["type": "string", "description": "Display name in the media library, e.g. 'Pricing Table Reveal'."],
                    "folderId": ["type": "string", "description": "Optional media folder to file the new scene under."],
                    "source": ["type": "string", "description": "The TSX module. Must `export default` a React component. Required for 'create'; on 'update' omit it to keep the current source and only change timing or size."],
                    "runtime": [
                        "type": "string",
                        "enum": ["web", "react-native"],
                        "description": "Which renderer draws the scene. 'web' (default) is React + Motion + shadcn/ui + Tailwind in a browser engine — use it for titles, kinetic type, dashboards and anything that should look like a web UI. 'react-native' renders real React Native views through Yoga and Fabric: import from `react-native` (View, Text, Image, StyleSheet, Animated) instead of DOM elements, style with the `style` prop rather than Tailwind classes, and expect React Native's flexbox defaults (column direction, no CSS cascade). Use it when the scene must mirror a real iOS/Android app's layout and look. Tailwind, shadcn/ui and lucide-react are NOT available in 'react-native'; `PalmierMotion.useSceneTime()` and `useSceneFrame()` work in both.",
                    ],
                    "width": ["type": "integer", "description": "Render width in pixels (16–4096). Defaults to the project width."],
                    "height": ["type": "integer", "description": "Render height in pixels (16–4096). Defaults to the project height."],
                    "fps": ["type": "number", "description": "Frames per second (1–120). Defaults to the project fps. Match the timeline unless the scene needs to be smoother."],
                    "durationInFrames": ["type": "integer", "description": "How many frames to render (1–36000). Defaults to 5 seconds. The last frame is held, so a clip can be extended past the animation as a freeze-frame."],
                ],
                required: ["action"]
            )
        ),
        AgentTool(
            name: .applyColor,
            description: "Author/refine a color grade on video/image clips with named controls — the colorist path, distinct from apply_effect (looks/FX). Returns the clips with their resulting grade as a `color` object — the same object get_timeline shows; pass one back via the `color` parameter to copy a grade between clips (replaces the whole grade). MERGES with the clip's current grade: only the params you pass change, the rest are preserved, so you can nudge one knob at a time (pass reset:true to start from neutral). Applies as live, editable color.* effects; non-color effects untouched. Iterate: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat. Undoable. All knobs optional. Color WHEELS use HUE (0–360°, standard) + AMOUNT per tonal zone — to push shadows teal, set shadowsHue 180 and shadowsAmount ~0.15. CURVES (master + per-channel R/G/B) give precise tone shaping — per-channel curves are tone-selective (e.g. pull the blue curve down in the highlights to tame a bright sky). HUE CURVES do secondary/qualified correction — target a source hue and shift its hue/saturation/lightness (e.g. desaturate greens, warm the skin) without a mask; pair with inspect_color's hueHistogram to find which hues are present. LUT applies a .cube film-look pack on top of the grade.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clip ids from get_timeline."],
                    "reset": ["type": "boolean", "description": "Start from neutral instead of merging onto the clip's current grade. Default false."],
                    "color": ["type": "object", "description": "A complete grade object as read from a clip's `color` key (get_timeline or an apply_color echo). Replaces the target clips' grade — the grade-copy path. Mutually exclusive with reset and individual knobs."],
                    "exposure": ["type": "number", "description": "-3…3 EV. Overall brightness in linear light."],
                    "contrast": ["type": "number", "description": "0.5…1.5 (1 = neutral)."],
                    "saturation": ["type": "number", "description": "0…2 (1 = neutral; <1 mutes)."],
                    "vibrance": ["type": "number", "description": "-1…1 (protects skin tones)."],
                    "temperature": ["type": "number", "description": "2000…11000 K. HIGHER = WARMER, lower = cooler/bluer (6500 = neutral)."],
                    "tint": ["type": "number", "description": "-100…100. Positive = green, negative = magenta."],
                    "highlights": ["type": "number", "description": "-1…1. Recover (<0) or lift (>0) highlights."],
                    "shadows": ["type": "number", "description": "-1…1. Lift (>0) or deepen (<0) shadows."],
                    "blacks": ["type": "number", "description": "-1…1. Black point. Negative deepens, positive lifts (faded look)."],
                    "whites": ["type": "number", "description": "-1…1. White point."],
                    "shadowsHue": ["type": "number", "description": "Shadow color-push hue 0–360° (0 red, 30 orange, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta). Use with shadowsAmount."],
                    "shadowsAmount": ["type": "number", "description": "0…1 strength of the shadow color push (0 = neutral)."],
                    "shadowsLum": ["type": "number", "description": "-0.5…0.5 shadow lift (brightness)."],
                    "midsHue": ["type": "number", "description": "Midtone color-push hue 0–360° (see shadowsHue). Use with midsAmount."],
                    "midsAmount": ["type": "number", "description": "0…1 strength of the midtone color push."],
                    "midsGamma": ["type": "number", "description": "0.5…2 midtone brightness (gamma; 1 = neutral)."],
                    "highsHue": ["type": "number", "description": "Highlight color-push hue 0–360° (see shadowsHue). Use with highsAmount."],
                    "highsAmount": ["type": "number", "description": "0…1 strength of the highlight color push."],
                    "highsGain": ["type": "number", "description": "0.5…1.5 highlight brightness (gain; 1 = neutral)."],
                    "masterCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                    "description": "Luma tone curve as [x,y] control points in 0–1 (input→output), preserves chroma. E.g. [[0,0.06],[1,0.95]] = lifted/faded film toe."],
                    "redCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                 "description": "Red-channel tone curve, [x,y] points 0–1."],
                    "greenCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                   "description": "Green-channel tone curve, [x,y] points 0–1."],
                    "blueCurve": ["type": "array", "items": ["type": "array", "items": ["type": "number"]],
                                  "description": "Blue-channel tone curve, [x,y] points 0–1. Tone-selective: e.g. [[0,0],[0.7,0.7],[1,0.85]] pulls blue only in the highlights (tames a sky) and leaves shadows."],
                    "hueCurves": [
                        "type": "object",
                        "description": "Secondary/qualified correction (Resolve-style Hue-vs-Hue/Sat/Lum). Targets replace any existing hue curve. Selectivity is ~±22° around each target hue.",
                        "properties": [
                            "targets": [
                                "type": "array",
                                "description": "One or more source-hue regions to adjust (e.g. skin at 30, sky at 210).",
                                "items": objectSchema(
                                    properties: [
                                        "targetHue": ["type": "number", "description": "Source hue to act on, 0–360° (0 red, 30 orange/skin, 60 yellow, 120 green, 180 cyan, 210 sky-blue, 240 blue, 300 magenta)."],
                                        "hueShift": ["type": "number", "description": "Rotate that hue by -30…30°."],
                                        "satScale": ["type": "number", "description": "Saturation multiplier for that hue, 0–2 (1 = neutral; 1.3 pops it, 0.6 mutes it, 0 fully desaturates)."],
                                        "lumShift": ["type": "number", "description": "Lightness shift for that hue, -0.5…0.5."],
                                    ],
                                    required: ["targetHue"]
                                ),
                            ],
                        ],
                    ],
                    "lut": [
                        "type": "object",
                        "description": "Apply a .cube 3D LUT (e.g. a film-look pack) on top of the primary grade; replaces any prior LUT. The agent does not author LUT data — pass a real file path.",
                        "properties": [
                            "path": ["type": "string", "description": "Absolute path to a .cube file (~ is expanded). Copied into project storage so it survives saves."],
                            "strength": ["type": "number", "description": "Dry/wet mix 0-1 (default 1)."],
                        ],
                    ],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .applyEffect,
            description: """
            Apply non-color effects (blur, sharpen, stylize, distort, detail, key) to video/image/text clips as a live, \
            editable effect stack — the looks/FX path, distinct from apply_color (grading). MERGES: each effect \
            you pass is added or updated by type; effects you don't mention are left in place. Pass enabled:false \
            to bypass one without removing it, or list its type in `remove` to delete it. Out-of-range params are \
            clamped; params you omit keep their current (or default) value. Effects render in a fixed canonical \
            order regardless of the order you pass them. Undoable. Returns the clips with their resulting \
            effects as [{type, params}] — the same shape this tool accepts, so copying effects between clips \
            is passing a clip's effects array back in.

            ANIMATED PARAMS: a param takes either a number (static) or keyframe rows \
            [[frame, value, interp?], ...] — clip-relative frames and the FULL interp vocabulary of \
            set_keyframes: every named ease (incl. sine/expo families), [x1,y1,x2,y2] beziers, \
            {type: 'spring'|'steps'|'back'|'elastic', …} objects, and split eases {out, in}; \
            default smooth. That's how you ramp a blur on a reveal, \
            pulse a glow to the beat, or ease a vignette in. An empty array clears the animation and keeps \
            the last static value. Values are clamped to the param's range.

            TEXT: effects apply to text clips too. distort.warp bends text (bend arches it, \
            waveAmplitude/waveLength/wavePhase run a wave through it — keyframe wavePhase linearly for a \
            continuous flag wave). Combine animated blur/glow/warp with set_keyframes and the text \
            animation presets for After-Effects-style title reveals.

            IN-SCENE TEXT: to embed text into the shot, combine distort.perspective (tilts the layer \
            plane in 3D — positive tiltX lays it back like writing on the ground, tiltY angles it like \
            a wall, distance controls how aggressive the vanishing is) with key.occlusion, which \
            composites the layer BEHIND the people in the frame: the compositor segments the subject of \
            the tracks below and re-blends it on top, so someone walking past covers the text. \
            key.occlusion works on any overlay (text, image, video); frames with no detected person \
            composite normally. feather/expand tune the occlusion edge like key.subject.

            SUBJECT TRANSITION (transition.subjectReveal): a modern person-portal cut between two \
            shots. Overlap the incoming clip on a track ABOVE the outgoing one, apply this effect to \
            the incoming clip, and keyframe progress [[0,0],[N,1,'linear']] across the overlap: the \
            new shot opens up from inside the outgoing subject's silhouette and grows until it fills \
            the frame. The matte comes from on-device segmentation of the frame below (quality like \
            key.subject: 0 fast / 1 balanced / 2 any-object), feather softens the reveal edge. Frames \
            where no subject is found fall back to a plain dissolve at the same progress, so the \
            transition always completes. progress 0 shows only the outgoing shot, 1 only the incoming.

            SCREEN REPLACEMENT (distort.cornerPin): pins the clip's four corners to four points \
            in CANVAS coordinates (0–1, top-left origin — the same space as set_keyframes position), \
            like After Effects' Corner Pin. This is how you paste an image, video, or nested \
            timeline onto a screen, phone display, sign, poster, or wall inside the shot so it reads \
            as part of the scene. It REPLACES that clip's position/scale/rotation: the whole frame is \
            warped onto the quad, so the transform is ignored while the pin is enabled (corners \
            default to the full canvas). Put the overlay on a track ABOVE the plate.\n\
            Workflow: inspect_timeline at the frame → read the surface's four corners off the \
            rendered image → apply_effect with topLeftX/topLeftY/topRightX/topRightY/bottomRightX/\
            bottomRightY/bottomLeftX/bottomLeftY → inspect_timeline again to check the fit and \
            nudge. If the surface MOVES, keyframe all eight params on the same frames (sample the \
            corners every few frames from inspect_timeline) and use 'linear' interp between tracking \
            keyframes — eased corners read as a wobble against the plate. Add key.occlusion to the \
            pinned clip when a hand or person passes in front of the surface, and blur.gaussian or \
            color.* (via apply_color) to match the plate's softness and grade.

            MESH WARP (distort.meshWarp): the bendable version of the corner pin — a 3×3 grid of \
            points (corners, edge midpoints, center) in the same canvas coordinates, and the layer \
            bends smoothly through all nine instead of staying a flat perspective plane. Use it to \
            wrap a label or overlay onto a curved surface (bottle, curved monitor, arm), bulge or \
            pinch a layer, or bend text along a shape. It also REPLACES the clip's transform. With \
            every point at its default the mapping is the identity; corners place the layer, moving \
            midpoints/center is what bends it. Params: {topLeft,topCenter,topRight,midLeft,center,\
            midRight,bottomLeft,bottomCenter,bottomRight}{X,Y} (defaults are the point's canvas \
            position, e.g. topCenter 0.5/0, center 0.5/0.5). Keyframe like the corner pin. Corner \
            pin wins when both are on one clip — use one per clip.

            Available effects — type: param (range, default):
            \(Self.effectCatalog())
            """,
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Clip ids from get_timeline."],
                    "effects": [
                        "type": "array",
                        "description": "Effects to add or update on the clips.",
                        "items": objectSchema(
                            properties: [
                                "type": ["type": "string", "enum": nonColorEffectIds(), "description": "Effect type id."],
                                "params": ["type": "object", "description": "Param values keyed by name. Each value is a number (static) or keyframe rows [[frame, value, interp?], ...] for an animated param; empty array clears the animation. Out-of-range values are clamped; omitted params keep their current/default value. Valid params per effect — type: param (range, default):\n\(effectCatalog())"],
                                "enabled": ["type": "boolean", "description": "Default true. false bypasses the effect without removing it."],
                            ],
                            required: ["type"]
                        ),
                    ],
                    "remove": ["type": "array", "items": ["type": "string"], "description": "Effect type ids to remove from the clips."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .inspectColor,
            description: "Measure color scopes of a timeline clip's current graded look (clipId) OR a raw media asset (mediaRef) — black/white points, % clipping, mean & per-channel levels, shadow/mid/highlight color tilt, saturation, warm-cool / green-magenta balance, and a saturation-weighted hueHistogram (12 bins of 30° from 0°/red — shows which hues are present, e.g. an orange cluster = skin, a cyan/blue cluster = sky) — and return the rendered frame too. Use this to grade by the numbers instead of eyeballing, to find hues to target with apply_color's hueCurves, or to measure footage/references before grading. clipId applies the clip's effects (graded look); mediaRef measures the raw asset. Pass a reference image/video id to also measure it and get the subject−reference GAP plus hints that map onto apply_color knobs. The loop: apply_color → inspect_color(clipId, reference) → read the gap → adjust → repeat until the gap is small.",
            inputSchema: objectSchema(
                properties: [
                    "clipId": ["type": "string", "description": "Timeline clip to measure — returns its current GRADED look (effects applied). Provide this or mediaRef."],
                    "mediaRef": ["type": "string", "description": "Media asset id from get_media to measure RAW (no grade). Provide this or clipId."],
                    "atFrame": ["type": "integer", "description": "Optional project frame to sample a clip. Defaults to the clip's midpoint. Ignored for mediaRef."],
                    "reference": ["type": "string", "description": "Optional image/video asset id from get_media to compare against; returns its scopes + the subject−reference gap."],
                ]
            )
        ),
        AgentTool(
            name: .denoiseAudio,
            description: "Remove background noise from audio clips using an on-device speech-enhancement model (DeepFilterNet3). strength is a dry/wet mix 0-1: 0 leaves the audio untouched, 1 is fully denoised. Full strength can sound thin or over-gated on real-world recordings, so the default is 0.6. The bake runs in the background — the timeline updates automatically when it finishes; no need to poll. Pass enabled:false to turn denoise off. Undoable.",
            inputSchema: objectSchema(
                properties: [
                    "clipIds": ["type": "array", "items": ["type": "string"], "description": "Audio clip ids from get_timeline."],
                    "strength": ["type": "number", "description": "Dry/wet mix, 0–1 (default 0.6). Lower it if voices sound thin or over-compressed."],
                    "enabled": ["type": "boolean", "description": "Default true. false removes the denoise effect from the clips."],
                ],
                required: ["clipIds"]
            )
        ),
        AgentTool(
            name: .listModels,
            description: "Lists AI models with their capabilities (durations, aspect ratios, resolutions, first/last frame support, reference support, voices/category for audio, and configurable settings for upscalers). Models with usesOwnApiKey:true run directly on the user's own provider key (OpenRouter for image/video, ElevenLabs for audio) and are billed there instead of in Palmier credits. Always call before generate_video, generate_transition, generate_image, generate_audio, or upscale_media so the model you pick actually supports the constraints you need. For transitions, pick a video model with supportsFirstFrame and supportsLastFrame. Returns { models, loaded } — if loaded=false the catalog hasn't synced yet (e.g. user not signed in); the models array may be empty even when models exist, so do not conclude no models are available. Retry after the user signs in.",
            inputSchema: objectSchema(
                properties: [
                    "type": ["type": "string", "enum": ["video", "image", "audio", "upscale"], "description": "Filter by type. Omit to list all models."],
                ]
            )
        ),
        AgentTool(
            name: .generateVideo,
            description: "Starts an async AI video generation. Returns a placeholder asset ID immediately; generation runs in the background and the asset becomes usable in add_clips once ready. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Text description of the video to generate. Optional for transforms such as lip sync that do not use a prompt."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID (e.g. 'veo3.1-fast'). Use list_models to see options. Defaults to first available model."],
                    "duration": ["type": "integer", "description": "Duration in seconds. Valid values depend on model."],
                    "aspectRatio": ["type": "string", "description": "Aspect ratio (e.g. '16:9', '9:16', '1:1')"],
                    "resolution": ["type": "string", "description": "Resolution (e.g. '720p', '1080p', '4k')"],
                    "startFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the first frame (image-to-video)"],
                    "endFrameMediaRef": ["type": "string", "description": "Media asset ID to use as the last frame (supported by some models)"],
                    "sourceVideoMediaRef": ["type": "string", "description": "Media asset ID of a source video required by video-to-video models. Source duration determines billing; aspectRatio and resolution apply when listed by the selected model."],
                    "sourceClipId": ["type": "string", "description": "Optional. Clip id (from get_timeline) referencing sourceVideoMediaRef. When set and the clip is trimmed, only the clip's visible range is sent to the model, not the full source — matches the UI's 'Use trimmed portion only'."],
                    "referenceImageMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of image references. Covers both reference-to-video generation (Seedance, Kling V3/O3 elements, Grok — refer as @Image1/@Element1 in prompt) and the single-image ref used by video-to-video edit models (Kling V3 Motion Control). See list_models maxReferenceImages for per-model cap."],
                    "referenceVideoMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of video references (Seedance only). Refer to them as @Video1, @Video2. See maxReferenceVideos and maxCombinedVideoRefSeconds."],
                    "referenceAudioMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs of audio references. Lip-sync models use this as the replacement audio track; prompt-driven models refer to them as @Audio1, @Audio2. See maxReferenceAudios, requiresReferenceAudio, and maxCombinedAudioRefSeconds."],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'Hero shots/Takes'. Created if missing. Omit for the project root."],
                ]
            )
        ),
        AgentTool(
            name: .generateTransition,
            description: "Creates an AI video transition between two consecutive shots on a video track in one call. Pass afterClipId (the clip that ends where the transition should begin). Captures the last composited timeline frame of that shot as the first frame and the first frame of the following shot as the last frame, generates with a first+last-frame video model, places the placeholder into the gap, and retimes it to fill the gap when ready. If the clips are already contiguous, opens a gap first (duration defaults to 4s, snapped to the model). If a gap already exists after afterClipId, uses that gap as-is (max 15s). Prefer this over manually chaining capture_frame + generate_video + add_clips. Costs real money; generation itself is not undoable, but the gap open and timeline placement are.",
            inputSchema: objectSchema(
                properties: [
                    "afterClipId": ["type": "string", "description": "Clip id from get_timeline for the shot before the transition. The next visual clip on the same track becomes the destination."],
                    "prompt": ["type": "string", "description": "Optional motion prompt. Defaults to a seamless continuous-take transition. Describe only the morph/camera/SFX — first and last frames already anchor both ends."],
                    "name": ["type": "string", "description": "Optional media-library name for the generated transition."],
                    "model": ["type": "string", "description": "Video model id that supports first and last frames. Use list_models. Defaults to the first eligible model."],
                    "duration": ["type": "integer", "description": "Seconds when opening a new gap between contiguous clips. Ignored when a gap already exists (the existing gap length wins). Snapped to the model's supported durations. Max 15s."],
                    "aspectRatio": ["type": "string", "description": "Optional. Defaults to the timeline's aspect ratio matched to the model."],
                    "resolution": ["type": "string", "description": "Optional resolution from list_models."],
                    "folder": ["type": "string", "description": "Optional destination folder path for the generated asset."],
                ],
                required: ["afterClipId"]
            )
        ),
        AgentTool(
            name: .generateImage,
            description: "Starts an async AI image generation. Returns a placeholder asset ID immediately; generation runs in the background. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Text description of the image to generate"],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID (e.g. 'nano-banana-pro'). Use list_models to see options. Defaults to first available model."],
                    "aspectRatio": ["type": "string", "description": "Aspect ratio (e.g. '16:9', '9:16')"],
                    "resolution": ["type": "string", "description": "Resolution (e.g. '2K', '4K')"],
                    "quality": ["type": "string", "description": "Image quality (e.g. 'low', 'medium', 'high'). Only supported by some models — see list_models."],
                    "referenceMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Media asset IDs to use as reference images"],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'Hero shots/Takes'. Created if missing. Omit for the project root."],
                ],
                required: ["prompt"]
            )
        ),
        AgentTool(
            name: .generateAudio,
            description: "Starts an async AI audio generation or transformation. Returns a placeholder asset ID immediately; the asset appears in get_media and becomes usable in add_clips once ready. TTS converts text into speech. Generative audio models create dialogue, music, or sound effects from a prompt, video, or supported image/audio references. Voice Cleanup isolates speech from background audio. Dubbing translates source speech while preserving speaker delivery; pass targetLanguage. For models whose inputs include audio or video, provide sourceMediaRef. Video-to-audio scoring models also accept videoSourceStartFrame+videoSourceEndFrame and place the result on the timeline automatically. Other results land in the media library for placement with add_clips. Use list_models with type='audio' to inspect inputs, category, voices, reference caps, and limits. Models marked usesOwnApiKey run directly on the user's own ElevenLabs key and are billed by ElevenLabs, not in Palmier credits; they need no Palmier account. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "prompt": ["type": "string", "description": "Required for text-driven models. TTS uses it as spoken text; generative audio models use it as the scene, music, or sound description. Omit for Voice Cleanup and Dubbing."],
                    "name": ["type": "string", "description": "Display name for the asset in the media library. Defaults to first 30 chars of prompt."],
                    "model": ["type": "string", "description": "Model ID. Use list_models with type='audio' to see options and their 'inputs'. Defaults to the first model."],
                    "voice": ["type": "string", "description": "TTS only. Voice preset name. list_models shows voicesSample (first 3) + voiceCount; any voice supported by the model is accepted. Defaults to the model's defaultVoice. Ignored by music models."],
                    "lyrics": ["type": "string", "description": "MiniMax Music only. Lyrics with optional [Verse]/[Chorus] section tags. If omitted and instrumental=false, MiniMax auto-writes lyrics from the prompt."],
                    "styleInstructions": ["type": "string", "description": "Gemini TTS only. Optional delivery instructions (e.g. 'warm and slow', 'British accent')."],
                    "instrumental": ["type": "boolean", "description": "Music models only. true = no vocals when the selected model supports it. Defaults to false."],
                    "duration": ["type": "integer", "description": "Length in seconds. ElevenLabs Music: 3–600. Sonilo text-to-music: up to 600. Video-to-audio models default to the source span; pass a value to request a different output length. Voice Cleanup and Dubbing always preserve the source length. Ignored by TTS, MiniMax, and Lyria 3 Pro."],
                    "sourceMediaRef": ["type": "string", "description": "Source audio or video asset ID for models whose inputs include audio or video. Required for Voice Cleanup and Dubbing."],
                    "targetLanguage": ["type": "string", "description": "Required for Dubbing. ISO language code such as 'es', 'fr', 'de', or 'ja'."],
                    "referenceImageMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Image asset IDs for audio models that support image references. See list_models for the count limit. Mutually exclusive with referenceAudioMediaRefs when list_models reports referenceImagesAndAudiosExclusive."],
                    "referenceAudioMediaRefs": ["type": "array", "items": ["type": "string"], "description": "Audio asset IDs for audio models that support audio references. Refer to them in the prompt as @Audio1, @Audio2, and @Audio3. See list_models for the count, duration, and file-type limits."],
                    "multilingual": ["type": "boolean", "description": "Enable multilingual generation when supported by the selected model. Defaults to false."],
                    "videoSourceStartFrame": ["type": "integer", "description": "Video-to-audio models only. Start frame (timeline) of a span to render and score — pair with videoSourceEndFrame. Use get_timeline for frame numbers; for the whole timeline use 0 to the timeline's end frame."],
                    "videoSourceEndFrame": ["type": "integer", "description": "Video-to-audio models only. End frame (exclusive) of the span to score. Must be > videoSourceStartFrame."],
                    "videoSourceMediaRef": ["type": "string", "description": "Video-to-audio models only. Score this existing video asset instead of a timeline span. Mutually exclusive with the videoSource frames."],
                    "folder": ["type": "string", "description": "Optional destination folder path, e.g. 'Hero shots/Takes'. Created if missing. Omit for the project root."],
                ],
                required: []
            )
        ),
        AgentTool(
            name: .upscaleMedia,
            description: "Enhances an existing video or image with an AI upscaler. It can change resolution, interpolate video frame rate, or apply model-specific restoration settings. Returns a placeholder asset ID immediately; the result appears in get_media once ready. Call list_models with type='upscale' first and use its exact setting IDs and values. Costs real money and is not undoable.",
            inputSchema: objectSchema(
                properties: [
                    "mediaRef": ["type": "string", "description": "ID of the video or image asset to upscale"],
                    "model": ["type": "string", "description": "Upscaler model ID (e.g. 'bytedance-upscaler', 'seedvr-image-upscaler'). Defaults to the first model that supports the asset's type."],
                    "sourceClipId": ["type": "string", "description": "Optional. Video clip id (from get_timeline) referencing mediaRef. When set and the clip is trimmed, only the clip's visible range is upscaled, not the full source."],
                    "settings": [
                        "type": "object",
                        "description": "Optional flat map of setting ID to value from list_models. Select settings take strings, numeric settings take numbers, and toggle settings take booleans. Omitted settings use model defaults. Example: {\"targetResolution\":\"4k\",\"targetFPS\":\"60\",\"enhancementModel\":\"Proteus\",\"noise\":0.2}.",
                    ],
                ],
                required: ["mediaRef"]
            )
        ),
        AgentTool(
            name: .sendFeedback,
            description: "Report an agent limitation or bug to the Palmier team so they can improve the product. Use when you can't do what the user asked because a capability or tool is missing or behaves wrong, the result is clearly off, or the user is plainly hitting a rough edge. This sends directly — there is no user confirmation step — so write the report in English and PARAPHRASE in your own words: translate non-English user text to English, and never include verbatim user messages, prompts, file paths, media, transcript text, or any project content. App/OS version and your recent tool names are attached automatically. Use sparingly: at most once per distinct issue.",
            inputSchema: objectSchema(
                properties: [
                    "category": ["type": "string", "enum": ["missing_capability", "wrong_result", "confusing_ux", "failure", "suggestion"], "description": "What kind of problem this is."],
                    "summary": ["type": "string", "description": "One-line paraphrased summary of the issue. Becomes the report's subject."],
                    "details": ["type": "string", "description": "Optional. Paraphrased explanation of what the user was trying to do and what went wrong or was missing. No verbatim content."],
                    "severity": ["type": "string", "enum": ["low", "medium", "high"], "description": "Optional. How much this blocked the user."],
                ],
                required: ["category", "summary"]
            )
        ),
        AgentTool(
            name: .reviewTimeline,
            description: "Read-only quality review of the active timeline. Reports pacing metrics (shot count, average/median shot seconds, per-third pacing), gaps that render black on the primary video track, and cut-to-beat alignment when detect_beats results are cached for the timeline's audio (run detect_beats on the music first, then call this). findings lists concrete issues with frame evidence. capture lists frames to render with capture_frame plus rubric questions — this tool never looks at pixels, so always do that visual pass to judge text readability, framing, and shot-to-shot consistency before calling a review complete. Pass referenceId (from manage_references) to compare pacing and BPM against a stored reference video; compare its look values via inspect_color. Makes no changes and creates no undo entries.",
            inputSchema: objectSchema(
                properties: [
                    "referenceId": ["type": "string", "description": "Optional. A reference profile id from manage_references; adds a pacing/BPM comparison against that reference."],
                ]
            )
        ),
        AgentTool(
            name: .manageReferences,
            description: "Maintain Palmier's app-wide library of reference videos — examples of the pacing, rhythm, and look the user wants their edits to match. Profiles are stored per-user and available in every project. Set action to: 'analyze' to fingerprint a video (shot pacing per third, BPM, loudness, color) and store it — pass mediaRef for project media or an absolute path for any video file, with an optional name; 'list' for all stored profiles; 'remove' with referenceId to delete one. Analysis decodes the whole video and can take a while on long files. Use a stored referenceId with review_timeline to compare the current edit's pacing, and inspect_color to compare its look against the profile's look values.",
            inputSchema: objectSchema(
                properties: [
                    "action": ["type": "string", "enum": ["analyze", "list", "remove"], "description": "What to do with the reference library."],
                    "mediaRef": ["type": "string", "description": "analyze: id of a video asset in the current project."],
                    "path": ["type": "string", "description": "analyze: absolute path to a video file on disk; alternative to mediaRef."],
                    "name": ["type": "string", "description": "analyze: optional display name for the profile; defaults to the file name."],
                    "referenceId": ["type": "string", "description": "remove: id of the profile to delete."],
                ],
                required: ["action"]
            )
        ),
    ]

    private static let keyframeRowShapes = "Row shapes — volumeDb: [frame, dB −60…+15]; opacity: [frame, 0–1]; rotation: [frame, degrees clockwise]; position: [frame, topLeftX, topLeftY] (TOP-LEFT corner in 0–1 canvas coords, NOT the center); scale: [frame, width, height] (normalized 0–1 canvas size, NOT a scale factor); crop: [frame, top, right, bottom, left] (0–1 insets). Optional last row element: the ease out of that keyframe — a name (smooth default, easeOut, easeIn, easeInOut, linear, hold, anticipate, spring, steps, plus sine/circ/expo/back/elastic/bounce with In/Out/InOut), an [x1,y1,x2,y2] bezier, {type: 'spring'|'steps'|'back'|'elastic'|'cubicBezier', …}, or a split ease {out, in}."

    private static func nonColorEffectIds() -> [String] {
        EffectRegistry.all.map(\.id).filter { !$0.hasPrefix("color.") }
    }

    /// One line per non-color effect for apply_effect's description, generated from the registry.
    private static func effectCatalog() -> String {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
        return EffectRegistry.all
            .filter { !$0.id.hasPrefix("color.") }
            .map { d in
                let params = d.params.map { p in
                    "\(p.key) (\(n(p.range.lowerBound))…\(n(p.range.upperBound))\(p.unit), default \(n(p.defaultValue)))"
                }.joined(separator: ", ")
                let addonNote = d.id.hasPrefix("mockup.") ? " [requires the Device Mockups project addon]" : ""
                return "• \(d.id) — \(d.displayName): \(params.isEmpty ? "no params" : params)\(addonNote)"
            }
            .joined(separator: "\n")
    }

    static let readSkill = AgentTool(
        name: .readSkill,
        description: "Load the full instructions for one of the user's installed skills — playbooks for specific editing tasks (motion design, brand packages, recurring formats). Call without arguments to list available skills as `- id: description` lines; call with `id` to load one skill's full procedure, then follow it. Before starting a task that matches a listed skill's description, load and follow that skill.",
        inputSchema: objectSchema(
            properties: [
                "id": ["type": "string", "description": "The skill id exactly as listed. Omit to list all installed skills."],
            ]
        )
    )

    /// MCP server only
    static let manageProject = AgentTool(
        name: .manageProject,
        description: "List, open, create, or close Palmier projects for this MCP session. Set `action` to: `list` for known projects plus session-active and visible state; `open` with a name, id from list, or .palmier path; `create` with an optional name and initial fps/aspectRatio/quality; or `close` to save and close the session project, optionally targeting another open project by name/id/path. Opening or creating changes only this session's target. Closing always completes a final save first. This tool never deletes projects or files.",
        inputSchema: objectSchema(
            properties: [
                "action": ["type": "string", "enum": ["list", "open", "create", "close"], "description": "Project operation."],
                "name": ["type": "string", "description": "Project name. For open/close, matched case-insensitively; for create, defaults to 'Untitled Project'."],
                "id": ["type": "string", "description": "Project id returned by action='list'. Used by open or close."],
                "path": ["type": "string", "description": "Filesystem path to a .palmier package. Used by open or close."],
                "fps": ["type": "integer", "description": "Create only. Optional timeline frame rate (1-120)."],
                "aspectRatio": [
                    "type": "string",
                    "description": "Create only. Optional canvas aspect ratio as width:height, such as '16:9', '3:2', or '2.39:1'.",
                ],
                "quality": [
                    "type": "string",
                    "enum": ["720p", "1080p", "2K", "4K"],
                    "description": "Create only. Optional resolution preset applied to the aspect ratio.",
                ],
            ],
            required: ["action"]
        )
    )

    static var mcpServer: [AgentTool] { all + [manageProject, readSkill] }
    static var inAppAgent: [AgentTool] { all + [readSkill] }

    private static func textBoxTransformProperties() -> [String: [String: Any]] {
        [
            "centerX": ["type": "number", "description": "0-1 horizontal center."],
            "centerY": ["type": "number", "description": "0-1 vertical center."],
            "width": ["type": "number", "description": "0-1 width."],
            "height": ["type": "number", "description": "0-1 height."],
            "rotation": ["type": "number", "description": "Clockwise degrees."],
        ]
    }

    private static func textStyleProperties(detailed: Bool) -> [String: [String: Any]] {
        let properties: [String: [String: Any]] = [
            "style": [
                "type": "object",
                "description": "Partial text-style patch. Omit properties to keep defaults or existing values.",
                "properties": [
                    "fontName": ["type": "string", "description": "Font PostScript name."],
                    "fontSize": ["type": "number", "minimum": 12, "maximum": 300, "description": "Font size in canvas points."],
                    "widthScale": ["type": "number", "minimum": TextStyle.axisScaleRange.lowerBound, "maximum": TextStyle.axisScaleRange.upperBound, "description": "Glyph width multiplier. 1 preserves the font's original width."],
                    "heightScale": ["type": "number", "minimum": TextStyle.axisScaleRange.lowerBound, "maximum": TextStyle.axisScaleRange.upperBound, "description": "Glyph height multiplier. 1 preserves the font's original height."],
                    "bold": ["type": "boolean", "description": "Bold font trait."],
                    "italic": ["type": "boolean", "description": "Italic font trait."],
                    "underline": ["type": "boolean", "description": "Draw a line below the text."],
                    "strikethrough": ["type": "boolean", "description": "Draw a line through the text."],
                    "overline": ["type": "boolean", "description": "Draw a line above the text."],
                    "tracking": ["type": "number", "minimum": -20, "maximum": 100, "description": "Spacing between characters in canvas points."],
                    "lineSpacing": ["type": "number", "minimum": -100, "maximum": 300, "description": "Additional spacing between lines in canvas points."],
                    "fontCase": ["type": "string", "enum": ["mixed", "uppercase", "lowercase"], "description": "Non-destructive display casing."],
                    "alignment": ["type": "string", "enum": ["left", "center", "right"], "description": "Text alignment."],
                    "color": ["type": "string", "description": "Text color as #RGB, #RRGGBB, or #RRGGBBAA."],
                    "outline": [
                        "type": "object",
                        "properties": [
                            "enabled": ["type": "boolean"],
                            "color": ["type": "string", "description": "Outline color hex."],
                            "width": ["type": "number", "minimum": 0, "maximum": 40, "description": "Width in canvas points."],
                        ],
                    ],
                    "shadow": [
                        "type": "object",
                        "properties": [
                            "enabled": ["type": "boolean"],
                            "color": ["type": "string", "description": "Shadow color hex. Six-digit colors preserve the current opacity."],
                            "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                            "offset": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number", "minimum": -200, "maximum": 200],
                                    "y": ["type": "number", "minimum": -200, "maximum": 200],
                                ],
                            ],
                            "blur": ["type": "number", "minimum": 0, "maximum": 100, "description": "Blur radius in canvas points."],
                        ],
                    ],
                    "background": [
                        "type": "object",
                        "properties": [
                            "enabled": ["type": "boolean"],
                            "color": ["type": "string", "description": "Background color hex. Six-digit colors preserve the current opacity."],
                            "opacity": ["type": "number", "minimum": 0, "maximum": 1],
                            "padding": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number", "minimum": 0, "maximum": 300],
                                    "y": ["type": "number", "minimum": 0, "maximum": 300],
                                ],
                            ],
                            "center": [
                                "type": "object",
                                "properties": [
                                    "x": ["type": "number", "minimum": -500, "maximum": 500],
                                    "y": ["type": "number", "minimum": -500, "maximum": 500],
                                ],
                            ],
                            "cornerRadius": ["type": "number", "minimum": 0, "maximum": 300, "description": "Corner radius in canvas points."],
                            "outline": [
                                "type": "object",
                                "properties": [
                                    "color": ["type": "string", "description": "Background outline color hex."],
                                    "width": ["type": "number", "minimum": 0, "maximum": 40, "description": "Background outline width in canvas points."],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        guard !detailed, var style = properties["style"] else { return properties }
        style = schemaWithoutDescriptions(style)
        style["description"] = "Same partial style patch as update_text."
        return ["style": style]
    }

    private static func schemaWithoutDescriptions(_ schema: [String: Any]) -> [String: Any] {
        schema.reduce(into: [:]) { result, entry in
            guard entry.key != "description" else { return }
            if let nested = entry.value as? [String: Any] {
                result[entry.key] = schemaWithoutDescriptions(nested)
            } else if let items = entry.value as? [Any] {
                result[entry.key] = items.map { item in
                    guard let nested = item as? [String: Any] else { return item }
                    return schemaWithoutDescriptions(nested)
                }
            } else {
                result[entry.key] = entry.value
            }
        }
    }

    private static func mergedProperties(_ chunks: [String: [String: Any]]...) -> [String: [String: Any]] {
        chunks.reduce(into: [:]) { merged, chunk in
            merged.merge(chunk) { _, new in new }
        }
    }

    private static func objectSchema(
        properties: [String: [String: Any]] = [:],
        required: [String] = [],
        description: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = ["type": "object"]
        if let description {
            dict["description"] = description
        }
        if !properties.isEmpty {
            dict["properties"] = properties
        }
        if !required.isEmpty {
            dict["required"] = required
        }
        return dict
    }
}

extension AgentTool {
    var mcpSchemaValue: Value {
        Self.valueFromJSON(inputSchema)
    }

    private static func valueFromJSON(_ any: Any) -> Value {
        switch any {
        case let v as Value: return v
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let arr as [Any]: return .array(arr.map(valueFromJSON))
        case let dict as [String: Any]:
            var out: [String: Value] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = valueFromJSON(v) }
            return .object(out)
        default: return .null
        }
    }
}

enum ToolArgsBridge {
    static func argsFromMCP(_ args: [String: Value]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(args.count)
        for (k, v) in args { out[k] = anyFromValue(v) }
        return out
    }

    static func anyFromValue(_ v: Value) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(_, let d): return d
        case .array(let arr): return arr.map(anyFromValue)
        case .object(let obj):
            var out: [String: Any] = [:]
            out.reserveCapacity(obj.count)
            for (k, v) in obj { out[k] = anyFromValue(v) }
            return out
        }
    }
}
