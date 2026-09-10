# Motion Editor

Motion scenes are editable documents containing imported component packages, layers, controls, animation tracks, recipes, sound cues, and canvas variants. They use the editor's shared undo history. Video baking is a derived playback/export step; editing the stage does not require a complete bake.

## Open and compose

1. Open a saved Palmier project and click **Motion Design** beside **Import** in the media toolbar (also available in the empty media state). Enter a scene name, choose React or React Native, and click **Create Scene**. React Native is offered in builds with the `ReactNative` trait. Cancelling before creation does not add an asset.
2. Click **New Component** in the component library. Choose Card or Title, name it, and click **Create Component**; its first layer is added and selected on the stage. Edit text, colors, and animation in the inspector. **Edit Component Source** optionally accepts custom TSX with a default export. To use existing project files, choose **Import Component** or **Browse Repository**; dependencies must already be installed. The importer does not run installation scripts.
3. Click a component in the library to add another instance to the stage. Exposed properties appear in the inspector; inferred controls can be edited through **Edit Component Controls** in the component library.
4. Select layers in the stage or layer tree; Command-click extends selection. Drag to move, use corner handles to scale or rotate, and use Align, Snap, Group, or Duplicate. Interact mode forwards input to the product component.
5. Turn on **Auto Keyframe** to key a property at the playhead. Diamond buttons add keys explicitly. The lower timeline moves keys and edits interpolation, cubic curves, springs, repetitions, and gaps.
6. Animate applies structured recipes. Set the stagger interval before applying a recipe to multiple selected layers. Recipes remain editable; **Expand Recipe** converts one non-overlapping recipe into frame keys.
7. Deselect layers to edit scene settings, sound cues, and format variants. Add to Timeline places the scene with a linked audio companion. Later scene edits update its timeline instances.

One completed drag is one undo action. Escape cancels the active gesture or operation. Imports and document writes have cancellation controls. A conflicting AI revision refuses a stale edit; read or refresh the scene before retrying.

## Component contract

Import the actual product component and its CSS/assets. Wrap providers, routing, callbacks, and external data in a local adapter when needed. The adapter should expose controlled props rather than depend on replaying interaction or network requests.

```tsx
import {PricingCard} from './product/PricingCard';
import './product/theme.css';

export default function PricingShot({price = 29, selected = false}: {
  price: number;
  selected: boolean;
}) {
  return <PricingCard price={price} selected={selected} onChoose={() => {}} />;
}
```

Simple TypeScript props, literal defaults, and compatible Storybook args/argTypes are inferred. Explicit registration supplies controls, fixtures, and slots that cannot be inferred:

```json
{
  "id": "pricing-card",
  "name": "Pricing Card",
  "entry": "./PricingShot.tsx",
  "exportName": "default",
  "runtime": "web",
  "props": [
    {"id":"price","label":"Price","kind":"number","defaultValue":29,"minimum":0,"maximum":999,"choices":[],"animatable":true},
    {"id":"selected","label":"Selected","kind":"boolean","defaultValue":false,"choices":[],"animatable":true}
  ],
  "fixtures": {"basic":{"price":29,"selected":false},"featured":{"price":59,"selected":true}},
  "slots": []
}
```

Import that JSON file to use its registration. Controls support numbers, strings, colors, booleans, choices, and embedded assets. **Save Fixture** stores the current controlled state. Timed fixture changes are available with Auto Keyframe.

Components can opt into internal editing by wrapping an element in `MotionSlot` from `palmier`, then registering its ID. The wrapper preserves the layout styles supplied by the component. It exposes translation, scale, rotation, opacity, and reveal. Slots appear inside the selected component's stage bounds and in its inspector. Repeated elements use stable `itemKey` values: `<MotionSlot id="row" itemKey="pro">` is registered as `row:pro`. Portals must explicitly carry the slot wrapper into the scene host; arbitrary descendants are not converted into editable layers.

A component's render must be a function of frame and controlled props. Use `useCurrentFrame` and the supported `palmier`/`remotion` helpers. Timers, network effects, CSS transitions, layout animations, and native animation drivers require adapters. React Native uses macOS views; iOS/Android-only modules are not interchangeable with macOS support. One scene uses one host. Native `Image` and `ImageBackground` accept bundled `require(...)` image strings and embedded data URLs; remote/file URLs and unpinned asset-registry IDs are refused. Empty image states do not delay frame readiness.

The scene pins bundled source, CSS, embedded assets, fixtures, and sound bytes. It can reopen without the source checkout. Reimporting an existing component builds an update candidate; applying it validates existing bindings and remains undoable. Scene revisions are immutable `.motion` files in the project package, including their component payloads. Previous revisions remain available to undo and Save As. Version-1 source-only scenes are rejected without modification.

## Agent operations

`manage_motion_scene` exposes `create`, `components`, `import`, `read`, `compose`, `animate`, `content`, `arrange`, `configure`, and `render`.

- `components` with `repositoryPath` searches local component exports and stories. With `mediaRef`, it searches registered components; `componentId` returns one schema. Responses paginate at up to 50 entries.
- `read` returns a revision and optional selected subtree without component source.
- Edits require the exact `expectedRevision`; `requestId` permits identical retries within the editor session's last 128 requests. Receipts return full stable IDs, changed IDs, no-op state, and the saved revision.
- Timing arguments use zero-based scene frames. Stored node tracks use layer-local frames. Numeric values interpolate; strings, choices, and booleans switch at keys.
- `configure` pins cue sources from library audio/video assets, with source trims and gain. Up to eight cues may overlap. It also manages reusable canvas variants.
- `render` returns a terminal bake result after checking that the document revision is still current. `inspect_media` provides frame inspection through the existing media tools.

## Manual acceptance plan

UI acceptance requires a human run; automated rendering is not confirmation that the UI interactions passed.

Use a temporary project and a real product component with CSS, a font, an image, two fixture states, and one registered slot. Import it, add three instances, change a label and price, stagger entrances, drag at different zoom levels, move an internal slot, and edit/move keys. Scrub forward and backward, then inspect the same frames after export. Expected: stable layout, matching frames, correct alpha, and one undo step per committed intent.

Add a sound cue, change its trim and gain, and add the scene to the timeline. Extend and split the linked clips, place them in a nested timeline, and export. Expected: cue timing follows the scene, extended tails are silent, and later scene edits update all instances.

Cancel a drag with Escape and release the mouse; change selection or deactivate the app mid-drag; edit a locked layer; mix a UI edit with an Agent edit and undo both. Expected: no stale commit, exact restoration, and clear refusals without empty undo steps.

Drop and paste valid and invalid `.motion` files into the Agent input. Switch projects during attachment validation. Expected: invalid scenes create no media or undo entry, and attachments do not enter the replacement project.

Save, Save As, close/reopen, remove the source checkout, and repeat rendering. Reimport an incompatible component update and cancel an import/render. Close the project while a write is admitted. Expected: pinned content remains available, incompatible bindings are refused, cancellation has a terminal result, and package state stays consistent.

## Render verification harness

The application harness runs an NSApplication event loop without opening a user project:

```sh
.build/debug/PalmierPro --bake-motion-scene /tmp/example.motion \
  --motion-output-directory /tmp/motion-verification \
  --motion-frames 0,200,20,200
```

It writes direct-seek PNGs, measured slot bounds, and the baked alpha ProRes movie with audio. Use a scene longer than the largest requested frame. Compare repeated frames byte-for-byte and decoded export pixels with a defined codec tolerance. The output directory isolates verification from the application cache. Native capture uses bounded leaf images (32 million pixels per frame, at most 4,096 pixels per leaf dimension) and a single reusable Metal target; overly complex frames fail explicitly. Scene files are limited to 64 MiB. Immutable revisions remain in the project package so undo and Save As retain their pinned content.

## Automated verification — 2026-09-09

- `scripts/bundle.sh debug --react-native`: passed, producing `.build/PalmierPro.app`. `codesign --verify --deep --strict` passed for the app and nested frameworks; the embedded compiler passed its separate signature check and `--version` execution. Hermes is arm64 and retains its versioned framework symlinks.
- The five application CLI scenarios were repeated from the packaged executable with `/tmp` as the working directory. Both hosts loaded their packaged resources, repeated seeks and decoded exports passed the same pixel assertions, and packaged snapshots exactly matched SwiftPM snapshots.
- `npm run build` in `web/`, `npm run bundle` in `native/rn/`, and `native/rn/build-host.sh`: passed. Both JavaScript resources and the arm64 native host were rebuilt.
- `scripts/localization/sync.sh`: its standard-trait Swift build and localization checks passed, generating the English inventory. Existing translation catalogs report 9,909 missing/obsolete-key coverage warnings; new untranslated UI uses the source-language fallback. Non-English catalogs were not modified.
- `swift test --traits ReactNative --filter 'MotionLayoutOperationsTests|MotionVideoEncoderTests|MotionSceneRenderingTests|MotionSceneOperationsTests|MotionSceneStoreTests|MotionFileMutationTests|MCPMotionSceneTests|MotionComponentImportTests|MotionSceneAudioTests|EditorUndoTests|ProjectPackageCoordinatorTests|MotionSceneRuntimeTests|MotionSceneModelTests'`: 70 tests in 13 suites passed. One older offscreen WebKit alpha test is disabled; actual application capture and the encoder regression below cover alpha separately.
- `swift test -Xswiftc -enable-actor-data-race-checks --filter 'MotionSceneStoreTests|MotionFileMutationTests|ProjectPackageCoordinatorTests|MCPMotionSceneTests|EditorUndoTests'`: 17 tests in five suites passed. Includes deterministic cancellation, save admission, package serialization, and undo interleaving. Thread Sanitizer was not run.
- `node --test runtime/scene-evaluator.test.cjs native/rn/image-source.test.cjs scripts/localization/sync.test.mjs`: 13 tests passed.
- MCP tests connect a real MCP client and server over an isolated in-memory transport. Discovery/schema, import, compose, animate, content, invalid inputs and legacy scene-file imports, stale revisions, retries, no-op receipts, persisted readback, and mixed UI-domain/MCP undo passed. No user project was modified.
- The application CLI rendered five isolated scenes in both hosts: a moving product card, controlled text and slot opacity, embedded images and empty-image state, a font, ellipse/reveal masks, path progress, text progression, transformed groups/camera, and native blur. Seek orders were `0,200,20,200` and `0,60,20,60`. Repeated frames were pixel-identical. FFmpeg-decoded ProRes 4444 frames differed by at most one alpha value and three premultiplied RGB values out of 255. Additional slot translation/scale fixtures returned identical measured bounds in both hosts.
- The encoder regression encodes and independently decodes 25%, 50%, and 100% alpha through AVFoundation, checking composited color within three values out of 255. Sound tests independently decode cue placement, gain, and silence from pinned source bytes.
- Derived motion movies deliberately retain the existing 1,800-second held final frame for timeline extension. The measured video duration is 1,800 seconds plus one frame; the AAC stream ends at the scene duration and extended tails are silent.

The full `swift test` run did not complete: it stalled in the existing Vision subject-mask test `identicalInputReusesTheCachedMaskWithoutRerunningVision` and was terminated after sampling the blocked process. It also reported unrelated failures in existing tool-schema, localization-sensitive notification/marker, project-registry, and appearance tests. The affected suites above passed; the full suite is not reported as passing. No before/after performance or token benchmark was performed. Human UI acceptance remains pending; use the plan above.

## Creation UI verification

In a temporary saved project, open **Motion Design** from the toolbar and the empty media state. Cancel once and confirm no media asset was added. Create a named React scene, then a Card component. Expect the component in the library, one selected layer on the stage, and editable title/subtitle/color controls in the inspector. Create a Title and add another instance from the library. Undo and redo component creation; its definition and first layer must disappear/reappear together. Close and reopen the scene and project to verify persistence.

Repeat with React Native in a native-enabled build. In **Edit Component Source**, submit invalid TSX: the dialog must retain the draft, show the compiler error, and add no layer. Correct it and retry. Exercise Return, Escape, Cancel during compilation, focus changes, scene close, and project close while work is active. Human UI acceptance remains pending.

Creation follow-up verification (2026-09-10):

- `swift test --filter 'MotionComponentCreationTests|MotionComponentImportTests|MotionSceneStoreTests|MotionSceneOperationsTests'`: 26 tests passed.
- `swift test --traits ReactNative --filter 'MotionComponentCreationTests|MotionComponentImportTests|MotionSceneStoreTests|MotionSceneOperationsTests|MotionFileMutationTests|EditorUndoTests|ProjectPackageCoordinatorTests'`: 36 tests in 7 suites passed, including four template/runtime combinations.
- `scripts/localization/sync.sh`: default build and localization checks passed; 1,223 source strings, with existing non-English coverage warnings.
- `scripts/bundle.sh debug --react-native`: build and packaging passed. `codesign --verify --deep --strict --verbose=2 .build/PalmierPro.app` passed.
- `swift test`: attempted again; legacy `link_clips`/`copy_attributes` and tool-schema tests reported failures. The run stalled in the Vision subject-mask test named above and was terminated after sampling.
- Direct UI verification was blocked by unavailable Accessibility and Screen Recording permissions. Follow the manual plan above; human UI acceptance is not claimed.
