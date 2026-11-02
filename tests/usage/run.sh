#!/bin/bash
# Opt-in usage counts: off by default, opt-out wipes the identity and unsent
# days, only completed days are sent, at most once a day. Pure logic, no network.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=tests/usage/.build
mkdir -p "$OUT"
swiftc -parse-as-library -O -o "$OUT/usagecheck" \
  tests/usage/main.swift \
  MeetingCoach/MeetingCoach/Engine/UsageReporter.swift
"$OUT/usagecheck"
