import AppKit
import Foundation

struct WeeklyReport {
    static func generate(from store: DataStore) -> String {
        let calendar = Calendar.current
        let today = Date()

        // Find Monday of this week
        let weekday = calendar.component(.weekday, from: today)
        // .weekday: Sunday=1, Monday=2 ...
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "M/d"

        // Collect all days from Monday to today
        var totals: [String: Int] = [:]
        var date = monday
        while date <= today {
            let key = fmt.string(from: date)
            if let dayRecords = store.records[key] {
                for (dept, count) in dayRecords {
                    totals[dept, default: 0] += count
                }
            }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }

        let mondayStr = displayFmt.string(from: monday)
        let todayStr = displayFmt.string(from: today)

        var lines = ["本周技术支持汇总（\(mondayStr) - \(todayStr)）"]

        let sorted = store.departments.filter { totals[$0, default: 0] > 0 }
        for dept in sorted {
            lines.append("\(dept): \(totals[dept, default: 0]) 次")
        }

        let grand = totals.values.reduce(0, +)
        lines.append("合计: \(grand) 次")

        return lines.joined(separator: "\n")
    }

    static func copyToClipboard(from store: DataStore) {
        let text = generate(from: store)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
