import Foundation

extension ToolDefinitions {
    static var motionScene: AgentTool {
        let string: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let integer: [String: Any] = ["type": "integer"]
        let boolean: [String: Any] = ["type": "boolean"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let values: [String: Any] = ["type": "object", "description": "Property bindings to JSON values. Transform values use scene pixels, clockwise degrees, scale factors and opacity 0–1. Use props.<id> or slots.<id>.<property> for registered component bindings."]
        let easing = motionObject([
            "kind": ["type": "string", "enum": MotionEasing.Kind.allCases.map(\.rawValue)],
            "x1": number, "y1": number, "x2": number, "y2": number, "stiffness": number, "damping": number, "mass": number,
        ])
        let layer = motionObject([
            "id": string, "name": string, "kind": ["type": "string", "enum": MotionNode.Kind.allCases.map(\.rawValue)],
            "parentId": string, "componentId": string, "startFrame": integer, "durationFrames": integer,
            "properties": values, "props": ["type": "object", "description": "Registered prop IDs to values; no props. prefix here."],
        ], required: ["kind"])
        let key = motionObject(["id": string, "frame": integer, "value": [:], "easing": easing], required: ["frame", "value"])
        let track = motionObject([
            "binding": string, "keys": ["type": "array", "items": key, "minItems": 1, "maxItems": 4096],
            "repeatCount": integer, "mirror": boolean, "gapFrames": integer,
        ], required: ["binding", "keys"])
        let format = motionObject([
            "id": string, "name": string, "width": integer, "height": integer,
            "overrides": ["type": "object", "description": "Layer IDs to base visual property overrides."],
        ], required: ["name", "width", "height"])
        let cue = motionObject([
            "id": string, "mediaRef": string, "frame": integer, "trimStartFrame": integer, "durationFrames": integer, "volumeDB": number,
        ], required: ["mediaRef", "frame", "durationFrames"])
        return AgentTool(
            name: .manageMotionScene,
            brief: "Import real React/React Native components and compose editable motion scenes. Read compact layers, animate props or transforms, apply fixtures and arrange layers through the same undoable operations as the visual Motion Editor.",
            description: """
            Author a structured motion asset. Use create for an empty scene or initial text/shape/group layers; import to compile a selected local product component (.tsx/.jsx/.js or a registration JSON), including its installed dependencies, CSS, fonts and assets. Import runs no installation scripts. Components must expose controlled props/fixtures and frame-driven behavior; timers, network effects, CSS transitions and native animation drivers do not provide random-access animation. A scene uses web or react-native-macos; device-only native modules are unsupported. Do not recreate product JSX when its actual component can be imported.

            Workflow: create → import → components with mediaRef (search/pagination, then componentId for schema) → compose layers referencing componentId → animate or content → inspect_media. read returns the current revision and layers without component source; targets restrict it to a subtree. components with repositoryPath indexes local exports and stories; without mediaRef or repositoryPath it searches the built-in module catalog; includeSource is only for inspecting one registered component to repair its adapter. Plain titles can use add_texts instead.

            Every edit after create requires mediaRef and expectedRevision from read. Supply a unique requestId for safe retries; reuse the identical request to replay its receipt within the current editor session's last 128 requests. Reusing it for a different request fails. Replayed receipts describe the original result; read to obtain the current revision. Edits validate atomically and produce one undo action; invalid, unchanged, cancelled or stale requests do not add undo steps. A saved receipt confirms document persistence. render waits for a terminal video bake and verifies that its revision is still current; inspect_media checks sampled frames. Place a created asset using add_clips.

            compose takes layers in stacking order. Groups use parentId. Start/duration and all tool keyframe times are scene frames; track storage converts them to layer-local frames. animate accepts a recipe (slide-up-fade, slide-left-fade, pop, fade-in, fade-out, float, pulse, spin, typewriter, text-stagger) with timing, amount, easing and staggerFrames, or explicit tracks with ordered unique keys. Numeric values interpolate; strings/booleans switch at keys. Easing belongs to the departing key. repeatCount includes the first cycle. Remove tracks with removeBindings; remove recipes with removeRecipeIds; expandRecipeId expands one non-overlapping recipe into editable keys. content sets base values, or writes keys when frame is supplied; fixture applies a registered controlled state.

            arrange supports translate (dx/dy, optional snap and autoKey at frame), align (left/center/right/top/middle/bottom), group, ungroup, duplicate, delete, lock/unlock, hide/show, and reorder (all layer IDs required). Grouping requires adjacent siblings; ungrouping requires an unanimated identity group. configure changes canvas/timing/background or manages formats and sound cues. Format application and edits share validation; shortening a scene must leave its layers, keys and cues valid. Unsupported combinations and locked layers are refused without partial edits.
            """,
            inputSchema: motionObject([
                "action": ["type": "string", "enum": ["create", "read", "components", "import", "compose", "animate", "content", "arrange", "configure", "render"]],
                "mediaRef": string, "expectedRevision": string, "requestId": string, "name": string,
                "width": ["type": "integer", "minimum": 16, "maximum": 4096],
                "height": ["type": "integer", "minimum": 16, "maximum": 4096],
                "fps": ["type": "number", "minimum": 1, "maximum": 120],
                "durationInFrames": ["type": "integer", "minimum": 1, "maximum": 36000],
                "runtime": ["type": "string", "enum": ["web", "react-native"]],
                "layers": ["type": "array", "items": layer, "maxItems": 128],
                "targets": strings, "values": values, "fixture": string, "frame": integer,
                "path": ["type": "string", "description": "Local component or registration path; relative paths use the linked project folder."],
                "repositoryPath": ["type": "string", "description": "For components: index component exports and stories in a local repository, with search and pagination. Cannot be combined with mediaRef."],
                "exportName": string, "componentId": string, "search": string, "offset": integer,
                "limit": ["type": "integer", "minimum": 1, "maximum": 50], "includeSource": boolean,
                "recipe": ["type": "string", "enum": MotionRecipe.Kind.allCases.map(\.rawValue)],
                "startFrame": integer, "durationFrames": integer, "amount": number, "staggerFrames": integer,
                "repeatCount": integer, "mirror": boolean, "gapFrames": integer, "easing": easing,
                "tracks": ["type": "array", "items": track, "maxItems": 128], "removeBindings": strings,
                "removeRecipeIds": strings, "expandRecipeId": string,
                "arrangement": ["type": "string", "enum": ["translate", "align", "group", "ungroup", "duplicate", "delete", "lock", "unlock", "hide", "show", "reorder"]],
                "dx": number, "dy": number, "snap": boolean, "autoKey": boolean,
                "alignment": ["type": "string", "enum": MotionAlignment.allCases.map(\.rawValue)],
                "background": string, "formats": ["type": "array", "items": format, "maxItems": 32],
                "applyFormatId": string, "removeFormatIds": strings,
                "soundCues": ["type": "array", "items": cue, "maxItems": 256], "removeCueIds": strings,
            ], required: ["action"])
        )
    }

    private static func motionObject(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        let descriptions: [String: String] = [
            "action": "Filmmaker action to perform; send only that action's parameters.",
            "mediaRef": "Motion asset ID; receipts return the full stable ID.",
            "expectedRevision": "Opaque revision from read or the last saved receipt; required for edits and render.",
            "requestId": "Unique retry ID; identical requests replay within the last 128 requests of this editor session.",
            "name": "Display name for the scene, layer, or format.",
            "width": "Canvas or format width in pixels, 16–4096.", "height": "Canvas or format height in pixels, 16–4096.",
            "fps": "Scene frame rate, 1–120; timing parameters use this rate.",
            "durationInFrames": "Scene duration, 1–36000 frames; existing layers and cues must fit.",
            "runtime": "web for React DOM or react-native for supported React Native macOS components.",
            "layers": "New layers in stacking order; component layers reference a registered componentId.",
            "targets": "Ordered stable layer IDs; recipe staggering follows this order.",
            "fixture": "Registered fixture ID to apply to selected component layers.",
            "frame": "Scene frame at which to sample, place a cue, or write a key; zero-based.",
            "exportName": "JavaScript export or named component story to import; default is default.",
            "componentId": "Registered component ID; components returns its controls and fixtures.",
            "search": "Case-insensitive component name or repository path filter.",
            "offset": "Zero-based discovery offset from nextOffset, default 0.",
            "limit": "Discovery page size, 1–50; default 20.",
            "includeSource": "Include bundled source only when inspecting one registered component for adapter repair.",
            "recipe": "Structured animation recipe; remains editable until explicitly expanded.",
            "startFrame": "Zero-based scene frame for the layer or recipe entrance.",
            "durationFrames": "Positive duration in scene frames; must fit the scene, layer, or pinned sound.",
            "amount": "Recipe travel in pixels or rotation in degrees; recipe-dependent, default 40.",
            "staggerFrames": "Delay between selected layers in their supplied order, 0–36000 frames.",
            "repeatCount": "Total cycles including the first, 1–1000; all cycles must fit the layer.",
            "mirror": "Reverse every second repetition.", "gapFrames": "Hold the cycle endpoint between repetitions, 0–36000 frames.",
            "easing": "Interpolation departing a key or driving a recipe; bezier and spring expose their parameters.",
            "tracks": "Complete replacement tracks per binding for each selected layer; key times are scene frames.",
            "removeBindings": "Track bindings to remove from selected layers.",
            "removeRecipeIds": "Stable recipe IDs to remove from selected layers.",
            "expandRecipeId": "Expand one non-overlapping recipe on one selected layer into exact frame keys.",
            "arrangement": "Arrange operation; reorder requires every scene layer ID in targets.",
            "dx": "Horizontal translation in scene pixels.", "dy": "Vertical translation in scene pixels.",
            "snap": "Snap translation to the shared eight-pixel stage grid.",
            "autoKey": "Write transform keys at frame; otherwise shift base values and existing position keys together.",
            "alignment": "Align selection bounds together, or align a single layer to the canvas.",
            "background": "Transparent or hex canvas color (#RGB, #RGBA, #RRGGBB, #RRGGBBAA).",
            "formats": "Named canvas variants with layer property overrides; saved without applying them.",
            "applyFormatId": "Saved format to apply atomically to canvas dimensions and layer base properties.",
            "removeFormatIds": "Saved format IDs to delete.",
            "soundCues": "Audio placements referencing library audio/video assets. Pins source bytes; up to eight cues may overlap.",
            "removeCueIds": "Stable sound cue IDs to delete.",
            "id": "Stable identity; omitted IDs are generated and returned.",
            "parentId": "Parent group ID; omit for a top-level layer.",
            "kind": "Supported layer or interpolation kind.",
            "binding": "Visual property, props.<id>, or slots.<id>.<property>.",
            "keys": "Ordered unique keys; numeric values interpolate and other values switch exactly at the key.",
            "value": "Typed property value matching the binding's registered schema.",
            "trimStartFrame": "Source audio trim measured at scene fps; zero-based.",
            "volumeDB": "Cue gain in decibels, -96 to +12; default -12.",
            "x1": "First cubic-bezier control x, 0–1.", "y1": "First cubic-bezier control y, -10 to 10.",
            "x2": "Second cubic-bezier control x, 0–1.", "y2": "Second cubic-bezier control y, -10 to 10.",
            "stiffness": "Spring stiffness, 0.1–10000.", "damping": "Spring damping, 0.1–1000.", "mass": "Spring mass, 0.01–100.",
        ]
        let described = properties.map { key, value -> (String, [String: Any]) in
                var property = value
                if property["description"] == nil { property["description"] = descriptions[key] }
                return (key, property)
            }
        return ["type": "object", "properties": Dictionary(uniqueKeysWithValues: described), "required": required, "additionalProperties": false]
    }
}
