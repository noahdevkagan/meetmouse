#!/bin/bash
# Speaker attribution on a scripted three-voice call, through the app's real
# SpeakerDiarizer: live labels vs the whole-call final pass (see
# Sources/rig/main.swift). Needs Apple Silicon, three English `say` voices,
# and network on the first run (FluidAudio downloads its models).
#
#   tests/diarization/run.sh
#
# Exit 0 pass, 1 the final pass did not run or attributes worse than the
# live labels, 2 this machine cannot run the check.
set -euo pipefail
cd "$(dirname "$0")"

echo "-- building rig (compiles the app's SpeakerDiarizer.swift)"
swift build -c release 2>&1 | tail -3
.build/release/rig
