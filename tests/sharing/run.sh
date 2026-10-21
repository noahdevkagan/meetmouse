#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/sharing/.build
mkdir -p "$OUT"
swiftc -parse-as-library -O -o "$OUT/sharingcheck" \
  tests/sharing/main.swift \
  "$SRC/Models/WebSharing.swift" \
  "$SRC/Models/MeetingReview.swift" \
  "$SRC/Models/AppSupport.swift"
"$OUT/sharingcheck"

swiftc -parse-as-library -O -o "$OUT/sharepromptcheck" \
  tests/sharing/share_prompt.swift \
  "$SRC/Models/SharePrompt.swift"
"$OUT/sharepromptcheck"

(cd web-share && npm test)
