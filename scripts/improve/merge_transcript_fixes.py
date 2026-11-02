#!/usr/bin/env python3
"""Merge "Help improve transcripts" pairs into Resources/common_corrections.json.

Input: the JSON from GET https://meetmouse.com/api/admin/transcript-fixes-summary
(pairs taught with "Fix a misheard term" on 3+ different Macs, already scrubbed by
the app and again by the Worker). Output: an updated bundle and a Markdown report
for the weekly PR body. Run by .github/workflows/improve-weekly.yml; a human merges.

Rules (decisions.md 2026-11-02 "transcript fixes", same as Rhino's merge script):
  * at least MIN_INSTALLS different Macs (re-checked here, not just trusted)
  * the pair passes the shared scrub (tests/transcripts/scrub_cases.json holds the
    app, the Worker and this script to the same cases)
  * English only: the app applies the bundle to English meetings only
  * never rewrite a common English word (their->there would break everyone)
  * conflicts: one heard phrase with several fixes needs a clear winner (2x)
  * never a rule that grows on a second pass (corrected contains heard), chains
    into another entry, or collides with a built-in default term
  * existing entries are never changed or removed; at most MAX_NEW per run

Prints `changed=true|false` last, for GitHub Actions. `--self-test` checks the
script against the shared fixture without touching any file.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "MeetingCoach/MeetingCoach/Resources/common_corrections.json"
DEFAULTS_SWIFT = ROOT / "MeetingCoach/MeetingCoach/Engine/TranscriptCleanup.swift"
FIXTURE = ROOT / "tests/transcripts/scrub_cases.json"

MIN_INSTALLS = 3
MAX_NEW = 50
MAX_WORDS = 5
MAX_CHARS = 60
ALLOWED_LANGUAGES = {"", "en"}

# Same as TranscriptFixScrub.personalPatterns (Swift) and PERSONAL (web-share/src/transcriptFixes.js).
PERSONAL = [
    re.compile(r"[\x00-\x1f\x7f<>]"),
    re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+"),
    re.compile(r"\b(https?://|www\.)", re.I),
    re.compile(r"\b[a-z0-9-]+\.(com|net|org|io|app|ai|co|dev|me|us|uk|de)\b", re.I),
    re.compile(r"\d[\d\s.,-]{2,}\d"),
    re.compile(r"\d{4,}"),
    re.compile(r"\b(sk|pk|rk|ghp|gho|xox[abp]|akia)[-_][A-Za-z0-9]", re.I),
    re.compile(r"[A-Za-z0-9_\-]{24,}"),
    re.compile(r"\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{12,}\b"),
]

COMMON_WORDS = set("""
a about after again all also am an and any are as at be because been before being but by can
could did do does doing done down each even every few for from get go going good got had has
have he her here hers him his how i if in into is it its it's just know like make me might mine
more most much must my no not now of off on once one only or other our ours out over own said
same say see she should so some such than that the their theirs them then there these they
they're this those though through to too two under until up us very was way we well were what
when where which while who whom whose why will with would yes yet you your you're yours
accept except affect effect lose loose weather whether right write hear here know no new knew
buy by bye sea see week weak where wear were peace piece plain plane principal principle
meeting call team plan deal price time next steps
""".split())


def collapse(text: str) -> str:
    return " ".join(str(text).split())


def shareable(text: str) -> bool:
    return (
        0 < len(text) <= MAX_CHARS
        and any(ch.isalpha() for ch in text)
        and len(text.split(" ")) <= MAX_WORDS
        and not any(p.search(text) for p in PERSONAL)
    )


def pair_shareable(heard: str, corrected: str) -> bool:
    heard, corrected = collapse(heard), collapse(corrected)
    return heard != corrected and shareable(heard) and shareable(corrected)


def grows_on_second_pass(heard: str, corrected: str) -> bool:
    return re.search(r"(?<!\w)" + re.escape(heard) + r"(?!\w)", corrected, re.I) is not None


def default_terms(swift_source: Path = DEFAULTS_SWIFT) -> set[str]:
    """Lowercased canonicals + garbles of VocabularyNormalizer.defaultTerms."""
    taken: set[str] = set()
    if not swift_source.exists():
        return taken
    for match in re.finditer(r'Term\("([^"]+)"(?:,\s*garbles:\s*\[([^\]]*)\])?\)', swift_source.read_text()):
        taken.add(collapse(match.group(1)).lower())
        for garble in re.findall(r'"([^"]+)"', match.group(2) or ""):
            taken.add(collapse(garble).lower())
    return taken


def candidates(summary: dict, taken: set[str]) -> tuple[list[dict], list[str]]:
    skipped: list[str] = []
    by_heard: dict[str, list[dict]] = {}
    for raw in summary.get("pairs", []):
        heard = collapse(raw.get("heard", ""))
        corrected = collapse(raw.get("corrected", ""))
        installs = int(raw.get("installs", 0) or 0)
        languages = {l for l in str(raw.get("languages", "") or "").split(",")}
        label = f"`{heard}` → `{corrected}` ({installs} Macs)"
        if installs < MIN_INSTALLS:
            skipped.append(f"{label}: under {MIN_INSTALLS} Macs")
        elif not pair_shareable(heard, corrected):
            skipped.append(f"{label}: fails the share scrub")
        elif heard.lower() == corrected.lower():
            skipped.append(f"{label}: casing only (the app already self-heals casing of known terms)")
        elif not languages <= ALLOWED_LANGUAGES:
            skipped.append(f"{label}: non-English ({', '.join(sorted(languages - {''}))})")
        elif heard.lower() in COMMON_WORDS:
            skipped.append(f"{label}: rewrites a common word")
        elif grows_on_second_pass(heard, corrected):
            skipped.append(f"{label}: would grow on a second pass")
        elif heard.lower() in taken or corrected.lower() in taken:
            skipped.append(f"{label}: overlaps a built-in term")
        else:
            by_heard.setdefault(heard.lower(), []).append(
                {"heard": heard, "corrected": corrected, "installs": installs}
            )
    picked: list[dict] = []
    for options in by_heard.values():
        options.sort(key=lambda p: -p["installs"])
        best = options[0]
        if len(options) > 1 and best["installs"] < 2 * options[1]["installs"]:
            alts = ", ".join(f"`{o['corrected']}` ({o['installs']})" for o in options)
            skipped.append(f"`{best['heard']}`: no clear winner between {alts}")
            continue
        picked.append(best)
    return picked, skipped


def merge(bundle: dict, picked: list[dict]) -> tuple[dict, list[dict], list[str]]:
    entries = list(bundle.get("entries", []))
    heards = {collapse(e["heard"]).lower() for e in entries}
    correcteds = {collapse(e["corrected"]).lower() for e in entries}
    added: list[dict] = []
    skipped: list[str] = []
    for pair in sorted(picked, key=lambda p: (-p["installs"], p["heard"].lower())):
        if len(added) >= MAX_NEW:
            break
        h, c = pair["heard"].lower(), pair["corrected"].lower()
        if h in heards:
            continue  # existing entries are never changed by the bot
        if h in correcteds or c in heards:
            skipped.append(f"`{pair['heard']}` → `{pair['corrected']}`: would chain with an existing entry")
            continue
        heards.add(h)
        correcteds.add(c)
        added.append(pair)
    entries.extend(added)
    entries.sort(key=lambda e: e["heard"].lower())
    out = dict(bundle)
    out["entries"] = entries
    return out, added, skipped


def report(added: list[dict], skipped: list[str], generated_at: str) -> str:
    lines = [
        "### Transcripts",
        "",
        "Weekly transcript update from people who opted in to **Help improve transcripts**. "
        f"Summary generated {generated_at or 'just now'}. Each pair below was taught with "
        f"\"Fix a misheard term\" on at least {MIN_INSTALLS} different Macs. `tests/transcripts` "
        "replays every bundled pair; a person's own vocabulary always overrides these, and "
        "they apply to English meetings only.",
        "",
        "#### Added",
    ]
    lines += [f"- `{p['heard']}` → `{p['corrected']}` ({p['installs']} Macs)" for p in added] or ["- none"]
    if skipped:
        lines += ["", "<details><summary>Skipped</summary>", ""] + [f"- {s}" for s in skipped] + ["", "</details>"]
    lines += ["", "Review before merging: a wrong rule rewrites everyone's transcripts."]
    return "\n".join(lines) + "\n"


def run(summary: dict, bundle: dict, taken: set[str]) -> tuple[dict, list[dict], str]:
    picked, skipped = candidates(summary, taken)
    updated, added, more_skipped = merge(bundle, picked)
    return updated, added, report(added, skipped + more_skipped, str(summary.get("generatedAt", "")))


def fetch(url: str, token: str) -> dict:
    import urllib.request

    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 (fixed https URL)
        return json.loads(response.read().decode())


def self_test() -> int:
    cases = json.loads(FIXTURE.read_text())["cases"]
    bad = [c for c in cases if pair_shareable(c["heard"], c["corrected"]) != c["share"]]
    for c in bad:
        print(f"  FAIL fixture {c['heard']!r} -> {c['corrected']!r}: expected share={c['share']}")
    json.loads(BUNDLE.read_text())  # the bundle must stay valid JSON
    print("merge_transcript_fixes self-test:", "FAILED" if bad else "ok")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--summary", type=Path, help="summary JSON file (instead of --fetch)")
    ap.add_argument("--fetch", help="admin summary URL")
    ap.add_argument("--token-env", default="FEEDBACK_ADMIN_TOKEN")
    ap.add_argument("--bundle", type=Path, default=BUNDLE)
    ap.add_argument("--report", type=Path, default=Path("evidence-transcripts.md"))
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    import os

    if args.summary:
        summary = json.loads(args.summary.read_text())
    elif args.fetch:
        token = os.environ.get(args.token_env, "")
        if not token:
            print(f"no {args.token_env} secret: nothing to do", file=sys.stderr)
            print("changed=false")
            return 0
        try:
            summary = fetch(args.fetch, token)
        except Exception as exc:  # network/auth trouble must not fail the weekly run
            print(f"summary unavailable ({exc}): nothing to do", file=sys.stderr)
            print("changed=false")
            return 0
    else:
        ap.error("--summary or --fetch is required")

    bundle = json.loads(args.bundle.read_text())
    updated, added, text = run(summary, bundle, default_terms())
    if added:
        args.bundle.write_text(json.dumps(updated, indent=2, ensure_ascii=False) + "\n")
        args.report.write_text(text)
    print(f"added {len(added)}", file=sys.stderr)
    print(f"changed={'true' if added else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
