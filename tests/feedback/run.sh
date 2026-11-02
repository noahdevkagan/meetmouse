#!/bin/bash
# Opt-in coaching feedback: off by default, opt-out wipes queue + id, the
# payload carries ids and numbers only (no free text, no custom rubric ids),
# and the shipped field-tuning table stays inside its clamp. Pure logic, no
# network.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/feedback/.build
mkdir -p "$OUT"
swiftc -parse-as-library -O -o "$OUT/feedbackcheck" \
  tests/feedback/main.swift \
  "$SRC/Engine/FeedbackReporter.swift" \
  "$SRC/Engine/FieldTuning.swift" \
  "$SRC/Engine/TuningTypes.swift"
"$OUT/feedbackcheck"

# The improve script must be able to parse and rewrite the table it edits.
python3 scripts/improve/propose.py --self-test
