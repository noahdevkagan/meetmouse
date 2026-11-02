"""Rules of the weekly transcript-fix merge (decisions.md 2026-11-02 "transcript fixes")."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import merge_transcript_fixes as m  # noqa: E402


def pair(heard, corrected, installs=3, languages="en"):
    return {"heard": heard, "corrected": corrected, "installs": installs, "languages": languages}


class MergeRules(unittest.TestCase):
    def run_merge(self, pairs, entries=None, taken=None):
        return m.run({"pairs": pairs}, {"entries": entries or []}, taken if taken is not None else m.default_terms())

    def test_shared_fixture_parity(self):
        for case in json.loads(m.FIXTURE.read_text())["cases"]:
            with self.subTest(case=case):
                self.assertEqual(m.pair_shareable(case["heard"], case["corrected"]), case["share"])

    def test_adds_pairs_from_three_macs(self):
        _, added, _ = self.run_merge([pair("cooper net ease", "Kubernetes", 4), pair("fig ma", "Figma", 2)])
        self.assertEqual([a["corrected"] for a in added], ["Kubernetes"])

    def test_install_count_rechecked(self):
        _, added, _ = self.run_merge([pair("fig ma", "Figma", 2)])
        self.assertEqual(added, [])

    def test_english_only(self):
        _, added, _ = self.run_merge([pair("fig ma", "Figma", 5, "en,es"), pair("note ion", "Notion", 5, "")])
        self.assertEqual([a["corrected"] for a in added], ["Notion"])

    def test_common_words_and_growth(self):
        _, added, _ = self.run_merge([pair("their", "there", 9), pair("ops", "DevOps ops", 9)])
        self.assertEqual(added, [])

    def test_scrub_applied(self):
        _, added, _ = self.run_merge([pair("call me", "555 123 4567", 9), pair("site", "acme.com", 9)])
        self.assertEqual(added, [])

    def test_clear_winner_only(self):
        _, added, _ = self.run_merge([pair("sales force", "Salesforce", 5), pair("sales force", "SalesForce", 4)])
        self.assertEqual(added, [])
        _, added, _ = self.run_merge([pair("sales force", "Salesforce", 8), pair("sales force", "SalesForce", 3)])
        self.assertEqual([a["corrected"] for a in added], ["Salesforce"])

    def test_built_in_defaults_skipped(self):
        taken = m.default_terms()
        self.assertIn("tidy cow", taken)  # parsed from TranscriptCleanup.swift
        _, added, _ = self.run_merge([pair("tidy cow", "Tidy Cow", 9), pair("app sumo", "App Sumo", 9)])
        self.assertEqual(added, [])

    def test_existing_never_changed_and_no_chains(self):
        existing = [{"heard": "fig ma", "corrected": "Figma", "installs": 3}]
        out, added, _ = self.run_merge(
            [pair("fig ma", "FigJam", 30), pair("figma", "Figma Design", 9), pair("fig mah", "fig ma", 9)],
            entries=existing,
        )
        self.assertEqual(added, [])
        self.assertEqual(out["entries"], existing)

    def test_cap_per_run(self):
        pairs = [pair(f"term number {chr(97 + i // 26)}{chr(97 + i % 26)}", f"Term{chr(65 + i // 26)}{chr(65 + i % 26)}", 3) for i in range(80)]
        _, added, _ = self.run_merge(pairs)
        self.assertEqual(len(added), m.MAX_NEW)

    def test_cli_writes_bundle_and_report(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "summary.json").write_text(json.dumps({"pairs": [pair("cooper net ease", "Kubernetes", 4)]}))
            (d / "bundle.json").write_text(json.dumps({"entries": []}))
            m.main(["--summary", str(d / "summary.json"), "--bundle", str(d / "bundle.json"), "--report", str(d / "r.md")])
            self.assertEqual(json.loads((d / "bundle.json").read_text())["entries"][0]["corrected"], "Kubernetes")
            self.assertIn("Kubernetes", (d / "r.md").read_text())

    def test_no_token_exits_clean(self):
        self.assertEqual(m.main(["--fetch", "https://example.invalid/x", "--token-env", "NO_SUCH_SECRET_SET"]), 0)

    def test_shipped_bundle_valid(self):
        data = json.loads(m.BUNDLE.read_text())
        self.assertIsInstance(data["entries"], list)


if __name__ == "__main__":
    unittest.main()
