import SwiftUI

/// Temporary bootstrap screen; replaced once Lobby lands.
struct RootView: View {
    var body: some View {
        ZStack {
            Color(red: 0.18, green: 0.37, blue: 0.28).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Game Night")
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Text("Setting the table…")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

#Preview {
    RootView()
}
