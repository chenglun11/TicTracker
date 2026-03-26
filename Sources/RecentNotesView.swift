import SwiftUI

private struct MarkdownContentView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") {
                    Text(inline(String(line.dropFirst(4))))
                        .font(.subheadline.bold())
                        .padding(.top, 4)
                } else if line.hasPrefix("## ") {
                    Text(inline(String(line.dropFirst(3))))
                        .font(.headline)
                        .padding(.top, 6)
                } else if line.hasPrefix("# ") {
                    Text(inline(String(line.dropFirst(2))))
                        .font(.title3.bold())
                        .padding(.top, 8)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else if let match = line.wholeMatch(of: /^(\d+)\.\s+(.+)$/) {
                    HStack(alignment: .top, spacing: 4) {
                        Text("\(match.1).")
                            .monospacedDigit()
                            .frame(width: 20, alignment: .trailing)
                        Text(inline(String(match.2)))
                    }
                } else if line.hasPrefix("---") || line.hasPrefix("***") {
                    Divider().padding(.vertical, 2)
                } else if line.isEmpty {
                    Spacer().frame(height: 4)
                } else {
                    Text(inline(line))
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct RecentNotesView: View {
    @Bindable var store: DataStore
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var copied = false
    @State private var expandedIssueDays: Set<String> = []
    @State private var selectedDayID: String?

    private struct DayEntry: Identifiable {
        let id: String // date key
        let date: Date
        let display: String
        let records: [String: Int]
        let total: Int
        let note: String
        let jiraCounts: [String: Int]
        let jiraTotal: Int
        let timestamps: [String: [String]]  // dept → ["HH:mm:ss", ...]
        let issues: [TrackedIssue]  // unified
    }

    private struct WeekGroup: Identifiable {
        let id: String          // e.g. "2026-W07"
        let label: String       // e.g. "2/10 — 2/16"
        let entries: [DayEntry]
        let isCurrentWeek: Bool
    }

    private static let dateFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private static let shortTimeFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d HH:mm"
        return fmt
    }()

    private static let displayFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d (EEE)"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    private static let weekLabelFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d"
        return fmt
    }()

    private var allEntries: [DayEntry] {
        // Collect all dateKeys that have any issue activity (created or commented)
        var issueActivityKeys = Set<String>()
        for issue in store.trackedIssues {
            issueActivityKeys.insert(issue.dateKey)
            for comment in issue.comments {
                issueActivityKeys.insert(DataStore.dateKey(from: comment.createdAt))
            }
        }
        let allKeys = Set(store.records.keys)
            .union(store.dailyNotes.keys)
            .union(store.jiraIssueCounts.keys)
            .union(issueActivityKeys)
            .sorted().reversed()
        return allKeys.compactMap { key in
            let records = store.records[key] ?? [:]
            let total = records.values.reduce(0, +)
            let note = store.dailyNotes[key] ?? ""
            let jiraCounts = store.jiraIssueCounts[key] ?? [:]
            let jiraTotal = jiraCounts.values.reduce(0, +)
            let issues = store.issuesActiveForKey(key)
            guard total > 0 || !note.isEmpty || jiraTotal > 0 || !issues.isEmpty else { return nil }
            guard let date = Self.dateFmt.date(from: key) else { return nil }
            let timestamps = store.tapTimestamps[key] ?? [:]
            return DayEntry(id: key, date: date, display: Self.displayFmt.string(from: date), records: records, total: total, note: note, jiraCounts: jiraCounts, jiraTotal: jiraTotal, timestamps: timestamps, issues: issues)
        }
    }

    private var filteredEntries: [DayEntry] {
        guard !searchText.isEmpty else { return allEntries }
        let query = searchText.lowercased()
        return allEntries.filter {
            $0.note.lowercased().contains(query) ||
            $0.display.contains(query) ||
            $0.records.keys.contains(where: { $0.lowercased().contains(query) }) ||
            $0.issues.contains(where: {
                $0.title.lowercased().contains(query) ||
                ($0.assignee?.lowercased().contains(query) ?? false) ||
                ($0.jiraKey?.lowercased().contains(query) ?? false) ||
                ($0.department?.lowercased().contains(query) ?? false) ||
                $0.comments.contains(where: { $0.text.lowercased().contains(query) })
            })
        }
    }

    private var weekGroups: [WeekGroup] {
        let calendar = Calendar.current
        let today = Date()
        let currentMonday = mondayOfWeek(containing: today, calendar: calendar)

        var grouped: [(monday: Date, entries: [DayEntry])] = []
        for entry in filteredEntries {
            let monday = mondayOfWeek(containing: entry.date, calendar: calendar)
            if let last = grouped.last, last.monday == monday {
                grouped[grouped.count - 1].entries.append(entry)
            } else {
                grouped.append((monday, [entry]))
            }
        }

        return grouped.map { monday, entries in
            let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
            let label = "\(Self.weekLabelFmt.string(from: monday)) — \(Self.weekLabelFmt.string(from: sunday))"
            let weekNum = calendar.component(.weekOfYear, from: monday)
            let year = calendar.component(.yearForWeekOfYear, from: monday)
            return WeekGroup(
                id: "\(year)-W\(String(format: "%02d", weekNum))",
                label: label,
                entries: entries,
                isCurrentWeek: monday == currentMonday
            )
        }
    }

    private func mondayOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % 7
        return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -daysFromMonday, to: date)!)
    }

    private var selectedEntry: DayEntry? {
        guard let id = selectedDayID else { return nil }
        return filteredEntries.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            // Left sidebar
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    Text("最近日记")
                        .font(.title3.bold())
                    Spacer()
                    if store.aiEnabled {
                        Button {
                            NSApp.setActivationPolicy(.regular)
                            openWindow(id: "ai-chat")
                            NSApp.activate(ignoringOtherApps: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                NotificationCenter.default.post(name: .generateWeeklyReport, object: nil)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                Text("AI 周报")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button {
                        WeeklyReport.copyToClipboard(from: store)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "已复制" : "复制周报")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                if allEntries.isEmpty {
                    ContentUnavailableView {
                        Label("暂无记录", systemImage: "book.closed")
                    } description: {
                        Text("开始记录你的日常工作吧")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedDayID) {
                        ForEach(weekGroups) { week in
                            Section {
                                ForEach(week.entries) { item in
                                    sidebarRow(item)
                                        .tag(item.id)
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    Text(week.label)
                                        .font(.subheadline.bold())
                                    if week.isCurrentWeek {
                                        Text("本周")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.primary.opacity(0.12), in: Capsule())
                                    }
                                    Spacer()
                                    let weekTotal = week.entries.reduce(0) { $0 + $1.total }
                                    let weekJira = week.entries.reduce(0) { $0 + $1.jiraTotal }
                                    if weekTotal > 0 {
                                        HStack(spacing: 2) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 8))
                                            Text("\(weekTotal)")
                                                .font(.caption2.bold())
                                        }
                                        .foregroundStyle(.blue.opacity(0.6))
                                    }
                                    if weekJira > 0 {
                                        HStack(spacing: 2) {
                                            Image(systemName: "ticket")
                                                .font(.system(size: 8))
                                            Text("\(weekJira)")
                                                .font(.caption2.bold())
                                        }
                                        .foregroundStyle(.orange.opacity(0.6))
                                    }
                                    let weekIssues = week.entries.reduce(0) { $0 + $1.issues.count }
                                    if weekIssues > 0 {
                                        HStack(spacing: 2) {
                                            Image(systemName: "ladybug")
                                                .font(.system(size: 8))
                                            Text("\(weekIssues)")
                                                .font(.caption2.bold())
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            .searchable(text: $searchText, prompt: "搜索记录")

            // Right detail
            if let item = selectedEntry {
                dayDetail(item)
            } else {
                ContentUnavailableView {
                    Label("选择一天查看详情", systemImage: "calendar")
                } description: {
                    Text("在左侧列表中选择日期")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedDayID == nil, let first = filteredEntries.first {
                selectedDayID = first.id
            }
        }
        .onChange(of: searchText) {
            if let id = selectedDayID, !filteredEntries.contains(where: { $0.id == id }) {
                selectedDayID = filteredEntries.first?.id
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Sidebar Row

    @ViewBuilder
    private func sidebarRow(_ item: DayEntry) -> some View {
        HStack(spacing: 6) {
            Text(item.display)
                .font(.callout)
            Spacer()
            if item.total > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "folder")
                        .font(.system(size: 8))
                    Text("\(item.total)")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.blue.opacity(0.6))
            }
            if item.jiraTotal > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "ticket")
                        .font(.system(size: 8))
                    Text("\(item.jiraTotal)")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.orange.opacity(0.6))
            }
            if !item.issues.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "ladybug")
                        .font(.system(size: 8))
                    Text("\(item.issues.count)")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Day Detail

    @ViewBuilder
    private func dayDetail(_ item: DayEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Date header
                HStack(spacing: 8) {
                    Text(item.display)
                        .font(.title2.bold())
                    Spacer()
                    if item.total > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.caption2)
                            Text("\(item.total)")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.blue.opacity(0.6))
                    }
                    if item.jiraTotal > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "ticket")
                                .font(.caption2)
                            Text("\(item.jiraTotal)")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.orange.opacity(0.6))
                    }
                    if !item.issues.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "ladybug")
                                .font(.caption2)
                            Text("\(item.issues.count)")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                // Project tags
                if item.total > 0 {
                    let sorted = store.departments.filter { item.records[$0, default: 0] > 0 }
                        + item.records.keys.filter { !store.departments.contains($0) && item.records[$0, default: 0] > 0 }.sorted()
                    FlowLayout(spacing: 6) {
                        ForEach(sorted, id: \.self) { dept in
                            let times = item.timestamps[dept] ?? []
                            HStack(spacing: 4) {
                                Text(dept)
                                Text("\(item.records[dept]!)")
                                    .fontWeight(.bold)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.08))
                            .clipShape(Capsule())
                            .help(times.isEmpty ? "" : times.map { String($0.prefix(5)) }.joined(separator: "  "))
                        }
                    }
                }

                // Jira tags
                if item.jiraTotal > 0 {
                    let issueMap = Dictionary(uniqueKeysWithValues: store.jiraIssues.map { ($0.key, $0.summary) })
                    let sortedJira = item.jiraCounts.sorted { $0.value > $1.value }
                    FlowLayout(spacing: 6) {
                        ForEach(sortedJira, id: \.key) { issueKey, count in
                            let label = issueMap[issueKey].map { "\(issueKey) \($0)" } ?? issueKey
                            HStack(spacing: 4) {
                                Text(label)
                                    .lineLimit(1)
                                Text("×\(count)")
                                    .fontWeight(.bold)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(Capsule())
                        }
                    }
                }

                // Tracked issues: all pending or just this day's activity
                let displayIssues = store.diaryShowAllPending
                    ? store.issuesVisibleForKey(item.id)
                    : item.issues
                if !displayIssues.isEmpty {
                    let grouped = Dictionary(grouping: displayIssues, by: \.type)
                    ForEach(IssueType.allCases, id: \.self) { type in
                        if let issues = grouped[type], !issues.isEmpty {
                            issueTypeSection(type: type, issues: issues, dayID: item.id)
                        }
                    }
                }

                // Note content
                if !item.note.isEmpty {
                    Divider()
                    MarkdownContentView(text: item.note)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func issueTypeSection(type: IssueType, issues: [TrackedIssue], dayID: String) -> some View {
        let sectionKey = "\(dayID)-\(type.rawValue)"
        let unresolvedCount = issues.filter { !$0.status.isResolved }.count
        let newCount = issues.filter { $0.dateKey == dayID }.count
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedIssueDays.contains(sectionKey) {
                        expandedIssueDays.remove(sectionKey)
                    } else {
                        expandedIssueDays.insert(sectionKey)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expandedIssueDays.contains(sectionKey) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: type.icon)
                        .font(.caption2)
                        .foregroundStyle(type.color.opacity(0.7))
                    Text(type.rawValue)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("\(issues.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if unresolvedCount > 0 {
                        Text("\(unresolvedCount)个待处理")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if newCount > 0 {
                        Text("+\(newCount)新增")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                }
            }
            .buttonStyle(.plain)
            if expandedIssueDays.contains(sectionKey) {
                FlowLayout(spacing: 6) {
                    ForEach(issues) { issue in
                        issueTag(issue, dayKey: dayID)
                    }
                }
            }
        }
    }

    private func issueTagLabel(_ issue: TrackedIssue) -> String {
        var parts = [issue.title]
        if let dept = issue.department, !dept.isEmpty { parts.insert(dept, at: 0) }
        if let jira = issue.jiraKey { parts.append(jira) }
        if let assignee = issue.assignee { parts.append(assignee) }
        return parts.joined(separator: " · ")
    }

    private func issueTag(_ issue: TrackedIssue, dayKey: String) -> some View {
        let isUnresolved = !issue.status.isResolved
        let isNewToday = issue.dateKey == dayKey
        let isUpdated = issue.updatedAt != nil && !isNewToday
        let typeColor = issue.type.color
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: issue.type.icon)
                    .font(.system(size: 9))
                    .foregroundStyle(typeColor.opacity(0.7))
                Image(systemName: issue.status.icon)
                    .font(.system(size: 9))
                    .fontWeight(isUnresolved ? .bold : .regular)
                if isNewToday {
                    Text("NEW")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(typeColor, in: Capsule())
                } else if isUpdated {
                    Text("UPD")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(typeColor, in: Capsule())
                }
                Text(issueTagLabel(issue))
                    .lineLimit(1)
                    .fontWeight(isUnresolved ? .semibold : .regular)
            }
            .font(.caption)
            HStack(spacing: 6) {
                Text("创建 " + Self.shortTimeFmt.string(from: issue.createdAt))
                if let upd = issue.updatedAt {
                    Text("· 更新 " + Self.shortTimeFmt.string(from: upd))
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            if let latest = issue.comments.last {
                Text(latest.text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(typeColor.opacity(isNewToday || isUpdated ? 0.12 : (isUnresolved ? 0.10 : 0.05)))
        .overlay(alignment: .leading) {
            if isNewToday || isUpdated {
                Rectangle()
                    .fill(typeColor.opacity(0.8))
                    .frame(width: 3)
            } else if isUnresolved {
                Rectangle()
                    .fill(typeColor.opacity(0.4))
                    .frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("\(issue.type.rawValue) · \(issue.status.rawValue)\(isNewToday ? " · 当日新增" : (isUpdated ? " · 有更新" : ""))")
    }

}

// Simple flow layout for tags
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (i, row) in rows.enumerated() {
            if i > 0 { y += spacing }
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
