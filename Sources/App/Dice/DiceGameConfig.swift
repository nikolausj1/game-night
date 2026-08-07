import Foundation

/// Which dice-game rules a table (or a launch request) is running. LCR
/// tonight, Yahtzee/Zilch/Shut the Box arriving in the next few hours —
/// this is the seam their controllers, cup views, and `DiceLauncher` all
/// key off of instead of each hardcoding their own dice count / face style.
///
/// Deliberately a DIFFERENT type from Engine's `DiceGameKind` (Sources/
/// Engine/DiceTypes.swift) rather than a rename of it: this app builds as
/// ONE Xcode target (App + Engine sources share a module — see
/// project.yml), so two top-level enums literally named `DiceGameKind`
/// can't coexist. Renaming Engine's existing `.leftRightCenter` case to
/// `.lcr` to unify them was considered and rejected for this pass — the
/// two call sites that construct `DiceClientState(kind: .leftRightCenter,
/// ...)` live in `GameHostController.swift`, outside this worker's edit
/// scope (`Sources/App/Dice/**` + `Sources/Engine/DiceTypes.swift` only)
/// and liable to be mid-edit by another concurrent worker — so renaming
/// that case would either break the build for a file this pass can't fix,
/// or race another session's edits to it. `DiceGameKind` stays exactly
/// what it's always been: the WIRE tag inside `DiceClientState.kind` for
/// LCR's phone broadcasts. `DiceKind` here is the APP-layer config-lookup
/// key — the game workers' new controllers don't need to reuse
/// `DiceClientState` at all (it's LCR-shaped: chips, centerPot,
/// seatNames), so this split costs nothing today and avoids the collision.
/// A later pass that wants ONE unified kind type can still do that rename
/// — it just needs to touch `GameHostController.swift` alongside it.
enum DiceKind {
    case lcr, yahtzee, zilch, shutTheBox
}

/// Which physical face vocabulary a die pool uses. `.lcr` is the three-
/// letter-plus-dot face LCR has always shown; `.pips` is a classic 1-6
/// pip die (Yahtzee, Zilch, Shut the Box). Drives both `DieNode`'s
/// geometry (`init(lcrDie:)` vs `init(pipDie:)`) and which
/// `DieFaceReader` method a settled roll gets read back through
/// (`upFace` vs `upPipValue`) — see `DieResult`, the tagged result type
/// `DiceTableSceneCoordinator.finishRoll()` reports so both styles ride
/// the same `onResult` callback without either one lying about what it
/// found.
enum DieFaceStyle {
    case lcr
    case pips
}

/// Per-`DiceKind` recipe the platform dice layer (`DiceTableSceneView`,
/// `DiceCupSceneView`, `DiceLauncher`) builds itself from, so LCR-only
/// literals (a hardcoded 3, a hardcoded LCR face style) don't leak back
/// into new call sites as Yahtzee/Zilch/Shut the Box land. Nothing here
/// executes rules — `supportsHolds`/`supportsSetAsides` are read-only
/// flags a (not-yet-written) game controller can consult to decide
/// whether ITS rules want the table's hold-tap primitive
/// (`DiceTableSceneCoordinator.setHeld`/`onDieTapped`) at all; the table
/// always exposes that primitive regardless of which flag is set here —
/// see that coordinator's doc for the mechanism.
struct DiceGameConfig {
    /// How many dice live in the table's persistent pool / a phone cup
    /// for this game.
    let diceCount: Int
    let dieFaceStyle: DieFaceStyle
    /// Yahtzee: a held die sits out of the next reroll until tapped again.
    let supportsHolds: Bool
    /// Zilch: dice scored this roll get set aside (banked) before
    /// rerolling the rest. A separate flag from `supportsHolds` even
    /// though both ride the SAME table primitive (`setHeld`/
    /// `onDieTapped`/the pool's `.held` state) — when/why a die leaves
    /// the roll pool is a game-controller (rules) concern, not a table
    /// (mechanism) one, so the two stay independently readable here.
    let supportsSetAsides: Bool

    static func config(for kind: DiceKind) -> DiceGameConfig {
        switch kind {
        case .lcr:
            return DiceGameConfig(diceCount: 3, dieFaceStyle: .lcr,
                                   supportsHolds: false, supportsSetAsides: false)
        case .yahtzee:
            return DiceGameConfig(diceCount: 5, dieFaceStyle: .pips,
                                   supportsHolds: true, supportsSetAsides: false)
        case .zilch:
            return DiceGameConfig(diceCount: 6, dieFaceStyle: .pips,
                                   supportsHolds: false, supportsSetAsides: true)
        case .shutTheBox:
            return DiceGameConfig(diceCount: 2, dieFaceStyle: .pips,
                                   supportsHolds: false, supportsSetAsides: false)
        }
    }
}
