import AppKit
import Foundation

@MainActor
enum ReportVisualRenderer {
    enum ImageFormat: Sendable, Equatable {
        case png
        case jpeg
    }

    private struct VisualMetric: Sendable {
        let title: String
        let value: String
        let detail: String
    }

    private struct VisualData: Sendable {
        let title: String
        let subtitle: String
        let comparisonSubtitle: String
        let primaryMetricTitle: String
        let primaryMetricValue: Int
        let metricCards: [VisualMetric]
        let recordsSectionTitle: String
        let recordsEmptyText: String
        let dailySectionTitle: String
        let statusSectionTitle: String
        let issueSectionTitle: String
        let records: [String: Int]
        let dailyTotals: [(label: String, count: Int)]
        let issues: [TrackedIssue]
        let note: String
        let assigneeTotals: [(String, Int)]
        let focusIssues: [TrackedIssue]
        let backlogIssues: [TrackedIssue]
    }

    static func renderDailyReport(store: DataStore) -> NSImage {
        let records = store.todayRecords
        let visibleIssues = store.issuesVisibleForKey(store.todayKey)
        let date = Date()
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "yyyy-MM-dd EEEE"
        displayFmt.locale = Locale(identifier: "zh_CN")
        let data = VisualData(
            title: store.feishuBotConfig.cardTitle.isEmpty ? "每日工单报告" : store.feishuBotConfig.cardTitle,
            subtitle: displayFmt.string(from: date),
            comparisonSubtitle: "",
            primaryMetricTitle: "支持次数",
            primaryMetricValue: records.values.reduce(0, +),
            metricCards: [],
            recordsSectionTitle: "项目支持",
            recordsEmptyText: "暂无项目支持记录",
            dailySectionTitle: "每日趋势",
            statusSectionTitle: "问题状态",
            issueSectionTitle: "问题明细",
            records: records,
            dailyTotals: [(label: "今日", count: records.values.reduce(0, +))],
            issues: visibleIssues,
            note: store.dailyNotes[store.todayKey] ?? "",
            assigneeTotals: [],
            focusIssues: [],
            backlogIssues: []
        )
        return render(data: data)
    }

    static func renderPeriodReport(store: DataStore, period: WeeklyReport.Period) -> NSImage {
        render(data: periodVisualData(store: store, period: period))
    }

    static func periodPNGData(store: DataStore, period: WeeklyReport.Period) async -> Data? {
        await periodImageData(store: store, period: period, format: .png)
    }

    static func periodJPEGData(store: DataStore, period: WeeklyReport.Period) async -> Data? {
        await periodImageData(store: store, period: period, format: .jpeg)
    }

    static func periodImageData(store: DataStore, period: WeeklyReport.Period, format: ImageFormat) async -> Data? {
        let data = periodVisualData(store: store, period: period)
        return await Task.detached(priority: .userInitiated) {
            renderImageData(data: data, format: format)
        }.value
    }

    static func issueTrackingPNGData(store: DataStore, period: WeeklyReport.Period) async -> Data? {
        await issueTrackingImageData(store: store, period: period, format: .png)
    }

    static func issueTrackingJPEGData(store: DataStore, period: WeeklyReport.Period) async -> Data? {
        await issueTrackingImageData(store: store, period: period, format: .jpeg)
    }

    static func issueTrackingImageData(store: DataStore, period: WeeklyReport.Period, format: ImageFormat) async -> Data? {
        let visibleIssues = store.visibleTrackedIssues
        return await Task.detached(priority: .userInitiated) {
            let data = issueTrackingVisualData(visibleIssues: visibleIssues, period: period)
            return renderImageData(data: data, format: format)
        }.value
    }

    private static func periodVisualData(store: DataStore, period: WeeklyReport.Period) -> VisualData {
        let calendar = Calendar.current
        let (start, end) = WeeklyReport.dateRange(for: period)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: end)!
        let keyFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM-dd"
        let shortFmt = DateFormatter()
        shortFmt.dateFormat = "M/d"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "M/d"

        var records: [String: Int] = [:]
        var dailyTotals: [(String, Int)] = []
        var notes: [String] = []
        var date = start
        while date <= end {
            let key = keyFmt.string(from: date)
            let supportCount = store.records[key]?.values.reduce(0, +) ?? 0
            let jiraCount = store.jiraIssueCounts[key]?.values.reduce(0, +) ?? 0
            dailyTotals.append((dayFmt.string(from: date), supportCount + jiraCount))
            for (name, count) in store.records[key] ?? [:] {
                records[name, default: 0] += count
            }
            if let note = store.dailyNotes[key], !note.isEmpty {
                notes.append("\(dayFmt.string(from: date)): \(note)")
            }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }

        let issues = store.visibleTrackedIssues.filter { issue in
            let keyInRange = issue.dateKey >= keyFmt.string(from: start) && issue.dateKey <= keyFmt.string(from: end)
            let createdInRange = issue.createdAt >= start && issue.createdAt < endExclusive
            let reportedInRange = issue.reportedAt.map { $0 >= start && $0 < endExclusive } ?? false
            return keyInRange || createdInRange || reportedInRange
        }

        let title = "技术支持\(period.reportName)"
        let subtitle = "\(shortFmt.string(from: start)) - \(shortFmt.string(from: end))"
        return VisualData(
            title: title,
            subtitle: subtitle,
            comparisonSubtitle: "",
            primaryMetricTitle: "支持次数",
            primaryMetricValue: records.values.reduce(0, +),
            metricCards: [],
            recordsSectionTitle: "项目支持",
            recordsEmptyText: "暂无项目支持记录",
            dailySectionTitle: "每日趋势",
            statusSectionTitle: "问题状态",
            issueSectionTitle: "问题明细",
            records: records,
            dailyTotals: dailyTotals,
            issues: issues,
            note: notes.joined(separator: "\n"),
            assigneeTotals: [],
            focusIssues: [],
            backlogIssues: []
        )
    }

    nonisolated private static func issueTrackingVisualData(visibleIssues: [TrackedIssue], period: WeeklyReport.Period) -> VisualData {
        let calendar = Calendar.current
        let (start, end) = WeeklyReport.dateRange(for: period)
        let keyFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM-dd"
        let shortFmt = DateFormatter()
        shortFmt.dateFormat = "M/d"

        func dateKey(from date: Date) -> String {
            keyFmt.string(from: date)
        }

        func primaryDate(_ issue: TrackedIssue) -> Date {
            issue.reportedAt ?? issue.createdAt
        }

        func primaryCreatedKey(_ issue: TrackedIssue) -> String {
            dateKey(from: primaryDate(issue))
        }

        func isReportUpdateComment(_ comment: IssueComment) -> Bool {
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            if text.hasPrefix("[Linear] 已导入") || text.hasPrefix("[Linear] 已通过链接导入") {
                return false
            }
            return true
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

        struct PeriodStats {
            let start: Date
            let end: Date
            let issues: [TrackedIssue]
            let openIssues: [TrackedIssue]
            let allOpenIssues: [TrackedIssue]
            let resolvedIssues: [TrackedIssue]
            let staleOpenIssues: [TrackedIssue]
            let focusIssues: [TrackedIssue]
            let dailyTotals: [(label: String, count: Int)]
            let typeTotals: [(String, Int)]
            let statusTotals: [(String, Int)]
            let assigneeTotals: [(String, Int)]
            let updatedIssueIDs: Set<UUID>
        }

        func periodStats(start: Date, end: Date) -> PeriodStats {
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: end)!
            let startKey = keyFmt.string(from: start)
            let endKey = keyFmt.string(from: end)

            let issues = visibleIssues
                .filter { issue in
                    let date = primaryDate(issue)
                    return date >= start && date < endExclusive
                }
                .sorted {
                    if $0.isEffectivelyResolved != $1.isEffectivelyResolved { return !$0.isEffectivelyResolved }
                    if $0.effectiveStatus != $1.effectiveStatus { return statusRank($0.effectiveStatus) < statusRank($1.effectiveStatus) }
                    return primaryDate($0) > primaryDate($1)
                }

            var dailyCounts: [String: Int] = [:]
            var typeCounts: [String: Int] = [:]
            var updatedIssueIDs = Set<UUID>()
            for issue in issues {
                typeCounts[issue.type.rawValue, default: 0] += 1
                dailyCounts[primaryCreatedKey(issue), default: 0] += 1
                let createdKey = primaryCreatedKey(issue)
                let resolvedKey = issue.resolvedAt.map { dateKey(from: $0) }
                for comment in issue.comments where isReportUpdateComment(comment) {
                    let key = dateKey(from: comment.createdAt)
                    guard key >= startKey && key <= endKey else { continue }
                    guard key != createdKey else { continue }
                    guard key != resolvedKey else { continue }
                    updatedIssueIDs.insert(issue.id)
                }
            }

            var dailyTotals: [(String, Int)] = []
            var date = start
            while date <= end {
                let key = keyFmt.string(from: date)
                dailyTotals.append((shortFmt.string(from: date), dailyCounts[key, default: 0]))
                date = calendar.date(byAdding: .day, value: 1, to: date)!
            }

            let openIssues = issues.filter { !$0.isEffectivelyResolved }
            let resolvedIssues = issues.filter(\.isEffectivelyResolved)
            let referenceDate = min(Date(), endExclusive)
            let staleThreshold = calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
            let allOpenBeforePeriodEnd = visibleIssues.filter { issue in
                guard !issue.isEffectivelyResolved, issue.effectiveStatus != .observing else { return false }
                return primaryDate(issue) < endExclusive
            }
            let staleOpenIssues = allOpenBeforePeriodEnd
                .filter { primaryDate($0) < staleThreshold }
                .sorted { primaryDate($0) < primaryDate($1) }
            let staleIDs = Set(staleOpenIssues.map(\.id))
            let unassignedIDs = Set(allOpenBeforePeriodEnd.filter { normalizedAssignee($0) == "未分配" }.map(\.id))
            let focusIssues = allOpenBeforePeriodEnd
                .filter { !staleIDs.contains($0.id) }
                .sorted { lhs, rhs in
                    if lhs.isEscalated != rhs.isEscalated { return lhs.isEscalated }
                    if unassignedIDs.contains(lhs.id) != unassignedIDs.contains(rhs.id) { return unassignedIDs.contains(lhs.id) }
                    if lhs.status != rhs.status { return statusRank(lhs.status) < statusRank(rhs.status) }
                    return primaryDate(lhs) < primaryDate(rhs)
                }

            let typeTotals = IssueType.allCases.compactMap { type -> (String, Int)? in
                let count = issues.filter { $0.type == type }.count
                return count > 0 ? (type.rawValue, count) : nil
            }
            let statusTotals = IssueStatus.allCases.compactMap { status -> (String, Int)? in
                let count = issues.filter { $0.effectiveStatus == status }.count
                return count > 0 ? (status.rawValue, count) : nil
            }
            var assigneeCounts: [String: Int] = [:]
            for issue in issues {
                assigneeCounts[normalizedAssignee(issue), default: 0] += 1
            }
            let assigneeTotals = assigneeCounts
                .map { ($0.key, $0.value) }
                .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }

            return PeriodStats(
                start: start,
                end: end,
                issues: issues,
                openIssues: openIssues,
                allOpenIssues: allOpenBeforePeriodEnd,
                resolvedIssues: resolvedIssues,
                staleOpenIssues: staleOpenIssues,
                focusIssues: focusIssues,
                dailyTotals: dailyTotals,
                typeTotals: typeTotals,
                statusTotals: statusTotals,
                assigneeTotals: assigneeTotals,
                updatedIssueIDs: updatedIssueIDs
            )
        }

        let previousEnd = calendar.date(byAdding: .day, value: -1, to: start)!
        let previousStart = calendar.date(from: calendar.dateComponents([.year, .month], from: previousEnd))!
        let current = periodStats(start: start, end: end)
        let previous = periodStats(start: previousStart, end: previousEnd)

        func deltaText(_ current: Int, _ previous: Int) -> String {
            let delta = current - previous
            if delta > 0 { return "+\(delta)" }
            if delta < 0 { return "\(delta)" }
            return "持平"
        }

        func deltaPP(_ current: Int, _ previous: Int) -> String {
            let delta = current - previous
            if delta > 0 { return "+\(delta)pp" }
            if delta < 0 { return "\(delta)pp" }
            return "持平"
        }

        func closureRate(_ stats: PeriodStats) -> Int {
            guard !stats.issues.isEmpty else { return 0 }
            return Int((Double(stats.resolvedIssues.count) / Double(stats.issues.count) * 100).rounded())
        }

        let currentClosureRate = closureRate(current)
        let previousClosureRate = closureRate(previous)
        let metricCards = [
            VisualMetric(title: "本期新增", value: "\(current.issues.count)", detail: "上月 \(previous.issues.count) · \(deltaText(current.issues.count, previous.issues.count))"),
            VisualMetric(title: "已关闭", value: "\(current.resolvedIssues.count)", detail: "关闭率 \(currentClosureRate)% · \(deltaPP(currentClosureRate, previousClosureRate))"),
            VisualMetric(title: "未关闭", value: "\(current.allOpenIssues.count)", detail: "上月 \(previous.allOpenIssues.count) · \(deltaText(current.allOpenIssues.count, previous.allOpenIssues.count))"),
            VisualMetric(title: "积压问题", value: "\(current.staleOpenIssues.count)", detail: "上月 \(previous.staleOpenIssues.count) · \(deltaText(current.staleOpenIssues.count, previous.staleOpenIssues.count))")
        ]

        var notes: [String] = []
        notes.append("较上月：新增 \(deltaText(current.issues.count, previous.issues.count))，已关闭 \(deltaText(current.resolvedIssues.count, previous.resolvedIssues.count))，未关闭 \(deltaText(current.allOpenIssues.count, previous.allOpenIssues.count))，积压 \(deltaText(current.staleOpenIssues.count, previous.staleOpenIssues.count))。")
        notes.append("本期新增 \(current.issues.count) 个，已关闭 \(current.resolvedIssues.count) 个，关闭率 \(currentClosureRate)%。")
        let net = current.issues.count - current.resolvedIssues.count
        if net > 0 {
            notes.append("月末未关闭 \(current.allOpenIssues.count) 个，净增加 \(net) 个，积压压力上升。")
        } else if net < 0 {
            notes.append("月末未关闭 \(current.allOpenIssues.count) 个，净减少 \(abs(net)) 个，问题消化速度较好。")
        } else {
            notes.append("新增与关闭持平，月末未关闭 \(current.allOpenIssues.count) 个。")
        }
        if let topType = current.typeTotals.max(by: { $0.1 < $1.1 }) {
            notes.append("\(topType.0) 是本期最高频类型，占 \(shareText(topType.1, total: current.issues.count))。")
        }
        if let topAssignee = current.assigneeTotals.first, topAssignee.0 != "未分配" {
            notes.append("\(topAssignee.0) 承接最多问题，共 \(topAssignee.1) 个。")
        }
        if !current.staleOpenIssues.isEmpty {
            notes.append("\(current.staleOpenIssues.count) 个未关闭问题已超过 7 天，建议优先复盘。")
        }
        let unassignedCount = current.allOpenIssues.filter { normalizedAssignee($0) == "未分配" }.count
        if unassignedCount > 0 {
            notes.append("\(unassignedCount) 个未关闭问题未分配负责人。")
        }
        if !current.updatedIssueIDs.isEmpty {
            notes.append("\(current.updatedIssueIDs.count) 个问题在本期有跟进更新。")
        }

        return VisualData(
            title: "问题追踪\(period.reportName)",
            subtitle: "\(shortFmt.string(from: start)) - \(shortFmt.string(from: end))",
            comparisonSubtitle: "对比上月 \(shortFmt.string(from: previousStart)) - \(shortFmt.string(from: previousEnd))",
            primaryMetricTitle: "本期新增",
            primaryMetricValue: current.issues.count,
            metricCards: metricCards,
            recordsSectionTitle: "类型分布",
            recordsEmptyText: "暂无类型数据",
            dailySectionTitle: "每日新增问题",
            statusSectionTitle: "状态分布",
            issueSectionTitle: "重点问题",
            records: Dictionary(uniqueKeysWithValues: current.typeTotals),
            dailyTotals: current.dailyTotals,
            issues: current.issues,
            note: notes.joined(separator: "\n"),
            assigneeTotals: current.assigneeTotals,
            focusIssues: current.focusIssues,
            backlogIssues: current.staleOpenIssues
        )
    }

    nonisolated static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    nonisolated static func jpegData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    private static func render(data: VisualData) -> NSImage {
        if let pngData = renderPNG(data: data),
           let image = NSImage(data: pngData) {
            return image
        }
        return NSImage(size: NSSize(width: 1200, height: 1100))
    }

    nonisolated private static func renderPNG(data: VisualData) -> Data? {
        renderImageData(data: data, format: .png)
    }

    nonisolated private static func renderImageData(data: VisualData, format: ImageFormat) -> Data? {
        let image = drawImage(data: data)
        switch format {
        case .png:
            return pngData(for: image)
        case .jpeg:
            return jpegData(for: image)
        }
    }

    nonisolated private static func drawImage(data: VisualData) -> NSImage {
        let width: CGFloat = 1200
        let margin: CGFloat = 64
        let contentWidth = width - margin * 2
        let maxIssueRows = data.metricCards.isEmpty ? 12 : 6
        let maxRecordRows = 12
        let issueRowHeight: CGFloat = 76
        let monthlyLayout = !data.metricCards.isEmpty
        let issueRows = monthlyLayout ? 0 : max(min(data.issues.count, maxIssueRows) + (data.issues.count > maxIssueRows ? 1 : 0), 1)
        let focusRows = monthlyLayout ? max(min(data.focusIssues.count, maxIssueRows) + (data.focusIssues.count > maxIssueRows ? 1 : 0), 1) : 0
        let backlogRows = monthlyLayout ? max(min(data.backlogIssues.count, maxIssueRows) + (data.backlogIssues.count > maxIssueRows ? 1 : 0), 1) : 0
        let assigneeRows = monthlyLayout ? max(min(data.assigneeTotals.count, 8), 1) : 0
        let projectRows = max(min(data.records.count, maxRecordRows) + (data.records.count > maxRecordRows ? 1 : 0), 1)
        let statusCount = Set(data.issues.map(\.status)).count
        let statusRowCount = max(min(statusCount, maxRecordRows) + (statusCount > maxRecordRows ? 1 : 0), 1)
        let noteHeight = data.note.isEmpty ? 0 : min(max(textHeight(data.note, width: contentWidth - 48, font: .systemFont(ofSize: 26)) + 72, 120), 300)
        let listHeight = CGFloat(projectRows * 42 + statusRowCount * 42 + assigneeRows * 42) + CGFloat(issueRows + focusRows + backlogRows) * issueRowHeight
        let height = max(1180, 980 + listHeight + noteHeight)
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()

        var y = height - margin
        drawText(data.title, x: margin, y: y, width: contentWidth, font: .boldSystemFont(ofSize: 54), color: NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.13, alpha: 1))
        y -= 58
        drawText(data.subtitle, x: margin, y: y, width: contentWidth, font: .systemFont(ofSize: 28), color: .secondaryLabelColor)
        y -= 72
        if !data.comparisonSubtitle.isEmpty {
            drawText(data.comparisonSubtitle, x: margin, y: y + 38, width: contentWidth, font: .systemFont(ofSize: 22), color: .secondaryLabelColor)
        }

        let pending = data.issues.filter { !$0.isEffectivelyResolved && $0.effectiveStatus != .observing }.count
        let resolved = data.issues.filter(\.isEffectivelyResolved).count
        let metricRows: [(String, String, String, NSColor)]
        if data.metricCards.isEmpty {
            metricRows = [
                (data.primaryMetricTitle, "\(data.primaryMetricValue)", "", NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1)),
                ("问题总数", "\(data.issues.count)", "", NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.88, alpha: 1)),
                ("待处理", "\(pending)", "", NSColor(calibratedRed: 0.90, green: 0.36, blue: 0.18, alpha: 1)),
                ("已解决", "\(resolved)", "", NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.34, alpha: 1))
            ]
        } else {
            let colors = [
                NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1),
                NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.34, alpha: 1),
                NSColor(calibratedRed: 0.90, green: 0.36, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.88, alpha: 1)
            ]
            metricRows = data.metricCards.enumerated().map { index, metric in
                (metric.title, metric.value, metric.detail, colors[min(index, colors.count - 1)])
            }
        }
        drawMetricCards(metricRows, x: margin, y: y, width: contentWidth)
        y -= 170

        y = drawSection(title: data.recordsSectionTitle, x: margin, y: y, width: contentWidth) { sectionY in
            drawBars(
                rows: data.records.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value },
                emptyText: data.recordsEmptyText,
                x: margin + 24,
                y: sectionY,
                width: contentWidth - 48,
                accent: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1),
                maxRows: maxRecordRows
            )
        }

        y = drawSection(title: data.dailySectionTitle, x: margin, y: y - 24, width: contentWidth) { sectionY in
            drawDailyTrend(data.dailyTotals, x: margin + 24, y: sectionY, width: contentWidth - 48)
        }

        var statusCounts: [IssueStatus: Int] = [:]
        for issue in data.issues {
            statusCounts[issue.effectiveStatus, default: 0] += 1
        }
        let statusRows: [(String, Int)] = statusCounts
            .map { status, count in (status.rawValue, count) }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
        y = drawSection(title: data.statusSectionTitle, x: margin, y: y - 24, width: contentWidth) { sectionY in
            drawBars(rows: statusRows, emptyText: "暂无问题记录", x: margin + 24, y: sectionY, width: contentWidth - 48, accent: NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.88, alpha: 1), maxRows: maxRecordRows)
        }

        if monthlyLayout {
            y = drawSection(title: "负责人统计", x: margin, y: y - 24, width: contentWidth) { sectionY in
                drawBars(
                    rows: data.assigneeTotals,
                    emptyText: "暂无负责人数据",
                    x: margin + 24,
                    y: sectionY,
                    width: contentWidth - 48,
                    accent: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1),
                    maxRows: 8
                )
            }
        }

        let issueRowsData = data.issues.sorted {
            if $0.isEffectivelyResolved != $1.isEffectivelyResolved { return !$0.isEffectivelyResolved }
            return $0.dateKey > $1.dateKey
        }
        if monthlyLayout {
            y = drawSection(title: data.issueSectionTitle, x: margin, y: y - 24, width: contentWidth) { sectionY in
                drawIssueRows(data.focusIssues, emptyText: "暂无重点问题", x: margin + 24, y: sectionY, width: contentWidth - 48, maxRows: maxIssueRows)
            }
            y = drawSection(title: "积压问题", x: margin, y: y - 24, width: contentWidth) { sectionY in
                drawIssueRows(data.backlogIssues, emptyText: "暂无超过 7 天未关闭的问题", x: margin + 24, y: sectionY, width: contentWidth - 48, maxRows: maxIssueRows)
            }
        } else {
            y = drawSection(title: data.issueSectionTitle, x: margin, y: y - 24, width: contentWidth) { sectionY in
                drawIssueRows(issueRowsData, x: margin + 24, y: sectionY, width: contentWidth - 48, maxRows: maxIssueRows)
            }
        }

        if !data.note.isEmpty {
            _ = drawSection(title: "记录", x: margin, y: y - 24, width: contentWidth) { sectionY in
                let rect = NSRect(x: margin + 24, y: sectionY - noteHeight + 34, width: contentWidth - 48, height: noteHeight - 48)
                drawWrappedText(data.note, rect: rect, font: .systemFont(ofSize: 26), color: .labelColor)
                return noteHeight
            }
        }

        image.unlockFocus()
        return image
    }

    nonisolated private static func drawMetricCards(_ cards: [(String, String, String, NSColor)], x: CGFloat, y: CGFloat, width: CGFloat) {
        let gap: CGFloat = 18
        let cardWidth = (width - gap * CGFloat(cards.count - 1)) / CGFloat(cards.count)
        for (index, card) in cards.enumerated() {
            let rect = NSRect(x: x + CGFloat(index) * (cardWidth + gap), y: y - 128, width: cardWidth, height: 128)
            rounded(rect, radius: 18, color: .white)
            card.3.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 8, height: rect.height), xRadius: 4, yRadius: 4).fill()
            drawText(card.0, x: rect.minX + 28, y: rect.maxY - 38, width: cardWidth - 56, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            drawText(card.1, x: rect.minX + 28, y: rect.maxY - 88, width: cardWidth - 56, font: .boldSystemFont(ofSize: 40), color: card.3)
            if !card.2.isEmpty {
                drawText(card.2, x: rect.minX + 28, y: rect.maxY - 116, width: cardWidth - 56, font: .systemFont(ofSize: 18), color: .secondaryLabelColor)
            }
        }
    }

    nonisolated private static func drawSection(title: String, x: CGFloat, y: CGFloat, width: CGFloat, draw: (CGFloat) -> CGFloat) -> CGFloat {
        drawText(title, x: x, y: y, width: width, font: .boldSystemFont(ofSize: 32), color: .labelColor)
        let contentStart = y - 56
        let contentHeight = draw(contentStart)
        return contentStart - contentHeight
    }

    nonisolated private static func drawBars(rows: [(String, Int)], emptyText: String, x: CGFloat, y: CGFloat, width: CGFloat, accent: NSColor, maxRows: Int = 12) -> CGFloat {
        guard !rows.isEmpty else {
            drawText(emptyText, x: x, y: y, width: width, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            return 48
        }
        let visibleRows = Array(rows.prefix(maxRows))
        let maxValue = max(visibleRows.map(\.1).max() ?? 1, 1)
        var cursor = y
        for row in visibleRows {
            drawText(row.0, x: x, y: cursor, width: 260, font: .systemFont(ofSize: 24), color: .labelColor)
            drawText("\(row.1)", x: x + width - 80, y: cursor, width: 80, font: .boldSystemFont(ofSize: 24), color: .labelColor, alignment: .right)
            let barX = x + 290
            let barWidth = max(8, (width - 400) * CGFloat(row.1) / CGFloat(maxValue))
            rounded(NSRect(x: barX, y: cursor - 20, width: width - 400, height: 14), radius: 7, color: NSColor(calibratedWhite: 0.88, alpha: 1))
            rounded(NSRect(x: barX, y: cursor - 20, width: barWidth, height: 14), radius: 7, color: accent)
            cursor -= 42
        }
        if rows.count > visibleRows.count {
            drawText("其余 \(rows.count - visibleRows.count) 项已省略", x: x, y: cursor, width: width, font: .systemFont(ofSize: 20), color: .secondaryLabelColor)
            cursor -= 36
        }
        return y - cursor
    }

    nonisolated private static func drawDailyTrend(_ rows: [(label: String, count: Int)], x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        guard !rows.isEmpty else {
            drawText("暂无趋势数据", x: x, y: y, width: width, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            return 64
        }
        let chartHeight: CGFloat = 180
        let maxValue = max(rows.map(\.count).max() ?? 1, 1)
        let gap: CGFloat = 10
        let barWidth = max(18, (width - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count))
        let baseY = y - chartHeight
        for (index, row) in rows.enumerated() {
            let h = max(6, (chartHeight - 48) * CGFloat(row.count) / CGFloat(maxValue))
            let barX = x + CGFloat(index) * (barWidth + gap)
            rounded(NSRect(x: barX, y: baseY + 34, width: barWidth, height: h), radius: 6, color: NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.34, alpha: 1))
            drawText(row.label, x: barX - 8, y: baseY + 18, width: barWidth + 16, font: .systemFont(ofSize: 18), color: .secondaryLabelColor, alignment: .center)
            drawText("\(row.count)", x: barX - 8, y: baseY + 52 + h, width: barWidth + 16, font: .boldSystemFont(ofSize: 18), color: .labelColor, alignment: .center)
        }
        return chartHeight
    }

    nonisolated private static func drawIssueRows(_ issues: [TrackedIssue], emptyText: String = "暂无问题记录", x: CGFloat, y: CGFloat, width: CGFloat, maxRows: Int = 12) -> CGFloat {
        guard !issues.isEmpty else {
            drawText(emptyText, x: x, y: y, width: width, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            return 48
        }
        let visibleIssues = Array(issues.prefix(maxRows))
        var cursor = y
        for issue in visibleIssues {
            let statusColor = issue.isEffectivelyResolved ? NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.34, alpha: 1) : NSColor(calibratedRed: 0.90, green: 0.36, blue: 0.18, alpha: 1)
            rounded(NSRect(x: x, y: cursor - 50, width: 110, height: 32), radius: 8, color: statusColor.withAlphaComponent(0.12))
            drawText(issue.displayStatusName, x: x + 10, y: cursor - 26, width: 90, font: .boldSystemFont(ofSize: 18), color: statusColor, alignment: .center)
            let meta = [issue.linearKey, issue.jiraKey, issue.assignee, issue.department].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            drawText(issue.title, x: x + 130, y: cursor - 4, width: width - 130, font: .systemFont(ofSize: 24), color: .labelColor)
            drawText(issueTimelineText(issue), x: x + 130, y: cursor - 32, width: width - 130, font: .systemFont(ofSize: 18), color: .secondaryLabelColor)
            drawText(meta.isEmpty ? issue.type.rawValue : "\(issue.type.rawValue) · \(meta)", x: x + 130, y: cursor - 56, width: width - 130, font: .systemFont(ofSize: 17), color: .secondaryLabelColor)
            cursor -= 76
        }
        if issues.count > visibleIssues.count {
            drawText("其余 \(issues.count - visibleIssues.count) 条已省略，详情请查看报告正文", x: x + 130, y: cursor - 4, width: width - 130, font: .systemFont(ofSize: 20), color: .secondaryLabelColor)
            cursor -= 42
        }
        return y - cursor
    }

    nonisolated private static func statusRank(_ status: IssueStatus) -> Int {
        switch status {
        case .pending: return 0
        case .inProgress: return 1
        case .testing: return 2
        case .scheduled: return 3
        case .observing: return 4
        case .fixed: return 5
        case .ignored: return 6
        }
    }

    nonisolated private static func shareText(_ count: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(count) / Double(total) * 100).rounded()))%"
    }

    nonisolated private static func issueTimelineText(_ issue: TrackedIssue) -> String {
        "创建 \(issueDateTimeText(issue.createdAt)) · 更新 \(issueDateTimeText(issueLatestActivityDate(issue)))"
    }

    nonisolated private static func issueDateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    nonisolated private static func issueLatestActivityDate(_ issue: TrackedIssue) -> Date {
        var dates = [issue.createdAt]
        if let reportedAt = issue.reportedAt { dates.append(reportedAt) }
        if let updatedAt = issue.updatedAt { dates.append(updatedAt) }
        if let resolvedAt = issue.resolvedAt { dates.append(resolvedAt) }
        dates.append(contentsOf: issue.comments.map(\.createdAt))
        return dates.max() ?? issue.updatedAt ?? issue.createdAt
    }

    nonisolated private static func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    nonisolated private static func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: NSRect(x: x, y: y - font.pointSize - 6, width: width, height: font.pointSize + 12), withAttributes: attrs)
    }

    nonisolated private static func drawWrappedText(_ text: String, rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    nonisolated private static func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        return ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs).height)
    }
}
