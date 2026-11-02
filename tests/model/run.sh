#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=tests/model/.build
mkdir -p "$OUT"

swiftc -swift-version 6 -parse-as-library -O -o "$OUT/modelcheck" \
  tests/model/main.swift \
  "$SRC/Engine/OllamaClient.swift" \
  "$SRC/Engine/Mclog.swift" \
  "$SRC/Engine/AIProvider.swift" \
  "$SRC/Engine/AIClient.swift" \
  "$SRC/Engine/ClaudeAccount.swift" \
  "$SRC/Engine/PlatformSupport.swift" \
  "$SRC/Models/MeetingLanguage.swift" \
  "$SRC/Models/TranscriptLanguageDetector.swift" \
  "$SRC/ViewModels/SettingsViewModel.swift"

"$OUT/modelcheck"
