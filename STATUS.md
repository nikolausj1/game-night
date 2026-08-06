---
title: "STATUS - Digital Card Games"
created: 2026-07-24
modified: 2026-08-06
version: 2.5
author: Claude Fable 5 (claude-fable-5)
tags:
---

# Digital Card Games - Status

## Project

Game Night (working title, needs a real name before shipping): a family iOS app where each player's iPhone is their private hand of cards and an iPad in the middle of the table is the communal felt. Cards flick from phone to table with real physics; a voice announcer calls the game. Native SwiftUI, peer-to-peer MultipeerConnectivity (no server/internet). Now also a dice platform (phone = dice cup, photoreal table cup at the rail).

## Stage

Active Development (feature-rich beta-adjacent: five card games + LCR dice, computer players, save/resume, themes, AirPlay spectator - all sim-verified, family playtest pending)

## Health

🟢 On-track - Waves 3 and 4 shipped in one day: manual draw-2/4 penalties, hand-fan geometry finally right at every count (root-caused twice, verified by screenshot at 2/3/7 cards), real rail hands bleeding off the screen edge, photoreal AI-generated table cup + felt/leather textures, real-dice cup loading (drag the actual settled dice into the cup), velocity-layered dice audio, wild-color glow, accessibility floor (Reduce Motion, Dynamic Type, VoiceOver labels) + TipKit. Also fixed two latent product bugs found during verification: MCSession teardown blocking the main thread on every reconnect, and a felt-texture change that silently inflated the whole hand screen's layout. Deployed to Justin's iPhone + iPad.

## Waiting on Me

- [ ] **Field-test wave 4** (hand fan at 3/7/13 cards, rail hands, drag-real-dice cup loading, photoreal cup, manual draw-4, dice audio) (~15 min)
      - unblocks: confirmation on real hardware; dice/cup shadows can ONLY be judged on device (simulator can't render SceneKit shadows)
- [ ] **Pick a name from `_review/name-candidates.md`** (top pick: Suited) (~10 min)
      - unblocks: icon/bundle ID off placeholder
- [ ] **500 house rules (kitty, misere, partnerships)** (~15 min)
      - unblocks: building 500 at all
- [ ] **Go-ahead for the kids' iPads** (decision, ~2 min)
      - unblocks: 4-hand family game night

## Next Up

1. Field-test wave 4 fixes from Justin's next report.
2. Family playtest night, then Farkle or Liar's Dice on the dice platform.
3. Polish leftovers: faint mirror-crease on the cup wall texture, cup-wall texture on-device shadow check, demo-mode deal-in ghost frame.

## Ideas Shelf

- **Liar's Dice** (M) - every phone hides dice under its own cup; bluffing + kids = chaos; platform seams already built
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
- **MCSession teardown blocks the calling thread**: `-[MCSession dealloc]` runs GCKSessionRelease which can sit in select() for many SECONDS (sampled live: whole app froze white at launch). Never let the last reference to an MCSession die on the main thread - nil the delegate, hand the reference to a background queue, let it dealloc there. Corollary: MCSession/MCNearbyServiceBrowser construction has real side effects and can even fail or crash on a sick network stack - construct transports lazily on first start(), never in an initializer that SwiftUI may run during body evaluation, and treat the ObjC initializers as fallible (store into optionals, guard, let a watchdog retry).
- **SwiftUI `aspectRatio(contentMode: .fill)` on a frameless Image changes the LAYOUT, not just the pixels**: it inflated an entire screen's proposal to a square (860x860 on a 440pt phone), silently blowing up all downstream geometry (a fan layout read the wrong container width; a toolbar pushed offscreen). If a texture must cover a region, constrain it with an explicit frame + clipped, or keep `.tile` sizing. For non-tileable textures with baked lighting, pre-mirror the image 2x2 (UIGraphicsImageRenderer, once, cached) and tile THAT - seams become self-matching by construction. Same trick in SceneKit: `material.diffuse.wrapS = .mirror`.
- **SceneKit shadows do not render in the iOS Simulator at all** (verified with near-opaque debug shadow colors and multiple light types, on multiple scenes). Judge any shadow work on a real device only - a missing shadow in a sim screenshot is not a bug, and shadow tuning iterated in the simulator is wasted work.
- **Fixed-count UI thresholds calibrated in one orientation are landscape bugs waiting to happen** - derive them from container/content dimensions (e.g. cards-per-screen-width), and when a layout compresses content, compress positions uniformly rather than clamping outliers (clamping piles items at the edges, which reads as "spread out to the bezel" instead of "held together").
