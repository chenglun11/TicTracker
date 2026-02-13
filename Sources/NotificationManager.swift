import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private let reminderID = "daily-note-reminder"

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func scheduleReminder(hour: Int, minute: Int) {
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
        center.add(request)
    }

    func cancelReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
    }
}
