#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p tests/ai/.build
swiftc -swift-version 6 -parse-as-library -o tests/ai/.build/aicheck \
  tests/ai/main.swift \
  MeetingCoach/MeetingCoach/Engine/AIProvider.swift \
  MeetingCoach/MeetingCoach/Engine/AIClient.swift
 tests/ai/.build/aicheck
