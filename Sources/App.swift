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
        .defaultSize(width: 420, height: 360)

        Window("最近日报", id: "recent-notes") {
            RecentNotesView(store: store)
        }
        .defaultSize(width: 360, height: 420)
    }
}
