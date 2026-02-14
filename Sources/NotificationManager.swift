import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private let reminderID = "daily-note-reminder"

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        Task {
            let granted = try? await center.requestAuthorization(options: [.alert, .sound])
            DevLog.shared.info("Notify", "通知权限: \(granted == true ? "已授权" : "未授权")")
        }
    }

    func scheduleReminder(hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])

        let content = UNMutableNotificationContent()
        content.title = "别忘了写日报"
        content.body = "今天做了什么？花一分钟记录一下吧"
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)
        Task {
            try? await center.add(request)
        }
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

        let id = "rss-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            try? await center.add(request)
        }
        DevLog.shared.info("Notify", "RSS 通知: [\(feedName)] \(title)")
    }
}
