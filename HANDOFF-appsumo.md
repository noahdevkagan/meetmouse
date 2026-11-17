# AppSumo redeem fixes — handoff

Branch `appsumo-redeem-fixes` (worktree `~/dev/meetmouse-appsumo`), commit b258a77 + this note. PR #85 (draft). Review fixes committed on top; coordinator pushes.

## To finish
1. `cd ~/dev/meetmouse-appsumo && git push -u origin appsumo-redeem-fixes` (push gate runs; local run result below).
2. `gh pr create --draft --title "AppSumo redeem: show code, numbered steps, in-app code prompt, Unlimited ✓"` with the body in "PR body" below. Never mark ready, no reviewers.

## What changed
- `docs/appsumo.html`: success state shows the code in a read-only box + Copy (fallback selects text, button says "Press ⌘C"); numbered steps (1 Download…, 2 Unlock); Unlock is grey (`.pending`) until Download is clicked, still clickable. Download Model note + support email kept. No email sending.
- `Models/UsageGate.swift`: `shouldShowAppSumoPrompt` / `markAppSumoPromptShown` (key `usage.appSumoPromptShown`); `FreeTier.showAppSumoPrompt`, `checkAppSumoPrompt(isLive:)`, `codeFocusRequest` / `requestCodeFocus()`. Unlock clears the prompt. Trial-ended notice waits while the prompt is up.
- `App/ContentView.swift`: welcome/rebrand sheet first; the AppSumo prompt (any non-unlocked install, once) follows on its dismiss, or at launch when nothing else shows; during the demo it waits for next launch. Limit sheet raised during the prompt is queued until it closes (review fixes on PR #85). Sidebar link "Enter AppSumo code…" (locked installs only).
- `App/MeetMouseApp.swift`: menu bar item "Enter AppSumo Code…" (locked installs only).
- `Views/GiveMeetMouseView.swift`: code box moved to the top ("Have an AppSumo or purchase code?"), focuses on request; new `AppSumoCodePrompt` sheet; `FreeTierCard` shows "Unlimited ✓" when unlocked (nothing showed before).
- `tests/freetier/main.swift`: prompt once, never for unlocked/grandfathered.
- CHANGELOG `## Unreleased` note (+ regenerated sitemap lastmod), decisions.md entry, screenshots `design/appsumo/redeem-success-{before,after}.png`.

## Not verified
- App UI never launched (dev build shares UserDefaults with the installed app); prompt → welcome sheet chaining, focus, and the NSAlert after unlocking from the sheet are untested by eye.
- Copy/clipboard fallback and the Download → Unlock style change only checked by reading code; screenshots forced the success state with a dummy code.

## PR body
AppSumo buyers redeem on /appsumo, install, and never enter their code. The free week hides it until day 8, then it locks and looks like the purchase failed.

- /appsumo success: code box + Copy, numbered steps, Unlock secondary until Download is clicked.
- App: one-time "Bought MeetMouse on AppSumo?" prompt at launch (not for unlocked/grandfathered); "Enter AppSumo code…" in sidebar + menu bar; code box at top of Get MeetMouse Unlimited; sidebar "Unlimited ✓".

Before / after: design/appsumo/redeem-success-before.png, redeem-success-after.png on this branch.
