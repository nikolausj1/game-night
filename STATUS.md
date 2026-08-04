---
title: "STATUS - Digital Card Games"
created: 2026-07-24
modified: 2026-08-04
version: 2.1
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

- [ ] **Field-test the reconnect fix** (lock phone mid-game, unlock, flick a card) (~5 min)
      - unblocks: confidence in the #1 recurring failure; tuning if it recurs
- [ ] **Try LCR with the phone as the dice cup** (shake, flip to pour) (~5 min)
      - unblocks: feel-tuning of the marquee dice interaction
- [ ] **Pick a name from `_review/name-candidates.md`** (top pick: Suited) (~10 min)
      - unblocks: icon/bundle ID off placeholder
- [ ] **500 house rules (kitty, misere, partnerships)** (~15 min)
      - unblocks: building 500 at all
- [ ] **Go-ahead for the kids' iPads** (decision, ~2 min)
      - unblocks: 4-hand family game night

## Next Up

1. Family playtest night: UNO with 2 humans + bots, LCR with the phone cup, lock/unlock reconnect drill - collect feel notes.
2. Port Wizard Keeper's GameInsights so announcer recaps tell stories; teach-mode coach walkthrough.
3. Dice wave 2: Farkle (keep/reroll UX) or Liar's Dice (private dice under each phone's cup - the architecture's best trick).

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

- **MultipeerConnectivity reconnect**: never archive/reuse MCPeerID across sessions - a dead session's ghost on the host blocks the returning peer even after force-quit. Fresh MCPeerID per connection attempt + durable app-level device ID for identity is the robust pattern (environment-level, applies to any Multipeer project).
- **SwiftUI transitions are unreliable for network-driven insertions** - explicit two-phase `withAnimation` (place, then animate) driven from `onAppear` is the dependable pattern for animating items that arrive via state sync.
- **simctl can't tap**: design every screen with launch-arg autostart hooks from day one (`-autoRole`, `-autoStartUno`, all-bot games that play themselves) - it turns screenshot verification into true end-to-end tests. (Promoted candidates; Oracle to vet.)
