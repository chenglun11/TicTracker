import AppKit
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private let reminderID = "daily-note-reminder"
    private let summaryID = "daily-summary"

    // MARK: - Action Identifiers

    static let actionOpenDaily = "open-daily-note"
    static let actionSnooze = "snooze"
    static let actionOpenRSSLink = "open-rss-link"
    static let actionCopyWeekly = "copy-weekly"
    static let actionViewStats = "view-stats"

    // MARK: - Category Identifiers

    static let categoryDailyReminder = "daily-reminder"
    static let categoryRSSItem = "rss-item"
    static let categoryDailySummary = "daily-summary"

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        Task {
            let granted = try? await center.requestAuthorization(options: [.alert, .sound])
            DevLog.shared.info("Notify", "通知权限: \(granted == true ? "已授权" : "未授权")")
            registerCategories()
        }
    }

    private func registerCategories() {
        let center = UNUserNotificationCenter.current()

        // daily-reminder: "打开日报" / "稍后提醒"
        let dailyOpen = UNNotificationAction(identifier: Self.actionOpenDaily, title: "打开日报", options: .foreground)
        let dailySnooze = UNNotificationAction(identifier: Self.actionSnooze, title: "稍后提醒")
        let dailyCategory = UNNotificationCategory(identifier: Self.categoryDailyReminder, actions: [dailyOpen, dailySnooze], intentIdentifiers: [])

        // rss-item: "打开链接"
        let rssOpen = UNNotificationAction(identifier: Self.actionOpenRSSLink, title: "打开链接", options: .foreground)
        let rssCategory = UNNotificationCategory(identifier: Self.categoryRSSItem, actions: [rssOpen], intentIdentifiers: [])

        // daily-summary: "复制周报" / "查看详情"
        let summaryCopy = UNNotificationAction(identifier: Self.actionCopyWeekly, title: "复制周报")
        let summaryView = UNNotificationAction(identifier: Self.actionViewStats, title: "查看详情", options: .foreground)
        let summaryCategory = UNNotificationCategory(identifier: Self.categoryDailySummary, actions: [summaryCopy, summaryView], intentIdentifiers: [])

        center.setNotificationCategories([dailyCategory, rssCategory, summaryCategory])
    }

    func scheduleReminder(hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])

        let content = UNMutableNotificationContent()
        content.title = "别忘了写日报"
        content.body = "今天做了什么？花一分钟记录一下吧"
        content.sound = .default
        content.categoryIdentifier = Self.categoryDailyReminder

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)
        Task {
            try? await center.add(request)
        }

        // Schedule daily summary 30 minutes later if enabled
        if UserDefaults.standard.object(forKey: "summaryEnabled") as? Bool ?? true {
            scheduleDailySummary(hour: hour, minute: minute)
        }
    }

    func snoozeReminder() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "别忘了写日报"
        content.body = "15 分钟前提醒过你哦，快去写日报吧"
        content.sound = .default
        content.categoryIdentifier = Self.categoryDailyReminder

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: "\(reminderID)-snooze", content: content, trigger: trigger)
        Task {
            try? await center.add(request)
            DevLog.shared.info("Notify", "稍后提醒已设置（15 分钟后）")
        }
    }

    // MARK: - Daily Summary

    private func scheduleDailySummary(hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [summaryID])

        // 30 minutes after reminder
        let totalMinutes = hour * 60 + minute + 30
        let summaryHour = (totalMinutes / 60) % 24
        let summaryMinute = totalMinutes % 60

        let content = UNMutableNotificationContent()
        content.title = "今日工作摘要"
        content.body = "点击查看今日统计"
        content.sound = .default
        content.categoryIdentifier = Self.categoryDailySummary

        var dateComponents = DateComponents()
        dateComponents.hour = summaryHour
        dateComponents.minute = summaryMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(identifier: summaryID, content: content, trigger: trigger)
        Task {
            try? await center.add(request)
            DevLog.shared.info("Notify", "每日摘要已设置 \(String(format: "%02d:%02d", summaryHour, summaryMinute))")
        }
    }

    func sendDailySummary(store: DataStore) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "今日工作摘要"

        let todayTotal = store.todayTotal
        let jiraTodayTotal = store.jiraIssueCounts[store.todayKey]?.values.reduce(0, +) ?? 0
        var parts: [String] = []
        if todayTotal > 0 { parts.append("项目支持 \(todayTotal) 次") }
        if jiraTodayTotal > 0 { parts.append("Jira 工单 \(jiraTodayTotal) 次") }
        content.body = parts.isEmpty ? "今天还没有记录，明天继续加油" : parts.joined(separator: "，")

        content.sound = .default
        content.categoryIdentifier = Self.categoryDailySummary

        let request = UNNotificationRequest(identifier: "\(summaryID)-now", content: content, trigger: nil)
        Task {
            try? await center.add(request)
        }
    }

    func cancelSummary() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [summaryID])
    }

    func refreshReminderIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "reminderEnabled") else { return }
        let hour = UserDefaults.standard.object(forKey: "reminderHour") as? Int ?? 17
        let minute = UserDefaults.standard.object(forKey: "reminderMinute") as? Int ?? 30
        scheduleReminder(hour: hour, minute: minute)
        DevLog.shared.info("Notify", "启动时刷新日报提醒 \(String(format: "%02d:%02d", hour, minute))")
    }

    func sendWelcome() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "TicTracker 已就绪"
        content.body = "今天也要加油哦 💪"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "welcome", content: content, trigger: nil)
        Task {
            try? await center.add(request)
        }
    }

    func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderID])
    }

    // MARK: - RSS Notifications

    func notifyRSSItem(feedName: String, title: String, link: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "[\(feedName)] 新条目"
        content.body = title
        content.sound = .default
        content.userInfo = ["link": link]
        content.categoryIdentifier = Self.categoryRSSItem

        let id = "rss-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            try? await center.add(request)
        }
        DevLog.shared.info("Notify", "RSS 通知: [\(feedName)] \(title)")
    }
}
