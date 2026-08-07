import SwiftUI

/// Sim-verify hook: `-autoStartShutBox` renders a real Shut the Box table —
/// full `GameHostController` + an all-bot `ShutBoxController`, exactly the
/// shape a real game reaches — standalone, no lobby/menu needed. Lets a
/// build be screenshotted mid-game (tiles part-tipped, dice settled, a bust
/// scorecard, the shut-the-box trophy) the same way `-autoStartLcr`
/// (`DiceTableView`/`DiceGameController`) already does for LCR.
///
/// NOT WIRED IN by this pass — `RoleRouter.swift`, `MenuView.swift`, and
/// `DiceGameController.swift` (home of `DiceLauncher`) all sit outside this
/// worker's edit scope (`Sources/App/Dice/ShutBox/**` only), so this
/// harness can construct and drive the real game just fine but has no
/// launch-argument hook of its own yet. For whoever wires it in, three
/// one-line additions, each mirroring an existing dice-game hook exactly:
///
/// 1. `RoleRouter.swift`, in `body`, alongside the existing
///    `-autoCupPreview` check:
///    ```swift
///    if CommandLine.arguments.contains("-autoStartShutBox") {
///        ShutBoxPreviewHarness()
///    } else if CommandLine.arguments.contains("-autoCupPreview") {
///        DiceCupPreviewHarness()
///    } else {
///        roleSwitch
///    }
///    ```
///    (This harness is self-contained — a real `GameHostController` built
///    right here — so it doesn't need `TableRootView`'s own routing at
///    all; the check can sit anywhere ahead of `roleSwitch`.)
///
/// 2. For the SAME harness to be reachable from a live table (not just the
///    sim-verify screenshot path), `DiceLauncher.start(kind:host:seats:)` in
///    `DiceGameController.swift` needs its `.shutTheBox` case filled in
///    (today it's a logged no-op — see that switch's own TODO comment):
///    ```swift
///    case .shutTheBox:
///        controller = ShutBoxController(host: host, seats: seats)
///    ```
///    This also needs `DiceLauncher.controller`'s type broadened beyond
///    `DiceGameController?` (an enum of controllers, a small protocol,
///    whatever fits best) since it's currently hard-typed to LCR's own
///    controller class — that's a real design call for whoever owns that
///    file, not a one-liner, so it's flagged rather than guessed at here.
///    `TableRootView.swift`'s `if let dice = diceLauncher.controller { … }`
///    branch would need the matching `ShutBoxTableView` case alongside it.
///
/// 3. `MenuView.swift`'s dice picker already lets a table pick "Shut the
///    Box" as `DiceKind.shutTheBox` for its deal button (see
///    `DiceGameConfig.config(for:)`) — that path already calls
///    `DiceLauncher.start(kind:host:seats:)`, so once (2) lands, real play
///    is reachable with NO menu changes. An `-autoStartShutBox` bot-only
///    hook there (mirroring `-autoStartLcr`'s `onAppear` block) is optional
///    polish once (2) exists; this harness covers the same screenshot need
///    today without it.
struct ShutBoxPreviewHarness: View {
    @State private var host = GameHostController()
    @State private var controller: ShutBoxController?

    var body: some View {
        ZStack {
            TableSurface()
            if let controller {
                ShutBoxTableView(controller: controller, onClose: nil)
            }
        }
        .onAppear {
            guard controller == nil else { return }
            let bots = BotRoster.random(count: 3).enumerated().map {
                SeatSpec(id: $0.offset, name: $0.element.name, isBot: true)
            }
            controller = ShutBoxController(host: host, seats: bots)
        }
    }
}
