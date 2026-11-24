#!/bin/bash
# End-to-end Parakeet download test against real Hugging Face (needs network,
# ~1-2 GB of transfer, ~10 min). Runs on GitHub's macOS runners via
# .github/workflows/download-e2e.yml; locally: bash tests/download-e2e/run.sh
# WARNING: deletes and re-downloads the cached Parakeet v3 model.
#
# 1. before the fix: one bare AsrModels.download call fails when the
#    connection keeps dropping mid-file ("connection lost"), as reported
# 2. the fix: the app's ParakeetDownloadState resumes through twice the drops
#    that defeated one call
# 3. the downloaded models load
# 4-5. the Terminal fallback command works with Apple's and Homebrew's Python,
#    and its files load
set -uo pipefail
cd "$(dirname "$0")"

echo "-- building rig (compiles the app's ParakeetDownloadState.swift)"
swift build -c release 2>&1 | tail -3
RIG=.build/release/rig
MODELS="$("$RIG" path)"   # FluidAudio's own path, not a guess
echo "   model folder: $MODELS"
CUT_MB=${CUT_MB:-8}
mkdir -p .out
fail=0
pass() { echo "PASS: $1"; }
flunk() { echo "FAIL: $1"; fail=1; }
reset() { rm -rf "$MODELS" /tmp/meetmouse-hf; }

PROXY=
start_proxy() {  # port cuts name
    python3 flaky_proxy.py "$1" "$2" "$CUT_MB" > ".out/proxy-$3.log" 2>&1 &
    PROXY=$!
    sleep 1
}
stop_proxy() { kill "$PROXY" 2>/dev/null; wait "$PROXY" 2>/dev/null; echo "   proxy: $(grep -c '^CUT' ".out/proxy-$1.log") cuts"; }

echo "-- 1. before the fix: single download call, connection drops every ${CUT_MB} MB"
reset
start_proxy 8901 100000 single
https_proxy=http://127.0.0.1:8901 "$RIG" single > .out/single.txt 2> .out/single.log
stop_proxy single
cat .out/single.txt
if grep -q "RESULT single fail transient=true" .out/single.txt; then
    pass "a single download call gives up after dropped connections (the reported bug)"
else
    flunk "single call should have failed with a transient error; the cut setup isn't reproducing the bug"
fi

# Drops it took to defeat one call; the app gets two rounds' worth plus a few,
# so rounds 1 and 2 fail the way the single call did and round 3 finishes.
PER_CALL=$(grep -c '^CUT' .out/proxy-single.log)
BUDGET=$((PER_CALL * 2 + 2))
echo "-- 2. the fix: app download state, $BUDGET drops (one call gave up after $PER_CALL)"
reset
start_proxy 8902 "$BUDGET" app
https_proxy=http://127.0.0.1:8902 "$RIG" app > .out/app.txt 2> .out/app.log
stop_proxy app
cat .out/app.txt
grep "\[Parakeet\]" .out/app.log | sed 's/^/   /'
if grep -q "RESULT app ok" .out/app.txt; then
    pass "app download finished through $BUDGET dropped connections"
else
    flunk "app download did not finish"
fi
if grep -qE "download complete \(round [3-6]\)" .out/app.log; then
    pass "it needed the extra resume rounds (one round would have failed)"
else
    flunk "expected completion in round 3+; check the log above"
fi

echo "-- 3. the downloaded models load"
"$RIG" load | tee .out/load-app.txt | grep RESULT
grep -q "RESULT load ok" .out/load-app.txt && pass "app-downloaded models load" || flunk "app-downloaded models don't load"

CMD=$("$RIG" command)
echo "-- Terminal fallback command:"
echo "   $CMD"

echo "-- 4. Terminal command with Apple's Python (/usr/bin/python3)"
reset
/usr/bin/python3 --version
if PATH="/usr/bin:/bin" bash -c "$CMD" > .out/cmd-apple.log 2>&1; then
    tail -1 .out/cmd-apple.log
    "$RIG" load | tee .out/load-apple.txt | grep RESULT
    grep -q "RESULT load ok" .out/load-apple.txt && pass "command works with Apple's Python" || flunk "command (Apple Python) downloaded files that don't load"
else
    tail -20 .out/cmd-apple.log; flunk "command failed with Apple's Python"
fi
du -sh "$MODELS" 2>/dev/null | sed 's/^/   size: /'

echo "-- 5. Terminal command with Homebrew's Python"
reset
BREW_BIN="$(brew --prefix)/bin"
[ -x "$BREW_BIN/python3" ] || brew install python >/dev/null
"$BREW_BIN/python3" --version
if PATH="$BREW_BIN:/usr/bin:/bin" bash -c "$CMD" > .out/cmd-brew.log 2>&1; then
    tail -1 .out/cmd-brew.log
    "$RIG" load | tee .out/load-brew.txt | grep RESULT
    grep -q "RESULT load ok" .out/load-brew.txt && pass "command works with Homebrew's Python" || flunk "command (Homebrew Python) downloaded files that don't load"
else
    tail -20 .out/cmd-brew.log; flunk "command failed with Homebrew's Python"
fi

[ $fail = 0 ] && echo "download e2e: all checks passed" || echo "DOWNLOAD E2E FAILED"
exit $fail
