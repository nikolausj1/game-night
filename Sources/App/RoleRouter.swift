import SwiftUI

/// First screen: pick this device's role at the table. iPads default to
/// being the table, phones to being a hand — but any device can be either
/// (a kid's iPad is just a big hand).
struct RoleRouter: View {
    enum Role { case undecided, table, hand }

    @State private var role: Role = {
        if DemoData.wantsTableDemo { return .table }
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

    var body: some View {
        switch role {
        case .undecided:
            RolePickerView(
                defaultRole: UIDevice.current.userInterfaceIdiom == .pad ? .table : .hand,
                playerName: $playerName,
                onPick: { role = $0 }
            )
        case .table:
            TableRootView()
        case .hand:
            HandRootView(playerName: playerName.isEmpty ? UIDevice.current.name : playerName)
        }
    }
}

struct RolePickerView: View {
    let defaultRole: RoleRouter.Role
    @Binding var playerName: String
    let onPick: (RoleRouter.Role) -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            FeltBackground()
            VStack(spacing: 28) {
                Spacer()
                VStack(spacing: 6) {
                    Text("Game Night")
                        .font(.system(size: 46, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                    Text("The cards live here now.")
                        .font(.system(.title3, design: .serif).italic())
                        .foregroundStyle(CardStyle.gold)
                }

                VStack(spacing: 14) {
                    if defaultRole == .hand {
                        TextField("Your name", text: $playerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                            .focused($nameFocused)
                            .submitLabel(.done)
                    }

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
