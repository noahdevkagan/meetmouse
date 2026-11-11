#!/bin/bash
# Claude Desktop config merge: pure merge + temp-dir file layer only; never
# touches the real ~/Library/Application Support/Claude config.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=tests/claude-desktop/.build
mkdir -p "$OUT"
swiftc -parse-as-library -O -o "$OUT/check" \
  tests/claude-desktop/main.swift \
  MeetingCoach/MeetingCoach/Engine/ClaudeDesktopConfig.swift
"$OUT/check"
