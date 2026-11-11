# ax-probe: what does a call app expose through Accessibility?

Dev-only, read-only probe (`scripts/ax-probe.swift`). It is not part of the app
target or `project.yml`. Use it during a throwaway call to see which AXUIElement
attributes carry participant names and active-speaker state in Zoom, Teams and
Google Meet (Chrome).

## Run it

```bash
swift scripts/ax-probe.swift zoom   --seconds 120 --interval 2
swift scripts/ax-probe.swift teams  --seconds 120 --interval 2   # new Teams (com.microsoft.teams2), else classic
swift scripts/ax-probe.swift chrome --seconds 120 --interval 2 --window meet --max-nodes 15000
# also: teams-classic, safari, or any bundle id (e.g. com.microsoft.edgemac)
```

Options:

| Option | Default | What it does |
|---|---|---|
| `--seconds N` | 60 | Total run time. Ctrl-C ends early and still writes everything. |
| `--interval N` | 1 | Seconds between tree walks. Each walk gets 80% of it. |
| `--window TEXT` | all windows | Only walk windows whose title contains TEXT. For Meet, put the call in its own Chrome window. |
| `--max-nodes N`, `--max-depth N` | 4000, 50 | Caps per walk. |
| `--out DIR` | new dir under `/tmp` | Must be new or empty. Refuses any path inside a git checkout. |
| `--redact` | off | Hash text values (see Privacy). |
| `--no-enable` | off | Do not set the accessibility-enable flags. |

One-time setup: grant Accessibility to the terminal app that runs the command
(System Settings > Privacy & Security > Accessibility), then quit and reopen
that terminal. If it is not trusted the script prints these steps and exits 2.
It never triggers the system prompt.

## How to get a useful run

1. Start a call with a colleague or a second device of your own. Keep
   the call window visible on the current Space, not minimized.
2. Start the probe, then have people take turns speaking, one at a time, with
   gaps of a few seconds. Mute/unmute once. Turn captions on for a stretch.
   Note the times, so you can line them up with `ts` in `changes.jsonl`.
3. If ticks print `CAPPED(time)` or `CAPPED(nodes)`, the walk only covered
   the start of the tree. Raise `--interval` (3 to 5) and `--max-nodes`, or use
   `--window`. `CAPPED(unresponsive)` means the app stopped answering AX calls.

## What it does

- Read-only: it reads attributes only. No actions, clicks, focus or raise. The
  only writes are `AXManualAccessibility`, falling back to `AXEnhancedUserInterface`,
  set on the application element of Chromium browsers, Teams and other
  Electron/WebView2 apps. Zoom, Safari and native apps are never written to.
  Flags it turned on are turned off again on exit, including Ctrl-C, SIGTERM and
  a closed terminal. A flag that was already on is left alone. If the probe is
  killed with `kill -9`, quit and reopen the app to clear the flag.
- If the Teams main process shows an almost empty tree, it also tries the
  helper processes inside the app bundle.
- Every AX call has a 0.5 s timeout, so a hung app cannot freeze the probe.
- Each tick it walks the app's windows and records, per node: role, subrole,
  title, description, value (truncated), identifier, role description, selected,
  focused, enabled, frame, the names of non-standard attributes
  (`_nonStdAttrs`), and the simple values of those attributes.
- Node identity across ticks is the AX element itself (`CFEqual`), not its
  position, so a reordered tree still diffs correctly. If an app re-creates
  elements, nodes are matched by a structural signature (role, subrole and
  identifier path) instead. The summary says how many nodes matched each way.
- For Chromium and web-shell apps it samples the target's CPU (all processes in
  the bundle) before and after enabling the web tree.

## Output (in the output dir)

- `snapshot-start.json`, `snapshot-end.json`: full trees. Each node has a run-stable `id`.
- `changes.jsonl`: one line per node whose attributes changed between ticks
  (`changed`, with `[old, new]` per attribute), plus `added`/`removed` nodes
  when both walks were complete. Attributes that flip as different people talk
  are the candidate speaking markers.
- `summary.txt` (also printed): node counts, walk time, identity match rates,
  name-like labels and participant rows, most-changed attributes, flip
  candidates, status words (muted, speaking, host...), caption nodes, probe CPU
  time and target CPU.

## Privacy

The output contains real names and call text. Keep it in `/tmp`. Do not commit
it, paste it, or attach it anywhere. To share structure, run with `--redact`:
text values become `h:<hash>#<length>`. The hash is salted per run, so it only
compares within one output dir. Status words such as `muted` stay as a tag.
Role, subrole, role description, identifiers, DOM ids and DOM classes are kept,
as are numbers, booleans and frames. Check a redacted file before sharing it anyway.
