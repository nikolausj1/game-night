import SwiftUI

/// Table geometry for the standing frame, shared by every layer.
struct ConnectFourLayout {
    let size: CGSize

    var frameH: CGFloat {
        let byHeight = (size.height - 190) / 1.16
        let byWidth = size.width * 0.88 * ConnectFourGeometry.aspect
        return max(160, min(byHeight, byWidth, 700))
    }
    var frameW: CGFloat { frameH / ConnectFourGeometry.aspect }
    /// Top-left of the frame image.
    var origin: CGPoint {
        CGPoint(x: (size.width - frameW) / 2,
                y: (size.height - frameH * 1.16) / 2 + frameH * 0.16)
    }
    var frameBottom: CGFloat { origin.y + frameH }
    var hoverTop: CGFloat { origin.y - frameH * 0.16 }

    func plaqueCenter(seat: Int) -> CGPoint {
        if seat == 0 { return CGPoint(x: size.width / 2, y: (frameBottom + size.height) / 2 + 4) }
        return CGPoint(x: size.width / 2, y: max(34, hoverTop / 2 - 2))
    }

    func holeCenter(row: Int, column: Int) -> CGPoint {
        CGPoint(x: origin.x + ConnectFourGeometry.colX[column] * frameW,
                y: origin.y + ConnectFourGeometry.rowY[row] * frameH)
    }

    func discCenter(column: Int, yFraction: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + ConnectFourGeometry.colX[column] * frameW, y: origin.y + yFraction * frameH)
    }

    var discSize: CGFloat { ConnectFourGeometry.disc * frameW }
}

/// The whole standing board. LAYER ORDER (back to front) is the point:
///
///   1. the frame's cast shadow on the felt
///   2. the DISCS (resting ones, the falling one, the held one)
///   3. the frame photo, whose 42 holes are alpha 0
///   4. light effects (column highlight, winning-line glow)
///
/// Because discs sit BEHIND the frame image and the felt sits behind the
/// discs, a falling disc genuinely disappears behind the front plate, shows
/// through each hole as it passes, and ends up seen through its own hole,
/// exactly how the real toy reads from the front.
struct ConnectFourFrameView: View {
    let controller: ConnectFourController
    let layout: ConnectFourLayout
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            shadowLayer
            discLayer
            frameLayer
            lightLayer
            touchLayer
            accessibilityLayer
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    // MARK: 1. Shadow

    private var shadowLayer: some View {
        Image("ConnectFourFrame")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(.black)
            .frame(width: layout.frameW, height: layout.frameH)
            .blur(radius: layout.frameW * 0.012)
            .opacity(0.42)
            .offset(x: layout.frameW * 0.012, y: layout.frameH * 0.022)
            .position(x: layout.origin.x + layout.frameW / 2, y: layout.origin.y + layout.frameH / 2)
            .allowsHitTesting(false)
    }

    // MARK: 2. Discs (BEHIND the frame)

    private var discLayer: some View {
        let cells = controller.visibleCells
        let d = layout.discSize
        return ZStack {
            ForEach(0..<42, id: \.self) { cell in
                if let seat = cells[cell] {
                    Image(seat == 0 ? "ConnectFourDiscRed" : "ConnectFourDiscYellow")
                        .resizable()
                        .frame(width: d, height: d)
                        .position(layout.holeCenter(row: cell / 7, column: cell % 7))
                        .transition(.identity)
                }
            }
            fallingDisc
            heldDisc
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var fallingDisc: some View {
        if let falling = controller.falling, let plan = controller.dropPlan {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(falling.start)
                Image(falling.seat == 0 ? "ConnectFourDiscRed" : "ConnectFourDiscYellow")
                    .resizable()
                    .frame(width: layout.discSize, height: layout.discSize)
                    .position(layout.discCenter(column: falling.column, yFraction: CGFloat(plan.y(at: t))))
            }
        }
    }

    /// The disc waiting above the frame, lined up over a column. Visible to
    /// everyone whenever it is somebody's turn and nothing is falling.
    @ViewBuilder
    private var heldDisc: some View {
        let state = controller.state
        if !controller.isBusy, state.phase == .playing {
            let column = controller.hoverColumn ?? 3
            Image(state.currentPlayer == 0 ? "ConnectFourDiscRed" : "ConnectFourDiscYellow")
                .resizable()
                .frame(width: layout.discSize, height: layout.discSize)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 5)
                .opacity(controller.hoverColumn == nil && !state.players[state.currentPlayer].isBot ? 0.62 : 0.96)
                .position(layout.discCenter(column: column, yFraction: ConnectFourGeometry.hoverY))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.36), value: column)
                .animation(.easeOut(duration: 0.2), value: controller.hoverColumn == nil)
        }
    }

    // MARK: 3. Frame

    private var frameLayer: some View {
        Image("ConnectFourFrame")
            .resizable()
            .frame(width: layout.frameW, height: layout.frameH)
            .position(x: layout.origin.x + layout.frameW / 2, y: layout.origin.y + layout.frameH / 2)
            .allowsHitTesting(false)
    }

    // MARK: 4. Light

    private var lightLayer: some View {
        ZStack {
            // Column highlight: a soft lit stripe down the column the held
            // disc is over (it also tells a bot's aim).
            if !controller.isBusy, controller.state.phase == .playing, let column = controller.hoverColumn {
                let x = layout.origin.x + ConnectFourGeometry.colX[column] * layout.frameW
                let w = layout.frameW * ConnectFourGeometry.hole * 1.45
                LinearGradient(colors: [.clear, CardStyle.gold.opacity(0.22), CardStyle.gold.opacity(0.16), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: w, height: layout.frameH * 0.99)
                    .blendMode(.plusLighter)
                    .position(x: x, y: layout.origin.y + layout.frameH * 0.5)
                    .transition(.opacity)
            }
            winningGlow
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: controller.hoverColumn)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var winningGlow: some View {
        let state = controller.state
        if state.phase == .gameOver, !controller.isBusy, let line = state.winningLine {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let pulse = reduceMotion ? 1.0 : 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 5.0)
                ZStack {
                    ForEach(line, id: \.self) { cell in
                        let c = layout.holeCenter(row: cell / 7, column: cell % 7)
                        let d = layout.discSize
                        Circle()
                            .fill(RadialGradient(colors: [CardStyle.gold.opacity(0.0), CardStyle.gold.opacity(0.55 * pulse)],
                                                 center: .center, startRadius: d * 0.1, endRadius: d * 0.55))
                            .overlay(Circle().strokeBorder(Color(red: 1.0, green: 0.93, blue: 0.62).opacity(0.55 + 0.45 * pulse), lineWidth: max(2, d * 0.07)))
                            .shadow(color: CardStyle.gold.opacity(0.9 * pulse), radius: d * 0.35)
                            .frame(width: d * 1.1, height: d * 1.1)
                            .blendMode(.plusLighter)
                            .position(c)
                    }
                }
            }
        }
    }

    // MARK: Touch

    @State private var touching = false

    /// Slide to aim, lift to drop. A quick tap drops straight into the
    /// tapped column. The zone covers the frame plus the space above it
    /// where the held disc waits.
    private var touchLayer: some View {
        let zoneX = layout.origin.x - layout.frameW * 0.04
        let zoneW = layout.frameW * 1.08
        let zoneY = layout.hoverTop - 10
        let zoneH = layout.frameBottom - zoneY
        return Color.clear
            .frame(width: zoneW, height: zoneH)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard controller.humanTurn else { return }
                        let column = ConnectFourGeometry.column(atX: (value.location.x + zoneX - layout.origin.x) / layout.frameW)
                        if column != controller.hoverColumn {
                            if column != nil { Haptics.tick() }
                            controller.hoverColumn = column
                        }
                    }
                    .onEnded { value in
                        guard controller.humanTurn else { controller.hoverColumn = nil; return }
                        let column = ConnectFourGeometry.column(atX: (value.location.x + zoneX - layout.origin.x) / layout.frameW)
                        guard let column else { controller.hoverColumn = nil; return }
                        if controller.state.legalColumns.contains(column) {
                            controller.drop(column: column)
                        } else {
                            Haptics.arm()   // full column
                            controller.hoverColumn = nil
                        }
                    }
            )
            .position(x: zoneX + zoneW / 2, y: zoneY + zoneH / 2)
    }

    private var accessibilityLayer: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { column in
                let x = layout.origin.x + ConnectFourGeometry.colX[column] * layout.frameW
                let full = !controller.state.legalColumns.contains(column)
                Color.clear
                    .frame(width: layout.frameW * 0.1, height: layout.frameH)
                    .position(x: x, y: layout.origin.y + layout.frameH / 2)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Column \(column + 1)\(full ? ", full" : "")"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Drops a disc"))
                    .accessibilityAction { if controller.humanTurn, !full { controller.drop(column: column) } }
            }
        }
        .allowsHitTesting(false)
    }
}
