import AppKit
import Foundation

@MainActor
struct WeeklyReport {
    enum Period: Sendable {
        case currentWeek
        case previousWeek
        case currentMonth
        case previousMonth

        nonisolated var reportName: String {
            switch self {
            case .currentWeek, .previousWeek:
                return "周报"
            case .currentMonth, .previousMonth:
                return "月报"
            }
        }
    }

    nonisolated static func dateRange(for period: Period, now: Date = Date()) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let currentMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!

        switch period {
        case .currentWeek:
            return (currentMonday, today)
        case .previousWeek:
            let end = calendar.date(byAdding: .day, value: -1, to: currentMonday)!
            return (calendar.date(byAdding: .day, value: -6, to: end)!, end)
        case .currentMonth:
            return (currentMonthStart, today)
        case .previousMonth:
            let end = calendar.date(byAdding: .day, value: -1, to: currentMonthStart)!
            return (calendar.date(from: calendar.dateComponents([.year, .month], from: end))!, end)
        }
    }

    static func generate(from store: DataStore, period: Period = .currentWeek) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let (rangeStart, rangeEnd) = dateRange(for: period, now: today)
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

        var lines = ["技术支持\(period.reportName)（\(startStr) - \(endStr)）"]

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

        // Tracked issues created/reported in the selected period. Use visibleTrackedIssues
        // so source toggles (for example hiding Feishu tasks) are respected in reports.
        let weekTracked = store.visibleTrackedIssues.filter { (entry: TrackedIssue) -> Bool in
            isDateKeyInRange(entry.dateKey) ||
            isDateInRange(entry.createdAt) ||
            isDateInRange(entry.reportedAt)
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
                lines.append("[\(issue.displayStatusName)] \(issue.title)\(suffix)")
            }
            // Summary by type
            let byType = Dictionary(grouping: weekTracked, by: \.type)
            for type in IssueType.allCases {
                guard let items = byType[type] else { continue }
                let fixed = items.filter { $0.effectiveStatus == .fixed }.count
                let ignored = items.filter { $0.effectiveStatus == .ignored }.count
                let observing = items.filter { $0.effectiveStatus == .observing }.count
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

    static func generateIssueTrackingReport(from store: DataStore, period: Period = .currentMonth) -> String {
        generateIssueTrackingReport(from: store.visibleTrackedIssues, period: period)
    }

    nonisolated static func generateIssueTrackingReport(from sourceIssues: [TrackedIssue], period: Period = .currentMonth, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let (rangeStart, rangeEnd) = dateRange(for: period, now: now)
        let rangeEndExclusive = calendar.date(byAdding: .day, value: 1, to: rangeEnd)!
        let keyFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM-dd"
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "M/d"
        let dateTimeFmt = DateFormatter()
        dateTimeFmt.dateFormat = "yyyy-MM-dd HH:mm"

        let startKey = keyFmt.string(from: rangeStart)
        let endKey = keyFmt.string(from: rangeEnd)
        func dateKey(from date: Date) -> String {
            keyFmt.string(from: date)
        }
        func primaryDate(_ issue: TrackedIssue) -> Date {
            issue.reportedAt ?? issue.createdAt
        }
        func primaryCreatedKey(_ issue: TrackedIssue) -> String {
            dateKey(from: primaryDate(issue))
        }
        func hasReportUpdateActivity(_ issue: TrackedIssue) -> Bool {
            let createdKey = primaryCreatedKey(issue)
            let resolvedKey = issue.resolvedAt.map { dateKey(from: $0) }
            return issue.comments.contains { comment in
                guard isReportUpdateComment(comment) else { return false }
                let key = dateKey(from: comment.createdAt)
                guard key >= startKey && key <= endKey else { return false }
                guard key != createdKey else { return false }
                guard key != resolvedKey else { return false }
                return true
            }
        }
        func normalizedAssignee(_ issue: TrackedIssue) -> String {
            if let assignee = issue.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
                return assignee
            }
            if let assignee = issue.linearAssignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
                return assignee
            }
            return "未分配"
        }
        func isReportUpdateComment(_ comment: IssueComment) -> Bool {
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            if text.hasPrefix("[Linear] 已导入") || text.hasPrefix("[Linear] 已通过链接导入") {
                return false
            }
            return true
        }
        func issueDateTimeText(_ date: Date) -> String {
            dateTimeFmt.string(from: date)
        }
        func issueLatestActivityDate(_ issue: TrackedIssue) -> Date {
            var dates = [issue.createdAt]
            if let reportedAt = issue.reportedAt { dates.append(reportedAt) }
            if let updatedAt = issue.updatedAt { dates.append(updatedAt) }
            if let resolvedAt = issue.resolvedAt { dates.append(resolvedAt) }
            dates.append(contentsOf: issue.comments.map(\.createdAt))
            return dates.max() ?? issue.updatedAt ?? issue.createdAt
        }
        func issueTimelineText(_ issue: TrackedIssue) -> String {
            "创建 \(issueDateTimeText(issue.createdAt)) · 更新 \(issueDateTimeText(issueLatestActivityDate(issue)))"
        }

        let issues = sourceIssues
            .filter { issue in
                let date = primaryDate(issue)
                return date >= rangeStart && date < rangeEndExclusive
            }
            .sorted {
                if $0.isEffectivelyResolved != $1.isEffectivelyResolved { return !$0.isEffectivelyResolved }
                return primaryDate($0) > primaryDate($1)
            }

        let startStr = displayFmt.string(from: rangeStart)
        let endStr = displayFmt.string(from: rangeEnd)
        var lines = ["问题追踪\(period.reportName)（\(startStr) - \(endStr)）"]
        let openIssues = sourceIssues
            .filter { issue in
                guard !issue.isEffectivelyResolved, issue.effectiveStatus != .observing else { return false }
                return primaryDate(issue) < rangeEndExclusive
            }
            .sorted { primaryDate($0) < primaryDate($1) }
        let openCount = openIssues.count
        let resolvedCount = issues.filter { $0.isEffectivelyResolved }.count
        let createdCount = issues.count
        let updatedCount = issues.filter(hasReportUpdateActivity).count
        let referenceDate = min(Date(), rangeEndExclusive)
        let staleThreshold = calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
        let staleCount = openIssues.filter { primaryDate($0) < staleThreshold }.count
        let unassignedCount = openIssues.filter { issue in
            return normalizedAssignee(issue) == "未分配"
        }.count
        lines.append("本期新增: \(createdCount)")
        lines.append("更新: \(updatedCount)")
        lines.append("月末未关闭: \(openCount)")
        lines.append("新增已关闭: \(resolvedCount)")
        lines.append("超过 7 天未关闭: \(staleCount)")
        lines.append("未分配负责人: \(unassignedCount)")

        lines.append("")
        lines.append("--- 分析摘要 ---")
        let net = createdCount - resolvedCount
        if net > 0 {
            lines.append("本期净增加 \(net) 个问题，积压压力上升。")
        } else if net < 0 {
            lines.append("本期净减少 \(abs(net)) 个问题，问题消化速度较好。")
        } else {
            lines.append("本期新增与关闭持平。")
        }
        if staleCount > 0 {
            lines.append("\(staleCount) 个未关闭问题已超过 7 天，建议优先复盘。")
        }
        if unassignedCount > 0 {
            lines.append("\(unassignedCount) 个未关闭问题未分配负责人。")
        }

        let byType = Dictionary(grouping: issues, by: \.type)
        if !byType.isEmpty {
            lines.append("")
            lines.append("--- 类型分布 ---")
            for type in IssueType.allCases {
                if let items = byType[type], !items.isEmpty {
                    lines.append("\(type.rawValue): \(items.count)")
                }
            }
        }

        let byStatus = Dictionary(grouping: issues, by: \.status)
        if !byStatus.isEmpty {
            lines.append("")
            lines.append("--- 状态分布 ---")
            for status in IssueStatus.allCases {
                if let items = byStatus[status], !items.isEmpty {
                    lines.append("\(status.rawValue): \(items.count)")
                }
            }
        }

        var assigneeCounts: [String: Int] = [:]
        for issue in issues {
            assigneeCounts[normalizedAssignee(issue), default: 0] += 1
        }
        let assigneeTotals = assigneeCounts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        if !assigneeTotals.isEmpty {
            lines.append("")
            lines.append("--- 负责人分布 ---")
            for (name, count) in assigneeTotals.prefix(8) {
                lines.append("\(name): \(count)")
            }
        }

        if !openIssues.isEmpty {
            lines.append("")
            lines.append("--- 未关闭问题 ---")
            for issue in openIssues {
                var meta = [issue.type.rawValue, issueTimelineText(issue)]
                if let jira = issue.jiraKey, !jira.isEmpty { meta.append(jira) }
                if let assignee = issue.assignee, !assignee.isEmpty { meta.append("负责人 \(assignee)") }
                lines.append("[\(issue.displayStatusName)] \(issue.title)（\(meta.joined(separator: " · "))）")
            }
        }

        lines.append("")
        lines.append("--- 问题明细 ---")
        if issues.isEmpty {
            lines.append("暂无问题记录")
        } else {
            for issue in issues {
                var meta = [issue.type.rawValue, issueTimelineText(issue)]
                if let dept = issue.department, !dept.isEmpty { meta.append(dept) }
                if let jira = issue.jiraKey, !jira.isEmpty { meta.append(jira) }
                if let linear = issue.linearKey, !linear.isEmpty { meta.append(linear) }
                if let assignee = issue.assignee, !assignee.isEmpty { meta.append("负责人 \(assignee)") }
                if let reporter = issue.reporterName, !reporter.isEmpty { meta.append("提交 \(reporter)") }
                if !issue.issueTags.isEmpty { meta.append("标签 \(issue.issueTags.joined(separator: ","))") }
                lines.append("[\(issue.displayStatusName)] \(issue.title)（\(meta.joined(separator: " · "))）")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func copyIssueTrackingReportToClipboard(from store: DataStore, period: Period = .currentMonth) {
        let text = generateIssueTrackingReport(from: store, period: period)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyIssueTrackingReportToClipboardAsync(from store: DataStore, period: Period = .currentMonth) async {
        let issues = store.visibleTrackedIssues
        let now = Date()
        let text = await Task.detached(priority: .userInitiated) {
            WeeklyReport.generateIssueTrackingReport(from: issues, period: period, now: now)
        }.value
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyImageToClipboard(from store: DataStore, period: Period = .currentWeek) {
        let image = ReportVisualRenderer.renderPeriodReport(store: store, period: period)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func copyImageToClipboardAsync(from store: DataStore, period: Period = .currentWeek) async -> Bool {
        guard let pngData = await ReportVisualRenderer.periodPNGData(store: store, period: period),
              let image = NSImage(data: pngData) else {
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        return true
    }

    static func copyIssueTrackingImageToClipboardAsync(from store: DataStore, period: Period = .currentMonth) async -> Bool {
        guard let pngData = await ReportVisualRenderer.issueTrackingPNGData(store: store, period: period),
              let image = NSImage(data: pngData) else {
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        return true
    }
}
