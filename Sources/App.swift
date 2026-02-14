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
struct TicTrackerApp: App {
    @State private var store = DataStore()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
                .onAppear {
                    if appDelegate.store == nil {
                        appDelegate.store = store
                        DevLog.shared.info("App", "启动 TicTracker")
                        HotkeyManager.shared.setup(store: store)
                        NotificationManager.shared.refreshReminderIfNeeded()
                        NotificationManager.shared.sendWelcome()
                        UpdateChecker.shared.checkInBackground()
                        RSSFeedManager.shared.setup(store: store)
                        RSSFeedManager.shared.startPolling()
                        JiraService.shared.setup(store: store)
                        if store.jiraConfig.enabled {
                            JiraService.shared.startPolling()
                        }
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
        .defaultSize(width: 600, height: 460)

        Window("最近日报", id: "recent-notes") {
            RecentNotesView(store: store)
        }
        .defaultSize(width: 360, height: 420)

        Window("RSS 订阅", id: "rss-reader") {
            RSSReaderView(store: store)
        }
        .defaultSize(width: 650, height: 500)

        Window("Jira 工单", id: "jira") {
            JiraView(store: store)
        }
        .defaultSize(width: 700, height: 500)

        Window("开发者日志", id: "dev-log") {
            DevLogView()
        }
        .defaultSize(width: 700, height: 450)

        Window("统计", id: "statistics") {
            StatisticsView(store: store)
        }
        .defaultSize(width: 650, height: 500)
    }
}
