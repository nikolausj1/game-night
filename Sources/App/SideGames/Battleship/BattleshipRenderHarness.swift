import SwiftUI

/// Sim-verify / CI helper: renders the Battleship screens to PNGs with
/// `ImageRenderer` and exits. Launch with `-renderBattleship <outputDir>`
/// (mount `BattleshipRenderHarness` from `RoleRouter` the way `-demoQuarto`
/// is mounted). Static: entrance animations and clocks don't run, so this
/// shows finished states (pegs placed, reticle lifted, effects frozen
/// mid-flight), not motion.
struct BattleshipRenderHarness: View {
    static var outputDir: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "-renderBattleship"),
              CommandLine.arguments.indices.contains(i + 1) else { return nil }
        return CommandLine.arguments[i + 1]
    }

    var body: some View {
        Color.black.ignoresSafeArea()
            .task { await render() }
    }

    @MainActor
    private func render() async {
        guard let dir = Self.outputDir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        func save<V: View>(_ name: String, _ size: CGSize, _ view: V) {
            let content = view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let data = renderer.uiImage?.pngData() {
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }

        let phone = CGSize(width: 390, height: 844)
        let ipad = CGSize(width: 1194, height: 834)
        let ipadPortrait = CGSize(width: 834, height: 1194)

        let hitFX = ChartEffect(cell: BattleshipCell(row: 3, col: 3), kind: .burst, frozenProgress: 0.28)
        let missFX = ChartEffect(cell: BattleshipCell(row: 6, col: 7), kind: .splash, frozenProgress: 0.4)

        save("phone-1-placement", phone, BattleshipHandContent(snapshot: BattleshipDemo.snapshot(.placementPartial)))
        save("phone-2-locked", phone, BattleshipHandContent(snapshot: BattleshipDemo.snapshot(.placementLocked)))
        save("phone-3-targeting-aim", phone, BattleshipHandContent(
            snapshot: BattleshipDemo.snapshot(.midBattle),
            preview: .init(aim: BattleshipCell(row: 4, col: 6),
                           toast: .init(text: "You sunk their Cruiser!", tone: .sunk, detail: "D4"),
                           targetEffects: [hitFX, missFX], freeze: true)))
        save("phone-4-fleet", phone, BattleshipHandContent(
            snapshot: BattleshipDemo.snapshot(.midBattle),
            preview: .init(page: .fleet, toast: .init(text: "They hit you!", tone: .hit, detail: "C7"),
                           fleetEffects: [hitFX], freeze: true)))
        save("phone-5-victory", phone, BattleshipHandContent(
            snapshot: BattleshipDemo.snapshot(.gameOver), preview: .init(freeze: true)))
        save("phone-6-defeat", phone, BattleshipHandContent(
            snapshot: BattleshipDemo.snapshot(.gameOver, seat: 1), preview: .init(freeze: true)))

        func table(_ stage: BattleshipDemo.Stage, salvo: Bool = false) -> some View {
            ZStack {
                TableSurface()
                BattleshipTableContent(snapshot: BattleshipDemo.table(stage, salvo: salvo),
                                       names: BattleshipDemo.names, botSeats: [1])
            }
        }
        save("table-1-battle", ipad, table(.midBattle))
        save("table-2-deploying", ipad, table(.placementLocked))
        save("table-3-gameover", ipad, table(.gameOver))
        save("table-4-salvo-portrait", ipadPortrait, table(.midBattle, salvo: true))

        // Let the writes land, then leave: this is a one-shot tool.
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(0)
    }
}
