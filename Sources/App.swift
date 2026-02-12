import SwiftUI

@main
struct TechSupportTrackerApp: App {
    @State private var store = DataStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Text("🛠 \(store.todayTotal)")
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: "settings") {
            SettingsView(store: store)
        }
        .defaultSize(width: 320, height: 400)
    }
}
