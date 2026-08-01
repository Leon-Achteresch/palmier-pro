#!/bin/bash
set -euo pipefail

APP=${CAPTURE_APP:-PalmierPro}
OUT=${CAPTURE_DIR:-.build/captures}

mkdir -p "$OUT"

activate() {
  osascript -e "tell application \"$APP\" to activate" >/dev/null
  sleep 0.5
}

# ponytail: falls back to full screen when Accessibility is not granted
rect() {
  osascript -e "tell application \"System Events\" to tell process \"$APP\" to get {position, size} of front window" 2>/dev/null |
    tr -d ' ' | awk -F, 'NF==4 {printf "-R%d,%d,%d,%d", $1, $2, $3, $4}'
}

case "${1:-}" in
shot)
  name=${2:-$(date +%H%M%S)}
  activate
  screencapture -x -o $(rect) "$OUT/$name.png"
  echo "$OUT/$name.png"
  ;;

rec)
  name=${2:-$(date +%H%M%S)}
  activate
  screencapture -x -v -V "${3:-10}" -k $(rect) "$OUT/$name.mov"
  echo "$OUT/$name.mov"
  ;;

ui)
  osascript -e "tell application \"System Events\" to tell process \"$APP\"
    $2
  end tell" || {
    echo "Accessibility permission missing: System Settings > Privacy & Security > Accessibility" >&2
    exit 1
  }
  ;;

*)
  cat <<'USAGE'
usage: scripts/capture.sh <command>
  shot [name]              screenshot of the app window -> .build/captures/<name>.png
  rec [name] [seconds]     record window (default 10s) -> .build/captures/<name>.mov
  ui '<applescript>'       run AppleScript inside the app's process, e.g.
                             ui 'keystroke "e" using command down'
                             ui 'click menu item "Export…" of menu "File" of menu bar 1'
                             ui 'get entire contents of window 1'
USAGE
  exit 1
  ;;
esac
