import AppKit
import Foundation

@MainActor
struct WeeklyReport {
    private static let commentFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d HH:mm"
        return fmt
    }()

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

        // Jira issue counts for the week
        var jiraTotals: [String: Int] = [:]
        var jiraDate = monday
        while jiraDate <= today {
            let key = fmt.string(from: jiraDate)
            if let dayCounts = store.jiraIssueCounts[key] {
                for (issueKey, count) in dayCounts {
                    jiraTotals[issueKey, default: 0] += count
                }
            }
            jiraDate = calendar.date(byAdding: .day, value: 1, to: jiraDate)!
        }
        if !jiraTotals.isEmpty {
            lines.append("")
            lines.append("--- Jira 工单支持 ---")
            let issueMap = Dictionary(uniqueKeysWithValues: store.jiraIssues.map { ($0.key, $0.summary) })
            for (issueKey, count) in jiraTotals.sorted(by: { $0.value > $1.value }) {
                let summary = issueMap[issueKey].map { " \($0)" } ?? ""
                lines.append("\(issueKey)\(summary): \(count) 次")
            }
            let jiraGrand = jiraTotals.values.reduce(0, +)
            lines.append("Jira 合计: \(jiraGrand) 次")
        }

        // Tracked issues for the week (unified)
        let weekTracked = store.trackedIssues.filter { (entry: TrackedIssue) -> Bool in
            guard let entryDate = fmt.date(from: entry.dateKey) else { return false }
            return entryDate >= monday && entryDate <= today
        }
        if !weekTracked.isEmpty {
            let sorted = weekTracked.sorted { $0.dateKey < $1.dateKey }
            lines.append("")
            lines.append("--- 问题追踪 ---")
            for issue in sorted {
                var detail = [issue.type.rawValue]
                if let dept = issue.department, !dept.isEmpty { detail.append(dept) }
                if let jira = issue.jiraKey { detail.append(jira) }
                if let assignee = issue.assignee { detail.append(assignee) }
                let suffix = " (\(detail.joined(separator: " · ")))"
                lines.append("[\(issue.status.rawValue)] \(issue.title)\(suffix)")
                for comment in issue.comments {
                    let time = Self.commentFmt.string(from: comment.createdAt)
                    lines.append("  [\(time)] \(comment.text)")
                }
            }
            // Summary by type
            let byType = Dictionary(grouping: weekTracked, by: \.type)
            for type in IssueType.allCases {
                guard let items = byType[type] else { continue }
                let fixed = items.filter { $0.status == .fixed }.count
                let ignored = items.filter { $0.status == .ignored }.count
                let unresolved = items.count - fixed - ignored
                var summary = "\(type.rawValue): \(items.count) 个（已修复 \(fixed)"
                if ignored > 0 { summary += "，已忽略 \(ignored)" }
                if unresolved > 0 { summary += "，未解决 \(unresolved)" }
                summary += "）"
                lines.append(summary)
            }
        }

        // Daily breakdown
        let weekdayFmt = DateFormatter()
        weekdayFmt.dateFormat = "M/d（EEE）"
        weekdayFmt.locale = Locale(identifier: "zh_CN")

        var detailLines: [String] = []
        let issueMap = Dictionary(uniqueKeysWithValues: store.jiraIssues.map { ($0.key, $0.summary) })
        var detailDate = monday
        while detailDate <= today {
            let key = fmt.string(from: detailDate)
            var parts: [String] = []
            if let dayRecords = store.records[key] {
                parts += allDepts
                    .filter { dayRecords[$0, default: 0] > 0 }
                    .map { "\($0)×\(dayRecords[$0]!)" }
            }
            if let dayCounts = store.jiraIssueCounts[key] {
                let jiraParts = dayCounts.sorted(by: { $0.value > $1.value })
                    .map { issueKey, count in
                        let summary = issueMap[issueKey] ?? issueKey
                        return "\(summary)×\(count)"
                    }
                parts += jiraParts
            }
            if !parts.isEmpty {
                let label = weekdayFmt.string(from: detailDate)
                detailLines.append("\(label): \(parts.joined(separator: ", "))")
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
