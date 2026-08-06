---
title: "STATUS - Digital Card Games"
created: 2026-07-24
modified: 2026-08-06
version: 2.4
author: Claude Fable 5 (claude-fable-5)
tags:
---

# Digital Card Games - Status

## Project

Game Night (working title, needs a real name before shipping): a family iOS app where each player's iPhone is their private hand of cards and an iPad in the middle of the table is the communal felt. Cards flick from phone to table with real physics; a voice announcer calls the game. Native SwiftUI, peer-to-peer MultipeerConnectivity (no server/internet). Now also a dice platform (phone = dice cup).

## Stage

Active Development (feature-rich beta-adjacent: five card games + LCR dice, computer players, save/resume, themes, AirPlay spectator - all sim-verified, family playtest pending)

## Health

🟢 On-track - Phase 3 shipped: UNO restyled to Justin's references, dice platform with phone-as-cup landed, reconnect redesigned at the identity level (the stuck-pill bug's root cause), landscape enabled. Deployed to Justin's iPhone + iPad. The backlog of Justin's field-test feedback is fully cleared. NEW: dice went real-3D (SceneKit) - the table throws physically simulated dice whose settled faces ARE the game result, and the phone cup is now a first-person look INTO a leather cup with motion-driven physics (sim-verified on the table side; cup needs a real phone's gyro).

## Waiting on Me

- [ ] **Read `_review/AUDIT.md` and pick which recommendations to greenlight** (~15 min)
      - unblocks: the next build wave's priorities (top recs: layered dice audio, name capture + table signage, accessibility pass)
- [ ] **Field-test wave 2** (game-switch sync, cup pour, manual dealing, browse-pause-play) (~10 min)
      - unblocks: confirmation of the two root-cause fixes on real hardware
- [ ] **Pick a cup concept** (toggle on the remote: cross-section / look-in / glass-bottom) (~3 min)
      - unblocks: retiring the other two or keeping the toggle
- [ ] **Pick a name from `_review/name-candidates.md`** (top pick: Suited) (~10 min)
      - unblocks: icon/bundle ID off placeholder
- [ ] **500 house rules (kitty, misere, partnerships)** (~15 min)
      - unblocks: building 500 at all
- [ ] **Go-ahead for the kids' iPads** (decision, ~2 min)
      - unblocks: 4-hand family game night

## Next Up

1. Audit quick wins: layered velocity-mapped dice audio (the physics already computes per-hit strength), player name capture on the remote, table text signage (name callouts, UNO direction/color chips).
2. Accessibility pass: Reduce Motion handling, Dynamic Type on the 38 fixed fonts, accessibility labels (family app, grandparents to kids).
3. Family playtest night, then Farkle or Liar's Dice on the dice platform.

## Ideas Shelf

- **Liar's Dice** (M) - every phone hides dice under its own cup; bluffing + kids = chaos; platform seams already built
- **Scorepad-only mode** (M) - Wizard Keeper's scorekeeping folded in for physical-card nights
- **Family deck** (S) - kids' drawings or photos as court cards via one Gemini batch
- **"Last trick" peek** (S) - review who threw what; settles arguments
- **Kid mode toggle** (S) - hints on by default, bigger cards, simpler language

## Biggest Risk

Breadth is outrunning human verification: five card games, dice, bots, saves, and AirPlay are sim-verified green, but only Free Play and half of UNO have ever been touched by real hands - one family playtest night would retire more risk than another build wave.

---

## Deferred

500 (blocked on house rules), scorepad-only mode, teach-mode coach, GameInsights port, kid mode, QR-scan join, phones-only table mode, Wizard Keeper history import, on-device LLM coaching (v2 seam), App Store prep, Apple TV as the table (design note in Decisions Log - AirPlay spectator covers the TV moment for now), runtime AI calls (never).

## App Store Readiness

Not close, deliberately: needs final name/bundle ID, real icon pass, privacy policy (local network), TestFlight with non-family testers, and the go-public decision. NOTE: UNO and Bicycle-scan art are personal-use only - a public release requires swapping those for original designs (the theme system already supports it).

## Lessons

- **MultipeerConnectivity reconnect (complete pattern, three failures deep)**: (1) never archive/reuse MCPeerID - fresh identity per connection attempt, durable app-level device ID for seat/session reclaim; (2) sessions die silently on phone lock and can lie about being connected - heartbeat + watchdog + rebuild-on-foreground; (3) force-quit leaves GHOST Bonjour advertisements in the mDNS cache for minutes, and a client that courts the first advertised peer spins forever on a corpse - advertise a launch timestamp in discoveryInfo, keep a candidate list, prefer newest, blacklist failed invites (short timeout) and cycle. All three are required for reliable reconnects; each alone looks fixed until the next field test. (promoted to Build Guide v5.0, 2026-08-04)
- **SwiftUI transitions are unreliable for network-driven insertions** - explicit two-phase `withAnimation` (place, then animate) driven from `onAppear` is the dependable pattern for animating items that arrive via state sync. (promoted to Build Guide v5.0, 2026-08-04)
- **simctl can't tap**: design every screen with launch-arg autostart hooks from day one (`-autoRole`, `-autoStartUno`, all-bot games that play themselves) - it turns screenshot verification into true end-to-end tests. (promoted to Build Guide v5.0, 2026-08-04)
- **Never point -derivedDataPath inside a Dropbox-synced repo**: gigabytes of build products sent the Dropbox file provider into a sync storm that stalled ALL filesystem calls in the repo (git status hung for 10+ minutes; even mv blocked). Build to /tmp always; if it happens, evict the build dir and wait out the storm - and heavy repo-wide `git status --untracked-files=all` scans (IDE/harness-spawned) amplify the stall. (promoted to Build Guide v5.0, 2026-08-04)
