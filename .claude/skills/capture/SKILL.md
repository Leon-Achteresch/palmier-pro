---
name: capture
description: Take screenshots or screen recordings of the running PalmierPro app, and drive its UI (menus, keyboard shortcuts, buttons) via AppleScript. Use when asked to show, screenshot, record, or verify the app's UI, or to reproduce a UI interaction visually.
---

# Capturing PalmierPro's UI

PalmierPro is a native macOS app — Playwright and mobilewright do not apply. Use
`scripts/capture.sh`, which wraps `screencapture` and System Events.

```bash
scripts/capture.sh shot inspector          # -> .build/captures/inspector.png
scripts/capture.sh rec export 10           # 10s recording -> .build/captures/export.mov
scripts/capture.sh ui 'keystroke "e" using command down'
```

Then `Read` the returned path to look at the screenshot.

To record *while* interacting, start `rec` with the Bash tool's
`run_in_background: true`, run the `ui` commands, and read the file once the
recording's duration has elapsed.

## Driving interactions

`ui` runs AppleScript inside the app's process:

```bash
scripts/capture.sh ui 'get entire contents of window 1'    # discover elements
scripts/capture.sh ui 'click button "Export" of window 1'
scripts/capture.sh ui 'click menu item "Export…" of menu "File" of menu bar 1'
scripts/capture.sh ui 'key code 49'                        # space
```

For editor state (timeline, clips, effects) prefer the palmier-pro MCP tools —
they are faster and more reliable than clicking. Use `ui` only for things that
exist solely in the UI.

## Notes

- Start the app first: `swift run` (or launch `/Applications/PalmierPro.app`).
- `ui` needs Accessibility permission for the terminal running Claude Code:
  System Settings → Privacy & Security → Accessibility. Without it, `shot`/`rec`
  still work but capture the full display instead of just the window.
- Output goes to `.build/captures/` (gitignored). Names are stable and
  overwritten, so reuse a name when iterating.
