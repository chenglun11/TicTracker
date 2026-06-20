import SwiftUI

struct ReportPeriodSummaryView: View {
    let store: DataStore
    @State private var period: WeeklyReport.Period = .currentMonth
    @Environment(\.dismiss) private var dismiss

    private struct DayIssueSummary: Identifiable {
        let id: String
        let label: String
        let created: [TrackedIssue]
        let updated: [TrackedIssue]
        let resolved: [TrackedIssue]

        var total: Int { created.count + updated.count + resolved.count }
    }

    private struct SummaryData {
        let title: String
        let subtitle: String
        let issues: [TrackedIssue]
        let openIssues: [TrackedIssue]
        let resolvedIssues: [TrackedIssue]
        let statusTotals: [(IssueStatus, Int)]
        let typeTotals: [(IssueType, Int)]
        let assigneeTotals: [(String, Int)]
        let sourceTotals: [(String, Int)]
        let days: [DayIssueSummary]
        let createdTotal: Int
        let updatedTotal: Int
        let resolvedTotal: Int
        let staleOpenIssues: [TrackedIssue]
        let unassignedOpenIssues: [TrackedIssue]
    }

    private var data: SummaryData {
        let calendar = Calendar.current
        let (start, end) = WeeklyReport.dateRange(for: period)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: end)!
        let keyFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM-dd"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "M/d"
        let startKey = keyFmt.string(from: start)
        let endKey = keyFmt.string(from: end)

        let issues = store.visibleTrackedIssues
            .filter { issue in
                let keyInRange = issue.dateKey >= startKey && issue.dateKey <= endKey
                let createdInRange = issue.createdAt >= start && issue.createdAt < endExclusive
                let reportedInRange = issue.reportedAt.map { $0 >= start && $0 < endExclusive } ?? false
                let updatedInRange = issue.updatedAt.map { $0 >= start && $0 < endExclusive } ?? false
                let resolvedInRange = issue.resolvedAt.map { $0 >= start && $0 < endExclusive } ?? false
                return keyInRange || createdInRange || reportedInRange || updatedInRange || resolvedInRange
            }
            .sorted {
                if $0.status.isResolved != $1.status.isResolved { return !$0.status.isResolved }
                if $0.status != $1.status { return Self.statusRank($0.status) < Self.statusRank($1.status) }
                return $0.dateKey > $1.dateKey
            }

        var days: [DayIssueSummary] = []
        var date = start
        while date <= end {
            let key = keyFmt.string(from: date)
            let created = issues.filter {
                $0.dateKey == key ||
                DataStore.dateKey(from: $0.createdAt) == key ||
                $0.reportedAt.map { DataStore.dateKey(from: $0) == key } == true
            }
            let updated = issues.filter {
                guard $0.updatedAt.map({ DataStore.dateKey(from: $0) == key }) == true else { return false }
                let updatedIssue = $0
                return !created.contains(where: { $0.id == updatedIssue.id })
            }
            let resolved = issues.filter {
                $0.resolvedAt.map { DataStore.dateKey(from: $0) == key } == true
            }
            let summary = DayIssueSummary(
                id: key,
                label: dayFmt.string(from: date),
                created: created,
                updated: updated,
                resolved: resolved
            )
            if summary.total > 0 { days.append(summary) }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }

        let statusTotals = IssueStatus.allCases.compactMap { status -> (IssueStatus, Int)? in
            let count = issues.filter { $0.status == status }.count
            return count > 0 ? (status, count) : nil
        }
        let typeTotals = IssueType.allCases.compactMap { type -> (IssueType, Int)? in
            let count = issues.filter { $0.type == type }.count
            return count > 0 ? (type, count) : nil
        }
        var assigneeCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        for issue in issues {
            assigneeCounts[Self.normalizedAssignee(issue), default: 0] += 1
            sourceCounts[issue.source.rawValue, default: 0] += 1
        }
        let assigneePairs: [(String, Int)] = assigneeCounts.map { key, value in
            (key, value)
        }
        let assigneeTotals = assigneePairs.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }
        let sourcePairs: [(String, Int)] = sourceCounts.map { key, value in
            (key, value)
        }
        let sourceTotals = sourcePairs.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }
        let openIssues = issues.filter { !$0.status.isResolved }
        let resolvedIssues = issues.filter { $0.status.isResolved }
        let referenceDate = min(Date(), endExclusive)
        let staleThreshold = calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
        let staleOpenIssues = openIssues
            .filter { $0.createdAt < staleThreshold && $0.status != .observing }
            .sorted { $0.createdAt < $1.createdAt }
        let unassignedOpenIssues = openIssues.filter {
            Self.normalizedAssignee($0) == "未分配"
        }

        return SummaryData(
            title: "问题追踪\(period.reportName)",
            subtitle: "\(dayFmt.string(from: start)) - \(dayFmt.string(from: end))",
            issues: issues,
            openIssues: openIssues,
            resolvedIssues: resolvedIssues,
            statusTotals: statusTotals,
            typeTotals: typeTotals,
            assigneeTotals: assigneeTotals,
            sourceTotals: sourceTotals,
            days: Array(days.reversed()),
            createdTotal: days.reduce(0) { $0 + $1.created.count },
            updatedTotal: days.reduce(0) { $0 + $1.updated.count },
            resolvedTotal: days.reduce(0) { $0 + $1.resolved.count },
            staleOpenIssues: staleOpenIssues,
            unassignedOpenIssues: unassignedOpenIssues
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    issueMetrics
                    analysisSection
                    distributionSection
                    focusSection
                    dayActivitySection
                    issueListSection(title: "未关闭问题", issues: data.openIssues)
                    issueListSection(title: "已关闭问题", issues: data.resolvedIssues)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 660, idealHeight: 760)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(data.title)
                    .font(.title3.bold())
                Text(data.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $period) {
                Text("本月").tag(WeeklyReport.Period.currentMonth)
                Text("上月").tag(WeeklyReport.Period.previousMonth)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 132)
            Button {
                WeeklyReport.copyIssueTrackingReportToClipboard(from: store, period: period)
            } label: {
                Label("复制问题报告", systemImage: "doc.on.doc")
            }
            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.bordered)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var issueMetrics: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                metricTile("问题总数", value: "\(data.issues.count)", icon: "tray.full", color: .purple)
                metricTile("未关闭", value: "\(data.openIssues.count)", icon: "circle", color: .orange)
                metricTile("已关闭", value: "\(data.resolvedIssues.count)", icon: "checkmark.circle.fill", color: .green)
                metricTile("关闭率", value: closureRateText, icon: "chart.line.uptrend.xyaxis", color: .blue)
            }
        }
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("数据分析", systemImage: "waveform.path.ecg")
                .font(.headline)

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    analysisTile("新增", value: "\(data.createdTotal)", detail: deltaDetail, color: .blue)
                    analysisTile("更新", value: "\(data.updatedTotal)", detail: "非新增日的状态或字段变动", color: .orange)
                    analysisTile("关闭", value: "\(data.resolvedTotal)", detail: closeDetail, color: .green)
                }
                GridRow {
                    analysisTile("积压", value: "\(data.staleOpenIssues.count)", detail: "创建超过 7 天且未关闭", color: .red)
                    analysisTile("未分配", value: "\(data.unassignedOpenIssues.count)", detail: "未关闭问题中缺少负责人", color: .secondary)
                    analysisTile("活跃日", value: busiestDayText, detail: "新增/更新/关闭合计最多", color: .purple)
                }
            }

            if !analysisNotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(analysisNotes, id: \.self) { note in
                        Label(note, systemImage: "smallcircle.filled.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func analysisTile(_ title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundStyle(color)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metricTile(_ title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.bold())
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("分布", systemImage: "square.grid.2x2")
                .font(.headline)
            ReportSummaryFlowLayout(spacing: 6) {
                ForEach(data.statusTotals, id: \.0) { status, count in
                    chip("\(status.rawValue) \(count)", icon: status.icon, color: status.isResolved ? .green : .orange)
                }
                ForEach(data.typeTotals, id: \.0) { type, count in
                    chip("\(type.rawValue) \(count)", icon: type.icon, color: type.color)
                }
                ForEach(data.assigneeTotals.prefix(8), id: \.0) { assignee, count in
                    chip("\(assignee) \(count)", icon: "person", color: .secondary)
                }
                ForEach(data.sourceTotals, id: \.0) { source, count in
                    chip("\(source) \(count)", icon: "link", color: .blue)
                }
            }
        }
    }

    private var dayActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("每日问题活动", systemImage: "calendar")
                .font(.headline)
            if data.days.isEmpty {
                Text("暂无问题活动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(data.days) { day in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(day.label)
                                    .font(.caption.bold())
                                    .frame(width: 48, alignment: .leading)
                                activityBadge("新增", count: day.created.count, color: .blue)
                                activityBadge("更新", count: day.updated.count, color: .orange)
                                activityBadge("关闭", count: day.resolved.count, color: .green)
                            }
                            dayIssueLine(title: "新增", issues: day.created)
                            dayIssueLine(title: "更新", issues: day.updated)
                            dayIssueLine(title: "关闭", issues: day.resolved)
                        }
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("重点关注", systemImage: "exclamationmark.triangle")
                .font(.headline)
            let escalated = data.openIssues.filter(\.isEscalated)
            let blocked = data.openIssues.filter { $0.status == .pending || $0.status == .inProgress }
            if data.staleOpenIssues.isEmpty && data.unassignedOpenIssues.isEmpty && escalated.isEmpty && blocked.isEmpty {
                Text("暂无需要优先处理的问题")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    focusGroup("超过 7 天未关闭", issues: data.staleOpenIssues, color: .red)
                    focusGroup("未分配负责人", issues: data.unassignedOpenIssues, color: .secondary)
                    focusGroup("已升级", issues: escalated, color: .purple)
                    focusGroup("处理中/待处理", issues: blocked, color: .orange)
                }
            }
        }
    }

    private func focusGroup(_ title: String, issues: [TrackedIssue], color: Color) -> some View {
        Group {
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(color)
                            .frame(width: 6, height: 6)
                        Text("\(title) \(issues.count)")
                            .font(.caption.bold())
                            .foregroundStyle(color)
                    }
                    ForEach(issues.prefix(5)) { issue in
                        Text(issue.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func dayIssueLine(title: String, issues: [TrackedIssue]) -> some View {
        Group {
            if !issues.isEmpty {
                Text("\(title)：\(issues.prefix(4).map(\.title).joined(separator: "；"))\(issues.count > 4 ? " 等 \(issues.count) 个" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func activityBadge(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text("\(count)").monospacedDigit()
        }
        .font(.caption2.bold())
        .foregroundStyle(count > 0 ? color : .secondary)
    }

    private func issueListSection(title: String, issues: [TrackedIssue]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: title.contains("未") ? "tray.full" : "checkmark.circle")
                .font(.headline)
            if issues.isEmpty {
                Text("暂无\(title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(issues) { issue in
                        issueRow(issue)
                    }
                }
            }
        }
    }

    private func issueRow(_ issue: TrackedIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label(issue.status.rawValue, systemImage: issue.status.icon)
                    .font(.caption.bold())
                    .foregroundStyle(issue.status.isResolved ? .green : .orange)
                Label(issue.type.rawValue, systemImage: issue.type.icon)
                    .font(.caption2)
                    .foregroundStyle(issue.type.color)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title)
                    .font(.callout.bold())
                    .lineLimit(2)
                ReportSummaryFlowLayout(spacing: 5) {
                    ForEach(issueChips(issue), id: \.self) { value in
                        Text(value)
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.08), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func chip(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
            .foregroundStyle(color)
    }

    private func issueChips(_ issue: TrackedIssue) -> [String] {
        var chips = [issue.dateKey]
        if let dept = issue.department, !dept.isEmpty { chips.append(dept) }
        if let jira = issue.jiraKey, !jira.isEmpty { chips.append(jira) }
        if let linear = issue.linearKey, !linear.isEmpty { chips.append(linear) }
        if let assignee = issue.assignee, !assignee.isEmpty { chips.append("负责人 \(assignee)") }
        if let reporter = issue.reporterName, !reporter.isEmpty { chips.append("提交 \(reporter)") }
        if issue.source != .manual { chips.append(issue.source.rawValue) }
        chips.append(contentsOf: issue.issueTags)
        return chips
    }

    private var closureRateText: String {
        guard data.createdTotal > 0 else { return data.resolvedTotal > 0 ? "100%" : "0%" }
        return "\(Int((Double(data.resolvedTotal) / Double(data.createdTotal) * 100).rounded()))%"
    }

    private var deltaDetail: String {
        let delta = data.createdTotal - data.resolvedTotal
        if delta > 0 { return "净增加 \(delta) 个，积压压力上升" }
        if delta < 0 { return "净减少 \(abs(delta)) 个，消化速度较好" }
        return "新增与关闭持平"
    }

    private var closeDetail: String {
        if data.resolvedTotal >= data.createdTotal && data.createdTotal > 0 {
            return "关闭量覆盖本期新增"
        }
        if data.resolvedTotal == 0 {
            return "本期暂无关闭记录"
        }
        return "仍有新增未被覆盖"
    }

    private var busiestDayText: String {
        guard let day = data.days.max(by: { $0.total < $1.total }) else { return "-" }
        return "\(day.label) · \(day.total)"
    }

    private var analysisNotes: [String] {
        var notes: [String] = []
        if let topType = data.typeTotals.max(by: { $0.1 < $1.1 }) {
            notes.append("\(topType.0.rawValue) 是本期最高频类型，占 \(shareText(topType.1, total: data.issues.count))。")
        }
        if let topAssignee = data.assigneeTotals.first, topAssignee.0 != "未分配" {
            notes.append("\(topAssignee.0) 承接最多问题，共 \(topAssignee.1) 个。")
        }
        if data.staleOpenIssues.count > 0 {
            notes.append("\(data.staleOpenIssues.count) 个未关闭问题已超过 7 天，建议优先复盘。")
        }
        if data.unassignedOpenIssues.count > 0 {
            notes.append("\(data.unassignedOpenIssues.count) 个未关闭问题未分配负责人。")
        }
        return notes
    }

    private func shareText(_ count: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(count) / Double(total) * 100).rounded()))%"
    }

    private static func statusRank(_ status: IssueStatus) -> Int {
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

    private static func normalizedAssignee(_ issue: TrackedIssue) -> String {
        if let assignee = issue.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
            return assignee
        }
        if let assignee = issue.linearAssignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
            return assignee
        }
        return "未分配"
    }
}

private struct ReportSummaryFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (index > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (index, row) in rows.enumerated() {
            if index > 0 { y += spacing }
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(view)
            x += size.width + spacing
        }
        return rows
    }
}
