#!/bin/bash
# Notes-accuracy bench: real notes prompt, made-up meeting, local Ollama.
# Informational only — not part of the push gate. See main.swift.
# Usage: bench/notes/run.sh            (Ollama on 127.0.0.1:11434)
#        OLLAMA_PORT=11555 NOTES_MODEL=qwen3.5:4b NOTES_MODES=standard,roomy bench/notes/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC=MeetingCoach/MeetingCoach
OUT=bench/notes/.build
mkdir -p "$OUT" bench/notes/.out
swiftc -O -o "$OUT/notesbench" \
  bench/notes/main.swift \
  "$SRC/Engine/PromptBuilder.swift" \
  "$SRC/Models/PreCallContext.swift" \
  "$SRC/Models/Nudge.swift" \
  "$SRC/Models/Utterance.swift"
NOTES_COMMIT="$(git rev-parse --short HEAD)" "$OUT/notesbench" "$PWD/bench/notes"
