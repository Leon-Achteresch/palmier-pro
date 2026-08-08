#!/bin/bash
set -euo pipefail

# react-native-macos 0.81 predates Xcode 26, whose libc++ dropped the transitive includes it
# relied on. Applied here rather than committed into node_modules so npm install stays clean.

cd "$(dirname "$0")"
RN="node_modules/react-native-macos"

[ -d "$RN" ] || { echo "missing $RN — run npm install first"; exit 1; }

apply_include() {
  local file="$1" header="$2" anchor="$3"
  if grep -q "^#include <$header>" "$file"; then return; fi
  sed -i '' "s|$anchor|$anchor\\
\\
#include <$header>|" "$file"
  echo "    + <$header> -> ${file#$RN/}"
}

apply_include "$RN/ReactCommon/hermes/executor/HermesExecutorFactory.cpp" thread '#include "HermesExecutorFactory.h"'

echo "  react-native-macos patched"
