# ax-probe: what does a call app expose through Accessibility?

Dev-only, read-only probe (`scripts/ax-probe.swift`). It is not part of the app
target or `project.yml`. Use it during a throwaway call to see which AXUIElement
attributes carry participant names and active-speaker state in Zoom, Teams and
Google Meet (Chrome).

## Run it

```bash
swift scripts/ax-probe.swift zoom   --seconds 90 --interval 2
swift scripts/ax-probe.swift teams  --seconds 90 --interval 2
swift scripts/ax-probe.swift chrome --seconds 90 --interval 2     # Meet tab must be the visible tab
# also: safari, or any bundle id (e.g. com.microsoft.edgemac)
```

Options: `--out DIR` (default: new dir under `/tmp`; refuses paths inside the repo),
`--redact`, `--max-nodes N` (4000), `--max-depth N` (50), `--no-enable`.

One-time setup: grant Accessibility to the terminal app that runs the command
(System Settings > Privacy & Security > Accessibility), then quit and reopen
that terminal. If it is not trusted the script prints these steps and exits 2.
It never triggers the system prompt.

## How to get a useful run

1. Start a call with a colleague or a second device of your own. Keep
   the call window visible on the current Space, not minimized.
2. Start the probe, then have people take turns speaking, one at a time, with
   gaps. Mute/unmute once. Turn captions on for a stretch.
3. Walks are limited to 80% of the interval. If ticks say `CAPPED(time)`, use a
   longer `--interval` (3 to 5) or a lower `--max-depth`; a capped walk only
   covers the start of the tree.

## What it does

- Read-only: no clicks, presses, focus or raise. The only attributes it sets are
  `AXManualAccessibility` then `AXEnhancedUserInterface`, for Chromium, Teams and
  unknown bundle ids, and it restores them on exit (Ctrl-C is fine). It reports
  which one took. For Teams it also tries helper processes if the main tree is empty.
- Each tick it walks the app's windows and records, per node: role, subrole, title,
  description, value (truncated), identifier, role description, selected, focused,
  enabled, frame, and the names and simple values of non-standard attributes.
- Chromium CPU of the target (all processes in the app bundle) is sampled before
  and after enabling the web tree.

## Output (in the output dir)

- `snapshot-start.json`, `snapshot-end.json`: full trees.
- `changes.jsonl`: one line per node whose attributes changed between ticks
  (`changed`), plus `added`/`removed` nodes. The attributes that flip when
  different people talk are the candidate speaking markers.
- `summary.txt` (also printed): node count, name-like labels and participant rows,
  most-changed attributes, flip candidates, status words (muted, speaking, host...),
  caption nodes, probe CPU time.

## Privacy

The output contains real names and call text. It stays in `/tmp`. Do not commit
it, paste it, or attach it anywhere. To share structure safely, run with
`--redact`: text values become `h:<hash>#<length>` (hash is salted per run, so it
only compares within one output dir), with status words such as `muted` kept as a
tag. Role, subrole, role description, identifiers and DOM ids/classes are kept.
Check a redacted file before sharing it anyway.
