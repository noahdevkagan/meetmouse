#!/bin/bash
# ASR trend case (non-blocking): a ~2-minute scripted two-speaker "hard"
# conversation — fast handoffs, an interruption, one-word backchannels,
# numbers, proper nouns (Nguyen, Priya, Kubernetes), acronyms, and speech
# rates from 155 to 210 wpm — through the real ParakeetPipeline.
#
# The point is longitudinal: run it after ASR-adjacent changes and compare
# the WER across commits in bench/asr-history.jsonl. Same audio every time
# (cached by gen_audio.sh), and the rig runs on its audio clock
# (RIG_CLOCK=audio: ticks per second of fed audio, no sleeping), so the
# same code gives the same transcript and any movement is the code, not
# scheduling. Three series, each recorded under its own corpus name:
#   synthetic-hard-det    mic channel settings (floor 0.006, silence 0.9 s)
#   synthetic-hard-them   Them channel settings (floor 0.002, silence 2.0 s)
#   synthetic-hard-noisy  mic settings + fixed-seed white noise, RMS 0.003
#                         (under the mic floor: room hiss in the gaps)
# The older corpus "synthetic-hard" was the real-time rig (wall-clock ticks,
# 8-13 errors on identical audio); it is no longer recorded.
#
# Each series runs twice; differing outputs print a loud warning (the
# determinism check — non-blocking). Takes well under real time.
#
#   tests/asr/hard.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "-- building rig (compiles the app's ParakeetTranscriber.swift)"
swift build -c release 2>&1 | tail -1
./gen_audio.sh

mkdir -p .out
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# run_series <corpus> <voice floor> <commit silence> <noise rms>
run_series() {
    local corpus=$1 floor=$2 silence=$3 noise=$4 run rc
    local ok1=0 ok2=0
    for run in 1 2; do
        rc=0
        RIG_CLOCK=audio RIG_VOICE_FLOOR=$floor RIG_COMMIT_SILENCE=$silence \
            RIG_NOISE_RMS=$noise \
            .build/release/rig cases/case_hard.json normal \
            > ".out/${corpus}.${run}.txt" 2> ".out/${corpus}.${run}.log" || rc=$?
        # A run counts only if the rig exited cleanly and reached DONE —
        # a crash or failed model load must not be scored as a WER spike.
        if [ "$rc" = "0" ] && grep -q '^DONE' ".out/${corpus}.${run}.txt"; then
            eval "ok${run}=1"
        fi
    done
    if [ "$ok1" != "1" ]; then
        echo "${corpus}: rig did not finish (see tests/asr/.out/${corpus}.1.log) — not recorded"
        return 0
    fi
    if [ "$ok2" = "1" ] && ! diff -q <(grep '^UTT' ".out/${corpus}.1.txt") \
                 <(grep '^UTT' ".out/${corpus}.2.txt") > /dev/null; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "!! WARNING: ${corpus} is NOT deterministic — two runs on identical"
        echo "!! audio gave different utterances. Trend points are unreliable."
        echo "!!   diff tests/asr/.out/${corpus}.1.txt tests/asr/.out/${corpus}.2.txt"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi

    local out
    out=$(python3 score.py hard ".out/${corpus}.1.txt" "$corpus")
    echo "$out" | grep -v '^JSON'
    echo "$out" | sed -n $'s/^JSON\t//p' | python3 -c "
import json, sys
r = json.load(sys.stdin)
r.update(commit='$commit', date='$date')
print(json.dumps(r))" >> ../../bench/asr-history.jsonl
}

run_series synthetic-hard-det   0.006 0.9 0
run_series synthetic-hard-them  0.002 2.0 0
run_series synthetic-hard-noisy 0.006 0.9 0.003

echo "recorded to bench/asr-history.jsonl (@ $commit)"
python3 - <<'PY'
import json
rows = [json.loads(l) for l in open("../../bench/asr-history.jsonl") if l.strip()]
for name in ("synthetic-hard-det", "synthetic-hard-them", "synthetic-hard-noisy"):
    print(f"-- {name} trend (last 5)")
    for r in [r for r in rows if r.get("corpus") == name][-5:]:
        c = r["combined"]
        print(f"  {r['date']}  @{r['commit']}  WER {c['rate']:.1%}  "
              f"({c['errors']} errs / {c['refWords']} words, {r['utterances']} utts)")
PY
