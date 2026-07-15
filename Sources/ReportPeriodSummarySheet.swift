import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReportPeriodSummaryView: View {
    let store: DataStore
    @State private var period: WeeklyReport.Period = .currentMonth
    @State private var isCopyingReport = false
    @State private var isRenderingImage = false
    @State private var isSendingFeishu = false
    @State private var actionMessage: String?
    @State private var actionSuccess = true
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

        func primaryDate(_ issue: TrackedIssue) -> Date {
            issue.reportedAt ?? issue.createdAt
        }

        func primaryDateKey(_ issue: TrackedIssue) -> String {
            keyFmt.string(from: primaryDate(issue))
        }

        let issues = store.visibleTrackedIssues
            .filter { issue in
                let date = primaryDate(issue)
                return date >= start && date < endExclusive
            }
            .sorted {
                if $0.isEffectivelyResolved != $1.isEffectivelyResolved { return !$0.isEffectivelyResolved }
                if $0.effectiveStatus != $1.effectiveStatus { return Self.statusRank($0.effectiveStatus) < Self.statusRank($1.effectiveStatus) }
                return primaryDate($0) > primaryDate($1)
            }

        var days: [DayIssueSummary] = []
        var date = start
        while date <= end {
            let key = keyFmt.string(from: date)
            let created = issues.filter {
                primaryDateKey($0) == key
            }
            let resolved = issues.filter {
                $0.resolvedAt.map { DataStore.dateKey(from: $0) == key } == true
            }
            let updated = issues.filter {
                let updatedIssue = $0
                guard !created.contains(where: { $0.id == updatedIssue.id }) else { return false }
                guard !resolved.contains(where: { $0.id == updatedIssue.id }) else { return false }
                return Self.hasReportUpdateActivity(updatedIssue, on: key)
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
        let updatedIssueIDs = Set(days.flatMap { $0.updated.map(\.id) })

        let statusTotals = IssueStatus.allCases.compactMap { status -> (IssueStatus, Int)? in
            let count = issues.filter { $0.effectiveStatus == status }.count
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
        let openIssues = store.visibleTrackedIssues
            .filter { issue in
                guard !issue.isEffectivelyResolved, issue.effectiveStatus != .observing else { return false }
                return primaryDate(issue) < endExclusive
            }
            .sorted {
                if $0.isEscalated != $1.isEscalated { return $0.isEscalated }
                if $0.effectiveStatus != $1.effectiveStatus { return Self.statusRank($0.effectiveStatus) < Self.statusRank($1.effectiveStatus) }
                return primaryDate($0) < primaryDate($1)
            }
        let resolvedIssues = issues.filter { $0.isEffectivelyResolved }
        let referenceDate = min(Date(), endExclusive)
        let staleThreshold = calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
        let staleOpenIssues = openIssues
            .filter { primaryDate($0) < staleThreshold }
            .sorted { primaryDate($0) < primaryDate($1) }
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
            createdTotal: issues.count,
            updatedTotal: updatedIssueIDs.count,
            resolvedTotal: resolvedIssues.count,
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
                    chartSection
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
                copyIssueReport()
            } label: {
                Label(isCopyingReport ? "生成中..." : "复制问题报告", systemImage: isCopyingReport ? "hourglass" : "doc.on.doc")
            }
            .disabled(isCopyingReport)
            Button {
                copyIssueReportImage()
            } label: {
                Label(isRenderingImage ? "生成中..." : "复制图片", systemImage: isRenderingImage ? "hourglass" : "photo")
            }
            .disabled(isRenderingImage)
            Button {
                exportIssueReportJPG()
            } label: {
                Label("导出 JPG", systemImage: "square.and.arrow.down")
            }
            .disabled(isRenderingImage)
            Button {
                sendIssueReportToFeishu()
            } label: {
                Label(isSendingFeishu ? "推送中..." : "推送飞书", systemImage: isSendingFeishu ? "hourglass" : "paperplane.fill")
            }
            .disabled(isSendingFeishu)
            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(actionSuccess ? .green : .red)
                    .lineLimit(1)
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

    private func copyIssueReport() {
        guard !isCopyingReport else { return }
        isCopyingReport = true
        let selectedPeriod = period
        Task {
            await WeeklyReport.copyIssueTrackingReportToClipboardAsync(from: store, period: selectedPeriod)
            isCopyingReport = false
            actionMessage = "问题报告已复制"
            actionSuccess = true
        }
    }

    private func copyIssueReportImage() {
        guard !isRenderingImage else { return }
        isRenderingImage = true
        let selectedPeriod = period
        Task {
            let ok = await WeeklyReport.copyIssueTrackingImageToClipboardAsync(from: store, period: selectedPeriod)
            isRenderingImage = false
            actionMessage = ok ? "图片已复制" : "图片生成失败"
            actionSuccess = ok
        }
    }

    private func exportIssueReportJPG() {
        guard !isRenderingImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "问题追踪\(period.reportName).jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isRenderingImage = true
        let selectedPeriod = period
        Task {
            if let data = await ReportVisualRenderer.issueTrackingJPEGData(store: store, period: selectedPeriod) {
                do {
                    try data.write(to: url)
                    actionMessage = "JPG 已导出"
                    actionSuccess = true
                } catch {
                    actionMessage = "导出失败：\(error.localizedDescription)"
                    actionSuccess = false
                }
            } else {
                actionMessage = "图片生成失败"
                actionSuccess = false
            }
            isRenderingImage = false
        }
    }

    private func sendIssueReportToFeishu() {
        guard !isSendingFeishu else { return }
        isSendingFeishu = true
        actionMessage = nil
        let selectedPeriod = period
        Task {
            let result = await FeishuBotService.shared.sendIssueTrackingReportNow(store: store, period: selectedPeriod)
            actionMessage = result.message
            actionSuccess = result.success
            isSendingFeishu = false
        }
    }

    private var issueMetrics: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                metricTile("本期新增", value: "\(data.createdTotal)", icon: "tray.full", color: .purple)
                metricTile("月末未关闭", value: "\(data.openIssues.count)", icon: "circle", color: .orange)
                metricTile("新增已关闭", value: "\(data.resolvedIssues.count)", icon: "checkmark.circle.fill", color: .green)
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
                    analysisTile("积压", value: "\(data.staleOpenIssues.count)", detail: "提交/创建超过 7 天且未关闭", color: .red)
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
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    distributionChart(
                        title: "状态分布",
                        rows: data.statusTotals.map { ($0.0.rawValue, $0.1, $0.0.isResolved ? Color.green : Color.orange) },
                        emptyText: "暂无状态数据"
                    )
                    distributionChart(
                        title: "类型分布",
                        rows: data.typeTotals.map { ($0.0.rawValue, $0.1, $0.0.color) },
                        emptyText: "暂无类型数据"
                    )
                }
                GridRow {
                    distributionChart(
                        title: "负责人 Top 8",
                        rows: data.assigneeTotals.prefix(8).map { ($0.0, $0.1, Color.blue) },
                        emptyText: "暂无负责人数据"
                    )
                    distributionChart(
                        title: "来源分布",
                        rows: data.sourceTotals.map { ($0.0, $0.1, Color.purple) },
                        emptyText: "暂无来源数据"
                    )
                }
            }
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

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("统计图表", systemImage: "chart.bar.xaxis")
                .font(.headline)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    dailyActivityChart
                    closureChart
                }
            }
        }
    }

    private var dailyActivityChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("每日活动趋势")
                    .font(.callout.bold())
                Spacer()
                chartLegend("新增", color: .blue)
                chartLegend("更新", color: .orange)
                chartLegend("关闭", color: .green)
            }

            let days = Array(data.days.reversed())
            if days.isEmpty {
                Text("暂无趋势数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                GeometryReader { proxy in
                    let maxValue = max(days.map { max($0.created.count, $0.updated.count, $0.resolved.count) }.max() ?? 1, 1)
                    let contentWidth = max(proxy.size.width, CGFloat(days.count) * 28)
                    let columnWidth = contentWidth / CGFloat(max(days.count, 1))
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: 0) {
                            ForEach(Array(days.enumerated()), id: \.element.id) { _, day in
                                VStack(spacing: 6) {
                                    HStack(alignment: .bottom, spacing: 3) {
                                        activityBar(count: day.created.count, maxValue: maxValue, color: .blue)
                                        activityBar(count: day.updated.count, maxValue: maxValue, color: .orange)
                                        activityBar(count: day.resolved.count, maxValue: maxValue, color: .green)
                                    }
                                    .frame(height: 118, alignment: .bottom)
                                    Text(day.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: columnWidth)
                            }
                        }
                        .frame(width: contentWidth)
                    }
                }
                .frame(height: 158)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var closureChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("关闭与积压")
                    .font(.callout.bold())
                Spacer()
                Text(closureRateText)
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }

            let periodOpenCount = max(data.createdTotal - data.resolvedTotal, 0)
            let total = max(data.createdTotal, 1)
            VStack(alignment: .leading, spacing: 10) {
                stackedProgress(
                    rows: [
                        ("新增已关闭", data.resolvedTotal, Color.green),
                        ("新增未关闭", periodOpenCount, Color.orange)
                    ],
                    total: total
                )
                distributionChartBody(
                    rows: [
                        ("新增", data.createdTotal, Color.blue),
                        ("关闭", data.resolvedTotal, Color.green),
                        ("月末未关闭", data.openIssues.count, Color.orange),
                        ("积压", data.staleOpenIssues.count, Color.red),
                        ("未分配", data.unassignedOpenIssues.count, Color.secondary)
                    ],
                    emptyText: "暂无分析数据"
                )
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func distributionChart(title: String, rows: [(String, Int, Color)], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.bold())
            distributionChartBody(rows: rows, emptyText: emptyText)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func distributionChartBody(rows: [(String, Int, Color)], emptyText: String) -> some View {
        let filtered = rows.filter { $0.1 > 0 }
        let maxValue = max(filtered.map(\.1).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            if filtered.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            } else {
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.0)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(width: 82, alignment: .leading)
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(row.2.opacity(0.16))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(row.2)
                                .frame(width: max(8, proxy.size.width * CGFloat(row.1) / CGFloat(maxValue)))
                        }
                        .frame(height: 8)
                        Text("\(row.1)")
                            .font(.caption.bold())
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
        }
        .frame(minHeight: 90, alignment: .top)
    }

    private func activityBar(count: Int, maxValue: Int, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(count > 0 ? color : Color.secondary.opacity(0.12))
            .frame(width: 7, height: max(5, 112 * CGFloat(count) / CGFloat(max(maxValue, 1))))
            .help("\(count)")
    }

    private func chartLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func stackedProgress(rows: [(String, Int, Color)], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(row.2)
                            .frame(width: max(row.1 == 0 ? 0 : 8, proxy.size.width * CGFloat(row.1) / CGFloat(max(total, 1))))
                    }
                }
            }
            .frame(height: 12)
            HStack(spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    chartLegend("\(row.0) \(row.1)", color: row.2)
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
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            let blocked = data.openIssues.filter { $0.effectiveStatus == .pending || $0.effectiveStatus == .inProgress }
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
                Label(issue.displayStatusName, systemImage: issue.displayStatusIcon)
                    .font(.caption.bold())
                    .foregroundStyle(issue.isEffectivelyResolved ? .green : .orange)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
        var chips = [
            "创建 \(issueDateTimeText(issue.createdAt))",
            "更新 \(issueDateTimeText(issueLatestActivityDate(issue)))"
        ]
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

    private func issueDateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func issueLatestActivityDate(_ issue: TrackedIssue) -> Date {
        var dates = [issue.createdAt]
        if let reportedAt = issue.reportedAt { dates.append(reportedAt) }
        if let updatedAt = issue.updatedAt { dates.append(updatedAt) }
        if let resolvedAt = issue.resolvedAt { dates.append(resolvedAt) }
        dates.append(contentsOf: issue.comments.map(\.createdAt))
        return dates.max() ?? issue.updatedAt ?? issue.createdAt
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

    private static func hasReportUpdateActivity(_ issue: TrackedIssue, on dateKey: String) -> Bool {
        issue.comments.contains { comment in
            isReportUpdateComment(comment) && DataStore.dateKey(from: comment.createdAt) == dateKey
        }
    }

    private static func isReportUpdateComment(_ comment: IssueComment) -> Bool {
        let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.hasPrefix("[Linear] 已导入") || text.hasPrefix("[Linear] 已通过链接导入") {
            return false
        }
        return true
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
