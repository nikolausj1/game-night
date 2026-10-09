---
title: "STATUS - Digital Card Games"
created: 2026-07-24
modified: 2026-10-09
version: 2.9
author: Claude Fable 5.1 (claude-fable-5-1)
tags:
---

# Digital Card Games - Status

## Project

Game Night (working title, needs a real name before shipping): a family iOS app where each player's iPhone is their private hand of cards and an iPad in the middle of the table is the communal felt. Cards flick from phone to table with real physics. Native SwiftUI, peer-to-peer MultipeerConnectivity (no server/internet). Thirteen games: five card games + cribbage + solitaire, four dice games on the phone-as-cup platform, and two board-and-paper games played directly on the table.

## Stage

Active Development (feature-rich beta-adjacent: five card games + LCR dice, computer players, save/resume, themes, AirPlay spectator - all sim-verified, family playtest pending)

## Health

🟢 On-track - 2026-10-09: project moved to `~/_Developer/Digital Card Games` (clean clone; the Dropbox clone's `.git` was corrupted by sync conflicts). A second overnight build is in progress tonight: card/coin physics simulations, Core Haptics in the cup, photoreal cross-section cup and card stock, lobby attract mode, bots pass, eight more games (Battleship, Gin Rummy, Go Fish/Old Maid/War, Hearts, Spades, Blackjack, Liar's Dice, Mancala, Checkers, Connect Four), save/resume everywhere, and a scripted verification matrix. Previously: THE OVERNIGHT BUILD LANDED: seven new games in one night (Cribbage with a photoreal pegboard and combinatorially exact scoring incl. the 29-hand test; Solitaire dealt onto the felt; Yahtzee/Zilch/Shut the Box on a generalized dice platform with pip dice and tap-to-hold; Dots & Boxes as real pencil on paper; Quarto in turned wood matching Justin's reference). Engine suite grew 375 -> 3,489 checks, all green. New category-shelf home screen (Cards / Dice / Board & Paper). All games bot-capable except Solitaire; all launch paths live-verified by screenshot. UNO reverse glyph redrawn against Justin's reference image. Deployed to both devices. Earlier: Wave 5 (motion + feel) shipped on top of waves 3-4: the hand-fan clipping regression root-caused (a SwiftUI mask silently clips - cards "slid under the felt") and fixed with a permanent mid-gesture screenshot harness; the UNO throw is finally ONE fluid arc (single animated progress scalar drives position/height/rotation/shadow - desync now structurally impossible, proven frame-by-frame from sim video); wild cards glow in their called color (chip removed); coins flick-glide with felt friction and rail bounce; free play got the full cup ceremony; LCR cup-loading perf fixed (throttled hit-tests, motion-gated shadow tracking); and the phone cup went PHOTOREAL - generated photographic interiors with live 3D dice composited over them, replacing the procedural render Justin rejected, plus the deep look-in rebuilt at honest real-cup proportions. Deployed to iPhone (iPad pending unlock). Earlier same day, waves 3-4: manual draw-2/4 penalties, hand-fan geometry finally right at every count (root-caused twice, verified by screenshot at 2/3/7 cards), real rail hands bleeding off the screen edge, photoreal AI-generated table cup + felt/leather textures, real-dice cup loading (drag the actual settled dice into the cup), velocity-layered dice audio, wild-color glow, accessibility floor (Reduce Motion, Dynamic Type, VoiceOver labels) + TipKit. Also fixed two latent product bugs found during verification: MCSession teardown blocking the main thread on every reconnect, and a felt-texture change that silently inflated the whole hand screen's layout. Deployed to Justin's iPhone + iPad.

## Waiting on Me

- [ ] **Play the seven new games** (Cribbage, Solitaire, Yahtzee, Zilch, Shut the Box, Dots & Boxes, Quarto) (~45 min of fun)
      - unblocks: the next fix wave; player-count ranges for Yahtzee (1-6) / Zilch / Shut the Box (2-6) were my judgment calls - veto freely
- [ ] **Field-test wave 5 leftovers** (one-motion UNO throw, coin flicking, photoreal phone cup on real hardware) (~10 min)
      - unblocks: closing the motion/feel wave for good
- [ ] **Pick a name from `_review/name-candidates.md`** (top pick: Suited) (~10 min)
      - unblocks: icon/bundle ID off placeholder
- [ ] **500 house rules (kitty, misere, partnerships)** (~15 min)
      - unblocks: building 500 at all
- [ ] **ON HOLD - do NOT deploy to the kids' iPads.** Justin's decision, 2026-08-28, in his words: "The app is not ready to deploy. I will let you know when it is." Do not raise this again; he will say when. (updated via Oracle at Justin's direction, 2026-08-28; carried into the live copy during the move to `~/_Developer`, 2026-10-09)
      - unblocks: nothing until he lifts the hold

## Next Up

1. Justin's field report on the seven new games; fix wave follows.
2. Family playtest night, then Farkle or Liar's Dice on the dice platform.
3. Polish leftovers: dice color-grade against the photo interiors (a touch bright/flat), on-device shadow + cup lighting pass, cross-section concept's photoreal treatment (look-ins done), demo-mode deal-in ghost frame.

## Ideas Shelf

- **Liar's Dice** (M) - every phone hides dice under its own cup; bluffing + kids = chaos; the generalized dice platform makes this mostly UI now
- **Scorepad-only mode** (M) - Wizard Keeper's scorekeeping folded in for physical-card nights
- **Family deck** (S) - kids' drawings or photos as court cards via one Gemini batch
- **"Last trick" peek** (S) - review who threw what; settles arguments
- **Kid mode toggle** (S) - hints on by default, bigger cards, simpler language

## Biggest Risk

Breadth is outrunning human verification: five card games, dice, bots, saves, and AirPlay are sim-verified green, but only Free Play, UNO, and part of LCR have ever been touched by real hands - one family playtest night would retire more risk than another build wave.

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
