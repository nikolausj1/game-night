---
title: "STATUS - Digital Card Games"
created: 2026-07-24
modified: 2026-10-09
version: 3.0
author: Claude Fable 5.1 (claude-fable-5-1)
tags:
---

# Digital Card Games - Status

## Project

Game Night (working title, needs a real name before shipping): a family iOS app where each player's iPhone is their private hand of cards and an iPad in the middle of the table is the communal felt. Cards flick from phone to table with real physics. Native SwiftUI, peer-to-peer MultipeerConnectivity (no server/internet). Twenty-five games on five shelves: nine card games (Wizard, Oh Hell, Hearts, Spades, Crazy Eights, UNO, Gin Rummy, Cribbage, Blackjack), a kids' pack (Go Fish, Old Maid, War), five dice games on the phone-as-cup platform (LCR, Yahtzee, Zilch, Shut the Box, Liar's Dice), six board games played on the table (Mancala, Checkers, Connect Four, Dots & Boxes, Quarto, Battleship), plus Solitaire and Free Play.

## Stage

Active Development (feature-rich beta-adjacent: 25 games, computer players with personalities, save/resume and recaps for every game, themes, AirPlay spectator; tonight's build is compiled and engine-tested but NOT yet screenshot-verified or on device, see Health)

## Health

🟡 At-risk - 2026-10-09 night 2 LANDED IN CODE, UNVERIFIED ON SCREEN. Ten work packages built by ~20 workers under a lead: (1) card physics v2 (FeltSim: cards shove, spin and stack each other, rail rebound, 240 Hz, 16/16 headless checks); (2) coin physics v2 (CoinSim: collisions with spin transfer, edge-rolls that wobble down like a real coin, dice impacts scatter coins, synthesized clink SFX, 26/26 checks); (3) Core Haptics cup (rattle texture, contact transients, pour gesture, table echo), pour-from-the-cup-mouth dice launch with a tipping table cup, photoreal cross-section cup interior; (4) linen card stock + gyro sheen; (5) attract-mode lobby (idle riffles, dice, card slides) with a lamp model lighting the felt, plates, deck and rail hands, plus brass place settings; (6) bots that play like people: Quarto made deterministic (node budgets), exact-EV Cribbage discards + 2-ply pegging, Dots & Boxes chain/double-cross solver (74-18 vs old), Yahtzee expectimax (avg 241-247), Zilch exact press tables (75% head-to-head), Shut the Box exact solution, UNO/Crazy Eights card counting, Wizard/Oh Hell bid scaling, six named personalities; (7) eight hidden-info and table games on a new generic side-game seam (Battleship, Gin Rummy, Go Fish, Old Maid, War, Hearts, Spades, Blackjack, Liar's Dice) and three local board games (Mancala, Checkers, Connect Four) with real photo assets; (8) Hearts passing + Spades nil/blind-nil UI on the phone, table signage and team recaps; (9) save/resume + game-over recap card + uniform rematch for every game, one ResumeCatalog feeding the lobby; (10) a scripted verification machine (`tools/verify.sh`: 30-entry screenshot matrix, two-sim Multipeer join assertion, frame strips). Engine suite 3,489 -> 22,793 checks, all green. `tools/build.sh sim` BUILD SUCCEEDED on the integrated tree; commit cf2435f pushed. WHY AT-RISK: the Mac was overloaded all night by other sessions (load 300-1000, disk down to 170 MB free), both dedicated simulators wedged in first-boot data migration, so NOTHING from tonight has been seen on a screen or felt on a device yet. Every worker shipped an honest "unverified" list; the verification matrix is the first thing to run once the machine is sane. Previously (2026-10-08/09): project moved to `~/_Developer/Digital Card Games`; the first overnight build landed seven games; waves 3-5 before that.

## Waiting on Me

- [ ] **Open the app and walk the new lobby** (25 tiles, attract mode after 8 s idle, place settings) and tell me what feels wrong (~10 min)
      - unblocks: the fix wave for night 2; none of tonight's visuals have been seen by anyone yet
- [ ] **Feel the cup haptics and the pour on your iPhone** (Core Haptics only exists on device; the simulator can only prove the fallback path) (~5 min)
      - unblocks: haptic tuning; the rattle/pour curves are first guesses
- [ ] **Play the seven games from night 1** (Cribbage, Solitaire, Yahtzee, Zilch, Shut the Box, Dots & Boxes, Quarto) (~45 min of fun)
      - unblocks: the next fix wave; bots for all of these got much stronger tonight, so they may now be too hard for the kids - say so and I add a "take it easy" personality
- [ ] **Pick a name from `_review/name-candidates.md`** (top pick: Suited) (~10 min)
      - unblocks: icon/bundle ID off placeholder
- [ ] **500 house rules (kitty, misere, partnerships)** (~15 min)
      - unblocks: building 500 at all
- [ ] **ON HOLD - do NOT deploy to the kids' iPads.** Justin's decision, 2026-08-28, in his words: "The app is not ready to deploy. I will let you know when it is." Do not raise this again; he will say when. (updated via Oracle at Justin's direction, 2026-08-28; carried into the live copy during the move to `~/_Developer`, 2026-10-09)
      - unblocks: nothing until he lifts the hold

## Next Up

1. Run the verification machine on a sane machine: `tools/verify.sh --multipeer` plus the targeted night-2 shots (attract, felt scatter, coin scatter, cup concepts, pour, Hearts/Spades, recaps); fix what it finds; deploy to Justin's iPhone and iPad.
2. Night-2 known gaps to close: Quarto controller does not yet pass personality node budgets; UNO 4-player bot has no measured edge; CribbageScoring counts Ace high in runs (pre-existing engine bug, A-2-3 should be a run); `-demoRecap` and the resume-into-local-view path are unexercised.
3. Family playtest night.

## Ideas Shelf

- **"Take it easy" bot personality** (S) - a seventh name that plays the legacy heuristics so the kids can win sometimes; one table row in BotPersonality
- **Phone tilt steers the pour** (S) - the wire already carries intensity; add tiltX/tiltY from device gravity and the table fans the dice toward where you tipped
- **Scorepad-only mode** (M) - Wizard Keeper's scorekeeping folded in for physical-card nights
- **Family deck** (S) - kids' drawings or photos as court cards via one Gemini batch
- **"Last trick" peek** (S) - review who threw what; settles arguments

## Biggest Risk

Twenty-five games and a physics rewrite landed in one night with zero human eyes on any of it; the simulator matrix will catch crashes and blank screens but not "this feels wrong", and the only cure for that is Justin playing it.

---

## Deferred

500 (blocked on house rules), scorepad-only mode, teach-mode coach, GameInsights port, kid mode, QR-scan join, phones-only table mode, Wizard Keeper history import, on-device LLM coaching (v2 seam), App Store prep, Apple TV as the table (design note in Decisions Log), watcher seat for extra phones (audit rec 10), table text commentary (built then shelved at Justin's direction - code dormant in TableSignage.swift), runtime AI calls (never).

## App Store Readiness

Not close, deliberately: needs final name/bundle ID, real icon pass, privacy policy (local network), TestFlight with non-family testers, and the go-public decision. NOTE: UNO and Bicycle-scan art are personal-use only - a public release requires swapping those for original designs (the theme system already supports it).

## Lessons

- **MultipeerConnectivity reconnect (complete pattern, three failures deep)**: (1) never archive/reuse MCPeerID - fresh identity per connection attempt, durable app-level device ID for seat/session reclaim; (2) sessions die silently on phone lock and can lie about being connected - heartbeat + watchdog + rebuild-on-foreground; (3) force-quit leaves GHOST Bonjour advertisements in the mDNS cache for minutes, and a client that courts the first advertised peer spins forever on a corpse - advertise a launch timestamp in discoveryInfo, keep a candidate list, prefer newest, blacklist failed invites (short timeout) and cycle. All three are required for reliable reconnects; each alone looks fixed until the next field test. (promoted to Build Guide v5.0, 2026-08-04)
- **SwiftUI transitions are unreliable for network-driven insertions** - explicit two-phase `withAnimation` (place, then animate) driven from `onAppear` is the dependable pattern for animating items that arrive via state sync. (promoted to Build Guide v5.0, 2026-08-04)
- **simctl can't tap**: design every screen with launch-arg autostart hooks from day one (`-autoRole`, `-autoStartUno`, all-bot games that play themselves) - it turns screenshot verification into true end-to-end tests. (promoted to Build Guide v5.0, 2026-08-04)
- **Never point -derivedDataPath inside a Dropbox-synced repo**: gigabytes of build products sent the Dropbox file provider into a sync storm that stalled ALL filesystem calls in the repo (git status hung for 10+ minutes; even mv blocked). Build to /tmp always; if it happens, evict the build dir and wait out the storm - and heavy repo-wide `git status --untracked-files=all` scans (IDE/harness-spawned) amplify the stall. (promoted to Build Guide v5.0, 2026-08-04)
- **MCSession teardown blocks the calling thread**: `-[MCSession dealloc]` runs GCKSessionRelease which can sit in select() for many SECONDS (sampled live: whole app froze white at launch). Never let the last reference to an MCSession die on the main thread - nil the delegate, hand the reference to a background queue, let it dealloc there. Corollary: MCSession/MCNearbyServiceBrowser construction has real side effects and can even fail or crash on a sick network stack - construct transports lazily on first start(), never in an initializer that SwiftUI may run during body evaluation, and treat the ObjC initializers as fallible (store into optionals, guard, let a watchdog retry). (promoted to Build Guide v7.1, 2026-08-06)
- **SwiftUI `aspectRatio(contentMode: .fill)` on a frameless Image changes the LAYOUT, not just the pixels**: it inflated an entire screen's proposal to a square (860x860 on a 440pt phone), silently blowing up all downstream geometry (a fan layout read the wrong container width; a toolbar pushed offscreen). If a texture must cover a region, constrain it with an explicit frame + clipped, or keep `.tile` sizing. For non-tileable textures with baked lighting, pre-mirror the image 2x2 (UIGraphicsImageRenderer, once, cached) and tile THAT - seams become self-matching by construction. Same trick in SceneKit: `material.diffuse.wrapS = .mirror`. (promoted to Build Guide v7.1, 2026-08-06)
- **SceneKit shadows do not render in the iOS Simulator at all** (verified with near-opaque debug shadow colors and multiple light types, on multiple scenes). Judge any shadow work on a real device only - a missing shadow in a sim screenshot is not a bug, and shadow tuning iterated in the simulator is wasted work. (promoted to Build Guide v7.1, 2026-08-06)
- **Fixed-count UI thresholds calibrated in one orientation are landscape bugs waiting to happen** - derive them from container/content dimensions (e.g. cards-per-screen-width), and when a layout compresses content, compress positions uniformly rather than clamping outliers (clamping piles items at the edges, which reads as "spread out to the bezel" instead of "held together"). (promoted to Build Guide v7.1, 2026-08-06)
- **SwiftUI `.mask()` CLIPS, it doesn't just fade** - a mask forces the view into an offscreen layer bounded by the mask's own frame, so content that animates outside it (a card dragged out of its fan) simply vanishes ("slides under the felt", a field-reported regression). For edge-fade cues on containers whose children travel, fade per-child opacity instead; never mask a container whose children animate beyond its bounds.
- **Multi-quantity animations must share ONE animated scalar** - animating position, height, rotation, and shadow via separate withAnimation calls/state lets SwiftUI run them out of lockstep under frame pressure (read as "two motions" in the field, three fix attempts). Make a custom Animatable ViewModifier whose animatableData is a single progress value and derive every quantity from it per-frame - desync becomes structurally impossible, and sim video + frame extraction proves motion quality objectively.
- **Photoreal in-app = photographic assets + live 3D actors composited over them** - procedural geometry/textures cap at "game render" no matter how much they're tuned (owner rejected them twice); a generated photo as the environment with only the dynamic objects rendered in a transparent 3D layer (SCNMaterial .shadowOnly catcher for grounding shadows) passes the "is this a photo?" test. Calibrate the physics container to the photo's geometry by measuring the image and mapping through the camera projection.
- **Fan-out needs ONE build owner and ONE simulator owner** - 13 parallel workers each running their own xcodebuild and simctl on a shared Mac filled the disk twice (every repo copy or private DerivedData is 1-2 GB), stacked hung simctl calls until CoreSimulator wedged, and left stale build locks when a worker was killed. What held: a single `tools/build.sh` that pins the live repo path, refuses below 1.5 GB free, serializes with a mkdir lock that records the holder pid and breaks dead locks, and traps INT/TERM/HUP; plus "workers never touch simulators, the lead screenshots centrally". Tell workers up front: no repo copies, no private DerivedData, no simctl.
- **When builds can't run, `swiftc -typecheck` of the whole tree is a real fallback** - `xcrun -sdk iphonesimulator swiftc -typecheck -continue-building-after-errors -target arm64-apple-ios17.0-simulator -parse-as-library <all .swift>` needs ~no disk and catches everything but resources and linking; WITHOUT `-continue-building-after-errors` swiftc stops at the first failing batch and silently skips the rest, so a "clean" typecheck can be a lie.
- **A simulator stuck in first-boot "Waiting on Data Migration" for 30+ minutes will not recover and blocks every simctl call** (list, install, io) with hangs. `simctl shutdown` hangs too. Fix: `kill -9` that device's `launchd_sim` process (its command line contains the UDID), then `simctl erase`, then boot; do it only on sims you own.
- **Design the plug-in seam BEFORE fanning out N game workers** - one generic transport (opaque kind + payload messages), one host protocol (handle/state/drainEvents/end), one registry keyed by kind string with table and hand view builders. Eight multiplayer games then landed as one registry line each with zero controller merges between workers.

