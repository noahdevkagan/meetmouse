#!/bin/bash
# Silent-mic gate: compiles the app's real MicSilenceMonitor.swift and checks
# when a mic that delivers only digital zeros is surfaced to the user.
# Pure logic — runs in seconds.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/micsilence/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/micsilencecheck" \
  tests/micsilence/main.swift \
  MeetingCoach/MeetingCoach/Engine/MicSilenceMonitor.swift
"$OUT/micsilencecheck"
