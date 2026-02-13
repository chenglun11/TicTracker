import AppKit
import Foundation

@MainActor
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

        let allDepts = Array(Set(store.departments + totals.keys)).sorted {
            let i1 = store.departments.firstIndex(of: $0)
            let i2 = store.departments.firstIndex(of: $1)
            switch (i1, i2) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0 < $1
            }
        }
        for dept in allDepts where totals[dept, default: 0] > 0 {
            lines.append("\(dept): \(totals[dept, default: 0]) 次")
        }

        let grand = totals.values.reduce(0, +)
        lines.append("合计: \(grand) 次")

        // Daily breakdown
        let weekdayFmt = DateFormatter()
        weekdayFmt.dateFormat = "M/d（EEE）"
        weekdayFmt.locale = Locale(identifier: "zh_CN")

        var detailLines: [String] = []
        var detailDate = monday
        while detailDate <= today {
            let key = fmt.string(from: detailDate)
            if let dayRecords = store.records[key] {
                let parts = allDepts
                    .filter { dayRecords[$0, default: 0] > 0 }
                    .map { "\($0)×\(dayRecords[$0]!)" }
                if !parts.isEmpty {
                    let label = weekdayFmt.string(from: detailDate)
                    detailLines.append("\(label): \(parts.joined(separator: ", "))")
                }
            }
            detailDate = calendar.date(byAdding: .day, value: 1, to: detailDate)!
        }
        if !detailLines.isEmpty {
            lines.append("")
            lines.append("--- 每日明细 ---")
            lines.append(contentsOf: detailLines)
        }

        // Append daily notes
        var noteLines: [String] = []
        var noteDate = monday
        while noteDate <= today {
            let key = fmt.string(from: noteDate)
            if let note = store.dailyNotes[key], !note.isEmpty {
                let display = displayFmt.string(from: noteDate)
                noteLines.append("\(display): \(note)")
            }
            noteDate = calendar.date(byAdding: .day, value: 1, to: noteDate)!
        }
        if !noteLines.isEmpty {
            lines.append("")
            lines.append("--- 每日记录 ---")
            lines.append(contentsOf: noteLines)
        }

        return lines.joined(separator: "\n")
    }

    static func copyToClipboard(from store: DataStore) {
        let text = generate(from: store)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
