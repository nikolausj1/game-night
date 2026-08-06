import SwiftUI
import TipKit

@main
struct GameNightApp: App {
    init() {
        // The three magic-gesture onboarding tips (see GameTips.swift) —
        // each is configured to show once, immediately, the first time its
        // screen decides it's eligible.
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    var body: some Scene {
        WindowGroup {
            RoleRouter()
        }
    }
}
