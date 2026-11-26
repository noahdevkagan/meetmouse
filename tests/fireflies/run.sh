#!/bin/bash
# Fireflies import gate: paging, dedupe, rate-limit stop and session-file
# shape against canned API replies (no network, no API key).
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/fireflies/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/firefliescheck" \
  tests/fireflies/main.swift \
  "$SRC/Engine/FirefliesImporter.swift" \
  "$SRC/Engine/GranolaImporter.swift" \
  "$SRC/Models/TranscriptSearch.swift" \
  "$SRC/Models/TranscriptStore.swift" \
  "$SRC/Models/AppSupport.swift"
"$OUT/firefliescheck"
