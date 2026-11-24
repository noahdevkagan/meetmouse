#!/bin/bash
# Parakeet download retry gate: compiles the app's real ParakeetDownloadRetry.swift
# and checks which failures get another resume round, the backoff schedule,
# the user-facing summary, and the Terminal fallback command. Pure logic.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/download/.build
mkdir -p "$OUT"
swiftc -O -o "$OUT/downloadcheck" \
  tests/download/main.swift \
  MeetingCoach/MeetingCoach/Engine/ParakeetDownloadRetry.swift
"$OUT/downloadcheck"
