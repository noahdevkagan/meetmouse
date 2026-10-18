#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/freetier/.build
mkdir -p "$OUT"
swiftc -parse-as-library -O -o "$OUT/freetiercheck" \
  tests/freetier/main.swift \
  tests/freetier/stubs.swift \
  "$SRC/Models/UsageGate.swift" \
  "$SRC/Models/ReferralLink.swift"
"$OUT/freetiercheck"
