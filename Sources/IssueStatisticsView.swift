import SwiftUI
import Charts

/// 月度问题提交统计视图：按月聚合 TrackedIssue 的提交量，按类型（Bug / Feature / Support）拆分。
struct IssueStatisticsView: View {
    @Bindable var store: DataStore

    enum RangePreset: String, CaseIterable, Identifiable {
        case last6 = "近 6 个月"
        case last12 = "近 12 个月"
        case all = "全部"
        var id: String { rawValue }

        /// 需要保留的最近月份数量；nil 表示不限制。
        var monthLimit: Int? {
            switch self {
            case .last6: return 6
            case .last12: return 12
            case .all: return nil
            }
        }
    }

    @State private var range: RangePreset = .last12

    // MARK: - 数据聚合

    private struct MonthPoint: Identifiable {
        let id: String          // "2025-06"
        var counts: [IssueType: Int] = [:]
        var total: Int { counts.values.reduce(0, +) }
    }

    private struct ChartEntry: Identifiable {
        let id = UUID()
        let month: String
        let type: IssueType
        let count: Int
    }

    private static let monthFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        return fmt
    }()

    /// 取问题的"提交所属月份"，优先使用 dateKey（yyyy-MM-dd），否则回退到 createdAt。
    private func monthKey(for issue: TrackedIssue) -> String {
        if issue.dateKey.count >= 7 {
            return String(issue.dateKey.prefix(7))
        }
        return Self.monthFmt.string(from: issue.createdAt)
    }

    /// 按月聚合后的桶，已按时间升序并应用范围过滤。
    private var buckets: [MonthPoint] {
        var map: [String: MonthPoint] = [:]
        for issue in store.visibleTrackedIssues {
            let key = monthKey(for: issue)
            var point = map[key] ?? MonthPoint(id: key)
            point.counts[issue.type, default: 0] += 1
            map[key] = point
        }
        let sorted = map.values.sorted { $0.id < $1.id }
        if let limit = range.monthLimit, sorted.count > limit {
            return Array(sorted.suffix(limit))
        }
        return sorted
    }

    private var chartEntries: [ChartEntry] {
        buckets.flatMap { bucket in
            IssueType.allCases.compactMap { type -> ChartEntry? in
                let count = bucket.counts[type, default: 0]
                return count > 0 ? ChartEntry(month: bucket.id, type: type, count: count) : nil
            }
        }
    }

    private var grandTotal: Int { buckets.reduce(0) { $0 + $1.total } }

    private var thisMonthTotal: Int {
        let key = Self.monthFmt.string(from: Date())
        return buckets.first { $0.id == key }?.total ?? 0
    }

    private func typeTotal(_ type: IssueType) -> Int {
        buckets.reduce(0) { $0 + $1.counts[type, default: 0] }
    }

    /// "2025-06" → "25/06"，使 x 轴更紧凑。
    private func shortLabel(_ month: String) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2 else { return month }
        return "\(parts[0].suffix(2))/\(parts[1])"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if buckets.isEmpty {
                ContentUnavailableView {
                    Label("无数据", systemImage: "ladybug")
                } description: {
                    Text("还没有任何问题提交记录")
                }
                .frame(maxHeight: .infinity)
            } else {
                chart
                breakdownList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                statCard(title: "总提交", value: "\(grandTotal)", subtitle: "个问题", color: .blue)
                statCard(title: IssueType.bug.rawValue, value: "\(typeTotal(.bug))", subtitle: "Bug", color: IssueType.bug.color)
                statCard(title: IssueType.hotfix.rawValue, value: "\(typeTotal(.hotfix))", subtitle: "需求", color: IssueType.hotfix.color)
                statCard(title: IssueType.issue.rawValue, value: "\(typeTotal(.issue))", subtitle: "支持", color: IssueType.issue.color)
                statCard(title: "本月", value: "\(thisMonthTotal)", subtitle: "个", color: .green)
            }
            .padding(.horizontal)

            HStack(spacing: 8) {
                ForEach(RangePreset.allCases) { preset in
                    Button(preset.rawValue) { range = preset }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            range == preset ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(range == preset ? .white : .primary)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Chart

    private var chart: some View {
        Chart(chartEntries) { entry in
            BarMark(
                x: .value("月份", shortLabel(entry.month)),
                y: .value("数量", entry.count)
            )
            .foregroundStyle(by: .value("类型", entry.type.rawValue))
            .cornerRadius(3)
        }
        .chartForegroundStyleScale(
            domain: IssueType.allCases.map(\.rawValue),
            range: IssueType.allCases.map(\.color)
        )
        .chartYAxis { AxisMarks(position: .leading) }
        .chartLegend(position: .top, alignment: .leading)
        .frame(height: 220)
        .padding(.horizontal)
        .padding(.top, 12)
    }

    // MARK: - Breakdown list

    private var breakdownList: some View {
        List(buckets.reversed()) { bucket in
            HStack(spacing: 12) {
                Text(bucket.id)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 80, alignment: .leading)
                ForEach(IssueType.allCases, id: \.self) { type in
                    let count = bucket.counts[type, default: 0]
                    if count > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: type.icon)
                                .font(.caption2)
                                .foregroundStyle(type.color)
                            Text("\(count)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                }
                Spacer()
                Text("\(bucket.total)")
                    .font(.body.bold())
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func statCard(title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
