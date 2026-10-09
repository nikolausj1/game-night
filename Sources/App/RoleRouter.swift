import SwiftUI

/// First screen: pick this device's role at the table. iPads default to
/// being the table, phones to being a hand — but any device can be either
/// (a kid's iPad is just a big hand).
struct RoleRouter: View {
    enum Role { case undecided, table, hand }

    @State private var role: Role = {
        if DemoData.wantsTableDemo || DemoData.wantsFreePlayDemo { return .table }
        if DemoData.wantsHandDemo { return .hand }
        // Sim-verify hook: -autoRole table|hand skips the picker.
        if let index = CommandLine.arguments.firstIndex(of: "-autoRole"),
           CommandLine.arguments.indices.contains(index + 1) {
            switch CommandLine.arguments[index + 1] {
            case "table": return .table
            case "hand": return .hand
            default: break
            }
        }
        return .undecided
    }()
    @AppStorage("gn.playerName") private var playerName = ""
    @AppStorage("gn.playerColor") private var playerColorIndex = -1

    // Sim-verify hooks bypass the interactive name+color prompt entirely —
    // -demoHand and -autoRole both need to land straight in HandRootView
    // with no touch input for automated screenshots to work.
    private var skipNamePrompt: Bool {
        DemoData.wantsHandDemo || CommandLine.arguments.contains("-autoRole")
    }

    var body: some View {
        // Sim-verify hook: -autoCupPreview shows the dice cup interior
        // standalone (see DiceCupPreviewHarness).
        if CommandLine.arguments.contains("-autoCupPreview") {
            DiceCupPreviewHarness()
        } else if SolitaireDemo.wantsDemo {
            // Sim-verify hook: -demoSolitaire drops straight into a
            // scripted mid-game Solitaire table, bypassing the role
            // picker/lobby entirely — Solitaire is a local, table-less
            // game (see SolitaireDemo's own doc comment), so there's no
            // host session to route through. `onClose` is a no-op: this
            // harness has nowhere to return to, same as
            // DiceCupPreviewHarness above.
            SolitaireView(onClose: {})
        } else if DotsAndBoxesDemoData.wantsDemo {
            // Sim-verify hook: -demoDotsAndBoxes, same shape as
            // -demoSolitaire above (see DotsAndBoxesDemoData's doc comment).
            DotsAndBoxesView(onClose: {})
        } else if QuartoDemo.wantsQuartoDemo {
            // Sim-verify hook: -demoQuarto, same shape as -demoSolitaire
            // above (see QuartoDemo's doc comment).
            QuartoView(onClose: {})
        } else {
            roleSwitch
        }
    }

    @ViewBuilder
    private var roleSwitch: some View {
        switch role {
        case .undecided:
            RolePickerView(
                defaultRole: UIDevice.current.userInterfaceIdiom == .pad ? .table : .hand,
                onPick: { role = $0 }
            )
        case .table:
            TableRootView()
        case .hand:
            // First run (name never chosen): the hand header used to show
            // the raw device name ("iPhone 16 Pro Max") because this fell
            // straight through to HandRootView, which starts the Multipeer
            // session immediately on init — so by the time anyone could
            // rename themselves, "hello" had already gone out under the
            // device name. Gating construction of HandRootView behind the
            // name prompt means the session simply doesn't start until
            // Done is tapped.
            if !skipNamePrompt, playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FirstLaunchNameView(playerName: $playerName, playerColorIndex: $playerColorIndex)
            } else {
                HandRootView(playerName: playerName.isEmpty ? UIDevice.current.name : playerName,
                             onLeave: { role = .undecided })
            }
        }
    }
}

struct RolePickerView: View {
    let defaultRole: RoleRouter.Role
    let onPick: (RoleRouter.Role) -> Void

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 6) {
                    Text("Game Night")
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                        .foregroundStyle(.white)
                    Text("The cards live here now.")
                        .font(.system(.title3, design: .serif).italic())
                        .foregroundStyle(CardStyle.gold)
                }

                VStack(spacing: 14) {
                    Button {
                        onPick(defaultRole)
                    } label: {
                        Label(defaultRole == .table ? "Host the table" : "Pick up your hand",
                              systemImage: defaultRole == .table
                                  ? "rectangle.inset.filled"
                                  : "hand.raised.fill")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: 320)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CardStyle.gold)
                    .foregroundStyle(CardStyle.ink)

                    Button {
                        onPick(defaultRole == .table ? .hand : .table)
                    } label: {
                        Text(defaultRole == .table
                             ? "Join as a hand instead"
                             : "Make this device the table")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                Spacer()
                Spacer()
            }
            .padding()
        }
    }
}

/// Shown once, before this phone's very first session ever opens: picks the
/// name and a felt-friendly color other players will see at the table.
/// Reached only when `gn.playerName` has never been set (see RoleRouter's
/// `.hand` case) — every later launch has a name and skips straight to
/// HandRootView, same as before this existed.
struct FirstLaunchNameView: View {
    @Binding var playerName: String
    @Binding var playerColorIndex: Int
    @FocusState private var nameFocused: Bool

    /// Six felt-friendly tones: saturated enough to read as "your color"
    /// against green felt, but none of them fight the felt's own green or
    /// blend into it (a felt-green swatch would be invisible on the table).
    static let palette: [Color] = [
        Color(red: 0.60, green: 0.13, blue: 0.14),  // deep red
        CardStyle.gold,
        CardStyle.stockTop,                          // ivory (card stock)
        Color(red: 0.35, green: 0.62, blue: 0.82),   // sky
        Color(red: 0.46, green: 0.25, blue: 0.49),   // plum
        Color(red: 0.13, green: 0.34, blue: 0.22)    // forest
    ]

    private var trimmedName: String { playerName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 6) {
                    Text("Who's playing?")
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                        .foregroundStyle(.white)
                    Text("Pick a name and a color for the table.")
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(spacing: 20) {
                    TextField("Your name", text: $playerName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .multilineTextAlignment(.center)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(commitIfReady)

                    HStack(spacing: 14) {
                        ForEach(Self.palette.indices, id: \.self) { index in
                            colorDot(index)
                        }
                    }
                }

                Button(action: commitIfReady) {
                    Text("Done")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: 280)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(CardStyle.gold)
                .foregroundStyle(CardStyle.ink)
                .disabled(trimmedName.isEmpty)

                Spacer()
                Spacer()
            }
            .padding()
        }
        .onAppear {
            // No color chosen yet on a truly fresh install — pre-select the
            // first swatch so Done is never blocked on an invisible choice.
            if playerColorIndex < 0 || playerColorIndex >= Self.palette.count {
                playerColorIndex = 0
            }
            nameFocused = true
        }
    }

    private func colorDot(_ index: Int) -> some View {
        let isSelected = playerColorIndex == index
        return Button {
            Haptics.tick()
            playerColorIndex = index
        } label: {
            Circle()
                .fill(Self.palette[index])
                .frame(width: 40, height: 40)
                .overlay(
                    Circle().strokeBorder(.white.opacity(isSelected ? 0.95 : 0.25),
                                          lineWidth: isSelected ? 3 : 1)
                )
                .shadow(color: .black.opacity(0.3), radius: isSelected ? 5 : 2, y: 1)
                .scaleEffect(isSelected ? 1.12 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel(Self.colorNames[index])
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Spoken names matching `palette`'s order, one-to-one — see the
    /// tones documented above each swatch.
    private static let colorNames = [
        "Deep red", "Gold", "Ivory", "Sky blue", "Plum", "Forest green"
    ]

    private func commitIfReady() {
        guard !trimmedName.isEmpty else { return }
        Haptics.play()
        nameFocused = false
        // Trim on commit only (not per-keystroke) so mid-typing whitespace
        // doesn't fight the text field's cursor.
        playerName = trimmedName
    }
}

/// Verification probe (tools/verify): `-showA11y` stamps the live
/// Reduce Motion state on screen so the matrix can prove the setting
/// actually reached the app.
struct A11yProbeOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if CommandLine.arguments.contains("-showA11y") {
                Text("RM:\(UIAccessibility.isReduceMotionEnabled ? 1 : 0)")
                    .font(.caption.monospaced()).padding(6)
                    .background(.black.opacity(0.6)).foregroundStyle(.white)
            }
        }
    }
}
