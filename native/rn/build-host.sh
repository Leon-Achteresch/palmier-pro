#!/bin/bash
set -euo pipefail

# Builds react-native-macos into a single vendored xcframework plus the Hermes dylib.
# Everything under native/rn/ is build-time only; the app consumes just the two artifacts.

cd "$(dirname "$0")"
ROOT="$PWD"
MACOS="$ROOT/macos"
PODS="$MACOS/Pods"
ARTIFACTS="$MACOS/build/artifacts"
OUT="$ROOT/build"
RN_PATH="$ROOT/node_modules/react-native-macos"

[ -d "$PODS" ] || { echo "missing $PODS — run: cd macos && RCT_NEW_ARCH_ENABLED=1 pod install"; exit 1; }

echo "==> patching react-native-macos for the macOS 26 SDK"
./patch-rn.sh

echo "==> building pods (arm64, Release)"
xcodebuild -project "$PODS/Pods.xcodeproj" -target Pods-PalmierRN \
  -configuration Release -sdk macosx -arch arm64 \
  REACT_NATIVE_PATH="$RN_PATH" \
  CONFIGURATION_BUILD_DIR="$ARTIFACTS" \
  build > "$MACOS/build/pods.log" 2>&1 || { tail -40 "$MACOS/build/pods.log"; exit 1; }

echo "==> compiling PalmierRNHost"
INCLUDES=("-I$PODS/Headers/Public")
for dir in "$PODS"/Headers/Public/*/; do INCLUDES+=("-I$dir"); done

rm -rf "$OUT" && mkdir -p "$OUT/obj" "$OUT/include"
clang++ -c "$MACOS/PalmierRNHost/PalmierRNHost.mm" -o "$OUT/obj/PalmierRNHost.o" \
  -std=c++20 -fobjc-arc -fexceptions -arch arm64 -mmacosx-version-min=14.0 -O2 \
  "${INCLUDES[@]}"

echo "==> merging $(ls "$ARTIFACTS"/*.a | wc -l | tr -d ' ') static libraries"
libtool -static -o "$OUT/libPalmierRNHost.a" "$OUT/obj/PalmierRNHost.o" "$ARTIFACTS"/*.a 2>/dev/null

cp "$MACOS/PalmierRNHost/PalmierRNHost.h" "$OUT/include/"
cat > "$OUT/include/module.modulemap" <<'EOF'
module PalmierRNHost {
  header "PalmierRNHost.h"
  export *
}
EOF

echo "==> assembling xcframework"
rm -rf "$OUT/PalmierRNHost.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/libPalmierRNHost.a" -headers "$OUT/include" \
  -output "$OUT/PalmierRNHost.xcframework" > /dev/null

echo "==> thinning Hermes to arm64"
HERMES_SRC="$PODS/hermes-engine/destroot/Library/Frameworks/macosx/hermes.framework"
rm -rf "$OUT/hermes.framework"
cp -R "$HERMES_SRC" "$OUT/hermes.framework"
lipo "$HERMES_SRC/hermes" -thin arm64 -output "$OUT/hermes.framework/Versions/Current/hermes"

rm -rf "$OUT/obj" "$OUT/libPalmierRNHost.a"
echo "==> done"
du -sh "$OUT/PalmierRNHost.xcframework" "$OUT/hermes.framework"
