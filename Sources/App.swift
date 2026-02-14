import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: DataStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if let store {
            HotkeyManager.shared.setup(store: store)
        }
    }

    // Show banner + sound even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Handle notification action buttons
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionID = response.actionIdentifier
        let link = response.notification.request.content.userInfo["link"] as? String
        let capturedStore = store

        MainActor.assumeIsolated {
            switch actionID {
            case NotificationManager.actionOpenDaily:
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openWindowRequest, object: "recent-notes")

            case NotificationManager.actionSnooze:
                NotificationManager.shared.snoozeReminder()

            case NotificationManager.actionOpenRSSLink:
                if let link, let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                }

            case NotificationManager.actionCopyWeekly:
                if let capturedStore {
                    WeeklyReport.copyToClipboard(from: capturedStore)
                    DevLog.shared.info("Notify", "周报已复制到剪贴板")
                }

            case NotificationManager.actionViewStats:
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openWindowRequest, object: "statistics")

            case UNNotificationDefaultActionIdentifier:
                NSApp.activate(ignoringOtherApps: true)

            default:
                break
            }
        }

        completionHandler()
    }
}

extension Notification.Name {
    static let openWindowRequest = Notification.Name("openWindowRequest")
}

@main
struct TicTrackerApp: App {
    @State private var store = DataStore()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

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
                .onReceive(NotificationCenter.default.publisher(for: .openWindowRequest)) { notification in
                    if let windowID = notification.object as? String {
                        openWindow(id: windowID)
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
