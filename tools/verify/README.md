---
title: Game Night verification machine
created: 2026-10-09
modified: 2026-10-09
version: 1.0
author: Claude Sonnet 5.5 (claude-sonnet-5-5)
tags:
---

# Game Night verification machine

The house lesson: `simctl` can't tap, so every screen we want to verify is reachable by launch args
(harness flags), and verification is a screenshot of the real app in a real sim. This directory automates that.

## Run it

```
tools/build.sh                      # serialized shared build (required first)
tools/verify.sh                     # whole matrix, both sims, in parallel (one thread per sim)
tools/verify.sh --multipeer         # ... plus the two-sim join test
tools/verify.sh --only hand,cup-0-crosssection   # entry names or groups
tools/verify.sh --device iphone --wait-scale 2   # slower host? scale every wait
tools/verify.sh --no-install        # skip uninstall/install (keeps app state)
```

Output goes to `_review/verify/<timestamp>/`: `index.html` (contact sheet, open it), `REPORT.md`,
`results.json`, one PNG per entry (iPad table shots auto-rotated), `raw/` (unrotated originals plus the
home-screen baselines), and `multipeer/` when that ran. `_review/verify/latest.txt` names the newest run.
Exit code is non-zero if any entry FAILs.

Sims: "GameNight iPad" `9704894E-AAA0-407F-9462-C11E4F8A251E`, "GameNight iPhone"
`BB8EF1B1-6871-4192-8A39-B47EC8120E0D`. The build under test is
`$GN_SCRATCH/dd-shared/Build/Products/Debug-iphonesimulator/GameNight.app` (override with `--app`).
The runner uninstalls then installs the app on each sim first, so every run starts from a clean container
(no saved games, no TipKit state, fresh `@AppStorage`).

## What PASS means

- FAIL: launch returned non-zero, screenshot failed, the app pid was not alive at screenshot time or right
  after it (crash; a matching `~/Library/Logs/DiagnosticReports/GameNight*.ips` is named in the notes), or
  the screenshot is indistinguishable (mean abs diff under 2/255 on a 48x48 grayscale) from the sim's home
  screen captured after terminating the app.
- WARN: near-uniform image (blank render).
- PASS: alive and drew something different from the home screen. It does NOT mean it looks right. Open `index.html`.

## Add an entry

Append to `matrix.json` `entries`: `{"name": "...", "group": "...", "device": "ipad|iphone", "args": [...], "wait": 8}`.
Optional: `"reduce_motion": true`, `"rotate": true|false` (default: iPad shots rotate when portrait-framed).
Then `tools/verify.sh --only <name>`. If the game has no launch hook, add one (pattern: `CommandLine.arguments.contains("-yourFlag")`
in the view's `.onAppear`, ideally gated on the real engine so the shot is true end-to-end) and list it in the matrix.

## Two-sim Multipeer test: `multipeer.sh`

`tools/verify/multipeer.sh [--runs N] [--timeout 90] [--no-install]`. The iPad launches
`-autoRole table -autoStart`, six seconds later the iPhone launches `-autoRole hand -autoPlay`. Sim-to-sim DTLS is
disabled by the app under `#if targetEnvironment(simulator)`, so they can talk.

Join assertion (PASS if either channel holds, and both apps are still alive):

1. LOG channel: `log stream` subsystem `com.levelup.gamenight` on the iPad grepped for `GN_JOIN_LOG_REGEX`
   (default `peer connected|welcome sent|hello from`). Dormant today: HostSession / GameHostController only log
   errors, there are no hello/welcome info lines. See "Hooks" for the one-liners that would light it up.
2. STATE channel (works today): `-autoStart` starts free play the moment a phone sits; `-autoPlay` makes the
   phone draw a card; the table autosaves 2s later to `Documents/SavedGames/*.json`. The script clears that folder
   first, then requires a save with a seat where `isBot == false` and `deviceID` is set. That is only possible
   after the full hello -> welcome -> seat -> snapshot -> action round trip over real Multipeer.

Screenshots of both sims plus both log captures land in `multipeer/`. Use `--runs 5` to measure flakiness
(MC discovery on sims can take 10-40s and occasionally needs the client watchdog, 10-20s, to retry).

## Motion proof: `frames.sh`

`tools/verify/frames.sh <udid> <seconds> <out.png> [frames=8] [launch args...]`

Records with `simctl io recordVideo`, extracts N evenly spaced frames (ffmpeg; falls back to
`extract_frames.swift` via AVFoundation if ffmpeg is missing), hstacks them with PIL (`hstack.py`) and prints the
frame-to-frame mean difference with a MOTION/STATIC verdict. Example, the L-R-C dice roll on the iPad:

```
tools/verify/frames.sh 9704894E-AAA0-407F-9462-C11E4F8A251E 6 /tmp/lcr-strip.png 8 -autoRole table -autoStartLcr
```

Env: `FRAMES_ROTATE=auto|0|1`, `FRAMES_HEIGHT=480`, `FRAMES_KEEP=1`.

## Known limitations

- Reduce Motion: the runner writes `com.apple.Accessibility ReduceMotionEnabled` in the sim's defaults and posts a
  notification, but the app only reads it through `UIAccessibility`/`\.accessibilityReduceMotion`; whether a
  running process picks it up is NOT proven (the entry relaunches the app after the write, which should be enough, but
  nothing in the app displays the flag). Treat `*-reducemotion` shots as "applied, visually compare with the plain
  entry". A one-line debug badge would make this provable (see Hooks).
- No taps: anything needing input has to be reachable by launch args. Coin drags, pending coins, menu interactions
  are not covered.
- Free-play "coins" has no launch flag (only `-demoFreePlayDice`).
- Screenshots are one instant. Animation correctness needs `frames.sh`.
- Sims stuck in first-boot "Waiting on Data Migration" (seen 2026-10-09 with host load ~700: KeychainMigrator took 34+ minutes) make every simctl call hang. `--boot-timeout` (default 600s) / `GN_BOOT_TIMEOUT` raise the patience; the runner then records every entry as FAIL "sim failed to boot" rather than hanging.
- Parallel threads (one per sim) are fine for processes but a heavily loaded host (other workers building) makes
  boots and launches slow; use `--wait-scale 2`. Timeouts are generous (boot 300s, launch 180s).
- Crash-report matching reads the pid out of the `.ips` header; reports can lag the crash by seconds.
- Needs python3 + PIL, ffmpeg (optional), perl (timeouts). Built only from the shared DerivedData; this tool never builds.

## Hooks the app lacks (one-liners for the lead)

One-line additions the verification machine would like (not applied; the tool never edits app code):

- Join log lines (enables multipeer channel 1):
  `HostSession.swift`, in `didChange` `.connected`: `self.log.info("peer connected: \(peerID.displayName)")`;
  `GameHostController.swift`, in `case .hello(let name, let deviceID)`: `Logger(subsystem: "com.levelup.gamenight", category: "Host").info("hello from \(name)")`
  and next to each `session.send(.welcome(seat: ...)` : `...info("welcome sent seat \(seat)")`.
- Reduce Motion probe: in `RoleRouter`, `.overlay(alignment: .topLeading) { if CommandLine.arguments.contains("-showA11y") { Text("RM:\(UIAccessibility.isReduceMotionEnabled ? 1 : 0)").font(.caption2).padding(2).background(.black).foregroundStyle(.white) } }` on `body`'s root.
- Free-play coins: `TableGameView` next to `freePlayDiceOn` add `@State private var freePlayCoinsOn = CommandLine.arguments.contains("-demoFreePlayCoins")` and wire it like the dice toggle.
