import AppKit
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private let reminderID = "daily-note-reminder"
    private let summaryID = "daily-summary"

    // MARK: - Action Identifiers

    static let actionOpenDaily = "open-daily-note"
    static let actionSnooze = "snooze"
    static let actionCopyWeekly = "copy-weekly"
    static let actionViewStats = "view-stats"

    // MARK: - Category Identifiers

    static let categoryDailyReminder = "daily-reminder"
    static let categoryDailySummary = "daily-summary"

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            print("[Notify] 通知权限: \(granted ? "已授权" : "未授权")")
            self.registerCategories()
        }
    }

    private func registerCategories() {
        let center = UNUserNotificationCenter.current()

        // daily-reminder: "打开日报" / "稍后提醒"
        let dailyOpen = UNNotificationAction(identifier: Self.actionOpenDaily, title: "打开日报", options: .foreground)
        let dailySnooze = UNNotificationAction(identifier: Self.actionSnooze, title: "稍后提醒")
        let dailyCategory = UNNotificationCategory(identifier: Self.categoryDailyReminder, actions: [dailyOpen, dailySnooze], intentIdentifiers: [])

        // daily-summary: "复制周报" / "查看详情"
        let summaryCopy = UNNotificationAction(identifier: Self.actionCopyWeekly, title: "复制周报")
        let summaryView = UNNotificationAction(identifier: Self.actionViewStats, title: "查看详情", options: .foreground)
        let summaryCategory = UNNotificationCategory(identifier: Self.categoryDailySummary, actions: [summaryCopy, summaryView], intentIdentifiers: [])

        center.setNotificationCategories([dailyCategory, summaryCategory])
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
        center.add(request) { error in
            if let error = error {
                print("[Notify] 日报提醒设置失败: \(error.localizedDescription)")
            }
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
        center.add(request) { error in
            if let error = error {
                print("[Notify] 稍后提醒设置失败: \(error.localizedDescription)")
            } else {
                print("[Notify] 稍后提醒已设置（15 分钟后）")
            }
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
        center.add(request) { error in
            if let error = error {
                print("[Notify] 每日摘要设置失败: \(error.localizedDescription)")
            } else {
                print("[Notify] 每日摘要已设置 \(String(format: "%02d:%02d", summaryHour, summaryMinute))")
            }
        }
    }

    func sendDailySummary(store: DataStore) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "今日工作摘要"

        let todayTotal = store.todayTotal
        content.body = todayTotal > 0 ? "项目支持 \(todayTotal) 次" : "今天还没有记录，明天继续加油"

        content.sound = .default
        content.categoryIdentifier = Self.categoryDailySummary

        let request = UNNotificationRequest(identifier: "\(summaryID)-now", content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                print("[Notify] 每日摘要发送失败: \(error.localizedDescription)")
            }
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
        print("[Notify] 启动时刷新日报提醒 \(String(format: "%02d:%02d", hour, minute))")
    }

    func sendWelcome() {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "TicTracker 已就绪"
        content.body = "今天也要加油哦 💪"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "welcome", content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                print("[Notify] 欢迎通知发送失败: \(error.localizedDescription)")
            }
        }
    }

    func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderID])
    }
}
