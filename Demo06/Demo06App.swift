import SwiftUI

@main
struct Demo06App: App {
    @StateObject private var heartRate = PhoneHeartRateManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(heartRate)
        }
    }
}
