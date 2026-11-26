#!/bin/bash
# Team space gate: key derivation and sealing must match the team page's
# script and the Worker (same vectors as web-share/test/teams.test.mjs),
# invite links parse strictly, and membership round-trips on disk.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/team/.build
mkdir -p "$OUT"
swiftc -parse-as-library -O -o "$OUT/teamcheck" \
  tests/team/main.swift \
  "$SRC/Models/TeamSpace.swift" \
  "$SRC/Models/WebSharing.swift" \
  "$SRC/Models/MeetingReview.swift" \
  "$SRC/Models/AppSupport.swift"
"$OUT/teamcheck"
