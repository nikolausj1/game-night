import SwiftUI

/// Sim-verify hook: `-autoCupPreview` renders the cup interior standalone
/// (no table, no lobby, no motion hardware needed — the scene's default
/// "natural hold" gravity poses the dice). Lets a build be screenshotted
/// to check the cup's geometry, lighting, and dice placement exactly as a
/// player would see them mid-turn. Same spirit as `-autoRole` /
/// `-autoStartLcr`.
///
/// `-cupConcept 0|1|2` forces a specific look (Cross-section / Look-in /
/// Glass bottom) for screenshotting; without it the harness shows the
/// persisted choice and the live toggle works exactly as in the game.
///
/// `-demoPipDice` (combine with `-autoCupPreview` on the launch line —
/// RoleRouter.swift only knows the latter flag, so this one is read right
/// here rather than adding a second entry hook): swaps the cup interior
/// out for a standalone TABLE felt showing a real 5-die PIP throw settle —
/// the platform-wave proof that `DieNode.init(pipDie:)`/`DieFaceReader.
/// upPipValue`/`DiceTableSceneView.faceStyle` actually produce a readable
/// 1-6 die, ahead of any real Yahtzee/Zilch/Shut the Box controller
/// existing to drive one. Not part of any real game flow.
///
/// `-demoPour` (also combine with `-autoCupPreview`): a table felt with a
/// real TableCupView on the bottom rail wearing the reference
/// `.tablePourTilt` and a 3-die pool that pours out of its mouth every ~5s
/// — the night-2 pour trajectory + cup-tip contract on film, without a
/// phone or a game controller. Use an iPad simulator.
struct DiceCupPreviewHarness: View {
    @State private var model = DiceCupModel()
    @State private var demoRollID = 0
    @AppStorage("gn.cupConcept") private var cupConceptRaw = CupConcept.crossSection.rawValue

    private var concept: CupConcept {
        if let index = CommandLine.arguments.firstIndex(of: "-cupConcept"),
           CommandLine.arguments.indices.contains(index + 1),
           let raw = Int(CommandLine.arguments[index + 1]),
           let forced = CupConcept(rawValue: raw) {
            return forced
        }
        return CupConcept(rawValue: cupConceptRaw) ?? .crossSection
    }

    private var isPipDemo: Bool {
        CommandLine.arguments.contains("-demoPipDice")
    }

    private var isPourDemo: Bool {
        CommandLine.arguments.contains("-demoPour")
    }

    var body: some View {
        if isPourDemo {
            pourDemo
        } else if isPipDemo {
            pipTableDemo
        } else {
            cupPreview
        }
    }

    private var cupPreview: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DiceCupSceneView(diceCount: 3, model: model, concept: concept)
                .id(concept)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    CupConceptToggle(concept: concept) {
                        cupConceptRaw = concept.next.rawValue
                    }
                }
                Spacer()
            }
            .padding(.top, 10)
            .padding(.trailing, 14)
        }
    }

    /// A real 3D felt (`TableSurface`, the same one the actual table uses)
    /// with a 5-pip-die pool that throws itself once on appearing —
    /// `DiceTableSceneView`'s own `Roll` struct is `DiceGameController`'s
    /// nested type, but it's a plain internal struct with a memberwise
    /// init, so this harness can hand it a synthetic roll request directly
    /// without needing a real `DiceGameController` (there isn't one for
    /// pip games yet) or touching TableRootView.swift's routing.
    private var pipTableDemo: some View {
        ZStack {
            TableSurface()
            DiceTableSceneView(
                roll: DiceGameController.Roll(id: 1, seat: 0, count: 5, intensity: 1.0),
                anchor: CGPoint(x: 0.5, y: 0.85),
                diceCount: 5, faceStyle: .pips
            ) { _, _ in }
            .ignoresSafeArea()
        }
    }

    /// Bottom-rail seat, geometry copied from DiceTableView (`cupCenter` /
    /// `cupMouthScreen`): plate at the anchor, cup 92pt beyond it, mouth at
    /// `TableCupView.mouthOffset`.
    private var pourDemo: some View {
        GeometryReader { geo in
            let anchor = CGPoint(x: 0.5, y: 0.90)
            let plate = CGPoint(x: anchor.x * geo.size.width, y: anchor.y * geo.size.height)
            let cup = CGPoint(x: plate.x, y: plate.y + 92)
            let off = TableCupView.mouthOffset(for: .bottom)
            ZStack {
                TableSurface()
                TableCupView(edge: .bottom, loadedCount: 3, requiredCount: 3)
                    .tablePourTilt(seat: 0, edge: .bottom)
                    .position(cup)
                DiceTableSceneView(
                    roll: demoRollID == 0 ? nil
                        : DiceGameController.Roll(id: demoRollID, seat: 0, count: 3,
                                                  intensity: demoRollID % 2 == 1 ? 1.1 : 0.5),
                    anchor: anchor,
                    pourMouthScreen: CGPoint(x: cup.x + off.dx, y: cup.y + off.dy)
                ) { _, _ in }
                .ignoresSafeArea()
            }
            .ignoresSafeArea()
            .onAppear {
                for n in 0..<4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(n) * 5.0) {
                        demoRollID = n + 1
                    }
                }
            }
        }
    }
}
