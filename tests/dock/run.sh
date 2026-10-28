#!/bin/bash
# Show in Dock preference: default and activation-policy mapping.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/dock/.build
mkdir -p "$OUT"
swiftc -parse-as-library -O -o "$OUT/dockcheck" \
  tests/dock/main.swift \
  "$SRC/App/DockVisibility.swift"
"$OUT/dockcheck"
