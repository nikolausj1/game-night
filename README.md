# Game Night

iOS devices replace physical cards. Every player's iPhone is their private hand; an iPad lying in the middle of the table is the communal card table — the deck, the trump card, the played trick, the scores. Swipe a card up off your phone and it lands on the table.

- **Platform:** iOS 17+, universal (iPhone = hand, iPad = table), SwiftUI + SwiftData
- **Sync:** MultipeerConnectivity, peer-to-peer — no server, no internet, works at the cabin
- **Games:** free-play table, Wizard, Oh Hell, Crazy Eights, 500 (phased)
- **Extras:** voice announcer, automatic scoring, rule coaching, lifetime stats, skeuomorphic felt-and-walnut design

## Project layout

- `project.yml` — XcodeGen source of truth (`xcodegen generate` after adding files; the `.xcodeproj` is generated and untracked)
- `Sources/Engine/` — pure Foundation game logic (cards, rules, scoring, protocol messages); no UI imports, headless-testable
- `Sources/Sync/` — MultipeerConnectivity transport
- `Sources/App/` — SwiftUI app, views, theme, announcer
- `Tests/` — headless engine tests (`swiftc -O Sources/Engine/*.swift Tests/<T>.swift`-style recipe)

## Build

```bash
xcodegen generate
xattr -cr Sources   # Dropbox xattr/codesign gotcha
xcodebuild -project GameNight.xcodeproj -scheme GameNight -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
```
