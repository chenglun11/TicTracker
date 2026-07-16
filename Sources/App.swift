import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    var store: DataStore? {
        didSet {
            if didFinishLaunching {
                initializeServicesIfNeeded()
            }
        }
    }
    private var didInitializeServices = false
    private var didFinishLaunching = false
    private var explicitTerminationRequested = false
    private var launchTerminationProtectionUntil: Date?
    private var quitObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        launchTerminationProtectionUntil = Date().addingTimeInterval(15)
        quitObserver = NotificationCenter.default.addObserver(
            forName: .requestAppQuit,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.requestQuit()
            }
        }
        didFinishLaunching = true
        initializeServicesIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if explicitTerminationRequested {
            return .terminateNow
        }
        if let launchTerminationProtectionUntil, Date() < launchTerminationProtectionUntil {
            DevLog.shared.warn("App", "忽略启动阶段的系统终止请求，避免菜单栏状态导致本地服务被关闭")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flushPendingSaves()
        if let quitObserver {
            NotificationCenter.default.removeObserver(quitObserver)
        }
    }

    private func requestQuit() {
        explicitTerminationRequested = true
        NSApp.terminate(nil)
    }

    @MainActor
    private func initializeServicesIfNeeded() {
        guard !didInitializeServices, let store else { return }
        didInitializeServices = true
        DevLog.shared.info("App", "启动 TicTracker")
        KeychainHelper.warmUpAccess()
        FeishuBotService.warmUpSecrets()
        DevLog.shared.info("App", "已完成 Keychain 预热")
        HotkeyManager.shared.setup(store: store)
        NotificationManager.shared.refreshReminderIfNeeded()
        NotificationManager.shared.sendWelcome()
        UpdateChecker.shared.checkInBackground()
        RSSFeedManager.shared.setup(store: store)
        if store.rssEnabled {
            RSSFeedManager.shared.startPolling()
        }
        JiraService.shared.setup(store: store)
        if store.jiraConfig.enabled {
            JiraService.shared.startPolling()
        }
        FeishuBotService.shared.setup(store: store)
        if store.feishuBotConfig.enabled {
            FeishuBotService.shared.startScheduler()
        }
        LinearService.shared.setup(store: store)
        if store.linearConfig.enabled {
            LinearService.shared.startPolling()
        }
        LocalMCPServer.shared.setup(store: store)
        if SyncManager.shared.config.enabled && !SyncManager.shared.automaticSyncPaused {
            Task { await SyncManager.shared.sync(store: store) }
            SyncManager.shared.startPeriodicSync(store: store)
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
        let taskIDString = response.notification.request.content.userInfo["taskID"] as? String
        let dateKey = response.notification.request.content.userInfo["dateKey"] as? String
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

            case NotificationManager.actionCompleteTask:
                if let taskIDString,
                   let taskID = UUID(uuidString: taskIDString),
                   let dateKey,
                   let capturedStore {
                    if let index = capturedStore.todoTasks.firstIndex(where: { $0.id == taskID }) {
                        var updatedTask = capturedStore.todoTasks[index]
                        updatedTask.isCompleted = true
                        updatedTask.completedAt = Date()
                        capturedStore.updateTask(updatedTask, forKey: dateKey)
                        DevLog.shared.info("Notify", "任务已标记完成")
                    }
                }

            case NotificationManager.actionSnoozeTask:
                if let taskIDString,
                   let taskID = UUID(uuidString: taskIDString),
                   let dateKey,
                   let capturedStore {
                    if let task = capturedStore.todoTasks.first(where: { $0.id == taskID }) {
                        NotificationManager.shared.snoozeTaskNotification(task: task, dateKey: dateKey)
                    }
                }

            case NotificationManager.actionOpenTodo:
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .openWindowRequest, object: "todo")

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
    static let generateWeeklyReport = Notification.Name("generateWeeklyReport")
    static let requestAppQuit = Notification.Name("requestAppQuit")
}

@main
struct TicTrackerApp: App {
    @State private var store: DataStore
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    init() {
        Self.migrateLegacyDefaultsIfNeeded()
        let store = DataStore()
        _store = State(initialValue: store)
        appDelegate.store = store
    }

    private static func migrateLegacyDefaultsIfNeeded() {
        let legacyBundleID = "com.maxli.TicTracker"
        guard Bundle.main.bundleIdentifier != legacyBundleID else { return }

        let migrationKey = "migratedDefaultsFrom.\(legacyBundleID)"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey),
              let legacyDefaults = UserDefaults(suiteName: legacyBundleID),
              let legacyDomain = legacyDefaults.persistentDomain(forName: legacyBundleID) else {
            return
        }

        for (key, value) in legacyDomain where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migrationKey)
        defaults.synchronize()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
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

        Window("最近日记", id: "recent-notes") {
            RecentNotesView(store: store)
        }
        .defaultSize(width: 360, height: 420)

        Window("RSS 订阅", id: "rss-reader") {
            RSSReaderView(store: store)
        }
        .defaultSize(width: 650, height: 500)

        Window("Jira 入口", id: "jira") {
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

        Window("AI 对话", id: "ai-chat") {
            AIChatView(store: store)
        }
        .defaultSize(width: 600, height: 700)

        Window("待办任务", id: "todo") {
            TodoView(store: store)
        }
        .defaultSize(width: 650, height: 550)

        Window("问题追踪", id: "issue-tracker") {
            IssueTrackerView(store: store)
        }
        .defaultSize(width: 650, height: 500)

        Window("问题月报", id: "issue-month-report") {
            ReportPeriodSummaryView(store: store)
        }
        .defaultSize(width: 920, height: 760)
    }
}
