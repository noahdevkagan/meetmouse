#!/usr/bin/env python3
"""Weekly coaching improve loop (decisions.md 2026-11-02 "coaching feedback").

Reads the aggregate feedback summary from the web-share Worker (opted-in
users' nudge ratings — ids and numbers only) and proposes bounded tweaks to
MeetingCoach/MeetingCoach/Engine/FieldTuning.swift:

  * helpful rate < 50%  -> relax the signal (multiplier up, at most +10%/run)
  * helpful rate > 75%  -> tighten slightly (at most -5%/run, needs more data)
  * helpful rate < 30%  -> flagged for a human: likely needs a rework or to be
                           off by default; the loop never disables a signal
  * every value stays inside FieldTuning.clampRange (0.67-1.5)

Only signals with >= MIN_INSTALLS distinct installs (enforced server-side)
and >= MIN_RATINGS ratings are touched. "custom" (user rubric signals) is
reported but never tuned. Outputs an evidence table (markdown) for the PR
body and appends a record to bench/field-feedback.jsonl for the scorecard.

Usage:
  propose.py --summary FILE [--evidence OUT.md]   # apply to the repo
  propose.py --fetch URL --token-env NAME ...     # fetch the summary first
  propose.py --self-test                          # used by tests/feedback
Prints "changed=true|false" last (the workflow reads it).
"""

import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIELD_FILE = REPO / "MeetingCoach" / "MeetingCoach" / "Engine" / "FieldTuning.swift"
HISTORY = REPO / "bench" / "field-feedback.jsonl"

CLAMP = (0.67, 1.5)
MIN_RATINGS = 20
MIN_RATINGS_TIGHTEN = 40
MAX_RELAX_STEP = 0.10
MAX_TIGHTEN_STEP = 0.05
RELAX_BELOW = 0.50
TIGHTEN_ABOVE = 0.75
FLAG_BELOW = 0.30
NOT_TUNED = {"custom"}

BLOCK = re.compile(
    r"(    // BEGIN FIELD TUNING\n)(.*?)(\n    // END FIELD TUNING)", re.S)
ENTRY = re.compile(r'"([A-Za-z]+)"\s*:\s*([0-9.]+)')


def read_table(text: str) -> dict[str, float]:
    m = BLOCK.search(text)
    if not m:
        raise SystemExit("FieldTuning.swift: BEGIN/END FIELD TUNING markers not found")
    return {k: float(v) for k, v in ENTRY.findall(m.group(2))}


def render_table(text: str, table: dict[str, float]) -> str:
    if table:
        lines = ["    static let multipliers: [String: Double] = ["]
        lines += [f'        "{k}": {table[k]:.2f},' for k in sorted(table)]
        lines.append("    ]")
        body = "\n".join(lines)
    else:
        body = "    static let multipliers: [String: Double] = [:]"
    m = BLOCK.search(text)
    return text[:m.start(2)] + body + text[m.end(2):]


def clamp(v: float) -> float:
    return min(max(v, CLAMP[0]), CLAMP[1])


def propose(summary: dict, table: dict[str, float]) -> tuple[dict[str, float], list[dict]]:
    """Pure: returns the new table and one evidence row per reported signal."""
    new = dict(table)
    rows = []
    for s in summary.get("signals", []):
        key, rate, n = s["signal"], float(s["helpfulRate"]), int(s["ratings"])
        before = table.get(key, 1.0)
        after, action = before, "hold"
        if key in NOT_TUNED:
            action = "not tuned (user rubric signals)"
        elif n < MIN_RATINGS:
            action = f"hold (needs {MIN_RATINGS} ratings)"
        elif rate < RELAX_BELOW:
            after = clamp(before * (1 + min(MAX_RELAX_STEP, RELAX_BELOW - rate)))
            action = "relax (fewer nudges)"
        elif rate > TIGHTEN_ABOVE and n >= MIN_RATINGS_TIGHTEN:
            after = clamp(before * (1 - min(MAX_TIGHTEN_STEP, (rate - TIGHTEN_ABOVE) / 2)))
            action = "tighten (more nudges)"
        after = round(after, 2)
        if abs(after - before) < 0.01:
            after = before
            if action.startswith(("relax", "tighten")):
                action = "hold (at clamp)"
        if key not in NOT_TUNED and after != 1.0:
            new[key] = after
        elif key in new and after == 1.0:
            del new[key]
        rows.append({
            "signal": key, "installs": s["installs"], "ratings": n, "helpfulRate": rate,
            "before": before, "after": after, "action": action, "flag": rate < FLAG_BELOW,
            "features": s.get("features", {}),
        })
    return new, rows


def fmt_feature(dist: dict) -> str:
    h, nh = dist.get("helpful", {}), dist.get("notHelpful", {})
    def med(d):
        return "–" if d.get("median") is None else f"{d['median']:g}"
    return f"{med(h)} / {med(nh)}"


def evidence_markdown(rows: list[dict], summary: dict) -> str:
    out = [
        "Proposed by the weekly improve loop from opted-in coaching feedback "
        f"(signals rated by ≥{summary.get('minInstalls', 5)} installs). "
        "Multipliers apply to threshold and cooldown; >1 = fewer nudges. "
        "Feature columns: median when rated helpful / not helpful.",
        "",
        "| signal | installs | ratings | helpful | multiplier | action | your share | your last turn (s) | minute |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        f = r["features"]
        flag = " ⚠️" if r["flag"] else ""
        out.append(
            f"| {r['signal']}{flag} | {r['installs']} | {r['ratings']} | {r['helpfulRate']:.0%} | "
            f"{r['before']:.2f} → {r['after']:.2f} | {r['action']} | "
            f"{fmt_feature(f.get('youShare', {}))} | {fmt_feature(f.get('lastYouTurnSec', {}))} | "
            f"{fmt_feature(f.get('minute', {}))} |")
    flagged = [r["signal"] for r in rows if r["flag"]]
    if flagged:
        out += ["", f"⚠️ Under {FLAG_BELOW:.0%} helpful: {', '.join(flagged)}. "
                "The loop only relaxes these; consider reworking the signal or turning it off by default."]
    return "\n".join(out) + "\n"


def fetch(url: str, token: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def self_test() -> int:
    text = FIELD_FILE.read_text()
    table = read_table(text)
    for k, v in table.items():
        assert CLAMP[0] <= v <= CLAMP[1], f"{k}={v} outside clamp"
    assert read_table(render_table(text, table)) == {k: round(v, 2) for k, v in table.items()}
    filled = render_table(text, {"talkTime": 1.1, "nextSteps": 0.95})
    assert read_table(filled) == {"nextSteps": 0.95, "talkTime": 1.1}
    assert read_table(render_table(filled, {})) == {}

    def sig(name, rate, n=60):
        return {"signal": name, "installs": 9, "ratings": n, "helpfulRate": rate, "features": {}}
    summary = {"minInstalls": 5, "signals": [
        sig("talkTime", 0.2), sig("nextSteps", 0.9), sig("stackedQuestions", 0.6),
        sig("goingQuiet", 0.3, n=5), sig("custom", 0.1), sig("voiceShare", 0.1),
    ]}
    new, rows = propose(summary, {"voiceShare": 1.48})
    assert new["talkTime"] == 1.1, new                   # capped at +10%
    assert new["nextSteps"] == 0.95, new                  # capped at -5%
    assert "stackedQuestions" not in new                  # in the dead band
    assert "goingQuiet" not in new                        # too few ratings
    assert "custom" not in new                            # never tuned
    assert new["voiceShare"] == 1.5, new                  # clamped
    assert [r["flag"] for r in rows] == [True, False, False, False, True, True]
    md = evidence_markdown(rows, summary)
    assert "talkTime ⚠️" in md and "1.00 → 1.10" in md
    print("propose.py self-test: ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary")
    ap.add_argument("--fetch")
    ap.add_argument("--token-env", default="FEEDBACK_ADMIN_TOKEN")
    ap.add_argument("--evidence", default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    if args.fetch:
        token = os.environ.get(args.token_env, "")
        if not token:
            print(f"no {args.token_env} set — nothing to do")
            print("changed=false")
            return 0
        summary = fetch(args.fetch, token)
    elif args.summary:
        summary = json.loads(Path(args.summary).read_text())
    else:
        ap.error("--summary or --fetch required")

    if not summary.get("signals"):
        print("not enough feedback yet (no signal rated by enough installs)")
        print("changed=false")
        return 0

    text = FIELD_FILE.read_text()
    table = read_table(text)
    new, rows = propose(summary, table)
    md = evidence_markdown(rows, summary)
    print(md)
    if args.evidence:
        Path(args.evidence).write_text(md)

    changed = new != table
    if changed:
        FIELD_FILE.write_text(render_table(text, new))
        date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        record = {"date": date, "signals": {r["signal"]: {
            "helpfulRate": r["helpfulRate"], "ratings": r["ratings"], "installs": r["installs"],
            "multiplier": r["after"]} for r in rows}}
        with open(HISTORY, "a") as f:
            f.write(json.dumps(record) + "\n")
    print(f"changed={'true' if changed else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
