import AppKit
import Foundation

@MainActor
struct WeeklyReport {
    enum Period {
        case currentWeek
        case previousWeek
    }

    private static let commentFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d HH:mm"
        return fmt
    }()

    static func generate(from store: DataStore, period: Period = .currentWeek) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Find Monday of this week
        let weekday = calendar.component(.weekday, from: today)
        // .weekday: Sunday=1, Monday=2 ...
        let daysFromMonday = (weekday + 5) % 7
        let currentMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!
        let rangeStart: Date
        let rangeEnd: Date
        switch period {
        case .currentWeek:
            rangeStart = currentMonday
            rangeEnd = today
        case .previousWeek:
            rangeEnd = calendar.date(byAdding: .day, value: -1, to: currentMonday)!
            rangeStart = calendar.date(byAdding: .day, value: -6, to: rangeEnd)!
        }
        let rangeEndExclusive = calendar.date(byAdding: .day, value: 1, to: rangeEnd)!

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "M/d"
        let startKey = fmt.string(from: rangeStart)
        let endKey = fmt.string(from: rangeEnd)

        func isDateKeyInRange(_ key: String) -> Bool {
            key >= startKey && key <= endKey
        }

        func isDateInRange(_ date: Date?) -> Bool {
            guard let date else { return false }
            return date >= rangeStart && date < rangeEndExclusive
        }

        // Collect all days in the selected report range.
        var totals: [String: Int] = [:]
        var date = rangeStart
        while date <= rangeEnd {
            let key = fmt.string(from: date)
            if let dayRecords = store.records[key] {
                for (dept, count) in dayRecords {
                    totals[dept, default: 0] += count
                }
            }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }

        let startStr = displayFmt.string(from: rangeStart)
        let endStr = displayFmt.string(from: rangeEnd)

        var lines = ["技术支持周报（\(startStr) - \(endStr)）"]

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

        // Jira 入口 counts for the week
        var jiraTotals: [String: Int] = [:]
        var jiraDate = rangeStart
        while jiraDate <= rangeEnd {
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
            lines.append("--- Jira 入口支持 ---")
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
            isDateKeyInRange(entry.dateKey) ||
            isDateInRange(entry.reportedAt) ||
            isDateInRange(entry.updatedAt) ||
            isDateInRange(entry.resolvedAt) ||
            entry.comments.contains { isDateInRange($0.createdAt) }
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
                let observing = items.filter { $0.status == .observing }.count
                let unresolved = items.count - fixed - ignored - observing
                var summary = "\(type.rawValue): \(items.count) 个（已修复 \(fixed)"
                if ignored > 0 { summary += "，已忽略 \(ignored)" }
                if observing > 0 { summary += "，观测中 \(observing)" }
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
        var detailDate = rangeStart
        while detailDate <= rangeEnd {
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
        var noteDate = rangeStart
        while noteDate <= rangeEnd {
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

    static func copyToClipboard(from store: DataStore, period: Period = .currentWeek) {
        let text = generate(from: store, period: period)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
