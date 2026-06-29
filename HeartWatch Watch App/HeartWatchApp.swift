import SwiftUI

@main
struct HeartWatch_Watch_AppApp: App {
    @StateObject private var heartRate = WatchHeartRateManager()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(heartRate)
        }
    }
}
