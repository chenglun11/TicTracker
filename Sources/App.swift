import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: DataStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let store {
            HotkeyManager.shared.setup(store: store)
        }
    }
}

@main
struct TechSupportTrackerApp: App {
    @State private var store = DataStore()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
                .onAppear {
                    if appDelegate.store == nil {
                        appDelegate.store = store
                        HotkeyManager.shared.setup(store: store)
                    }
                }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "plus.circle.fill")
                Text("\(store.todayTotal)")
            }
        }
        .menuBarExtraStyle(.window)

        Window("设置", id: "settings") {
            SettingsView(store: store)
        }
        .defaultSize(width: 500, height: 460)

        Window("最近日报", id: "recent-notes") {
            RecentNotesView(store: store)
        }
        .defaultSize(width: 360, height: 420)
    }
}
