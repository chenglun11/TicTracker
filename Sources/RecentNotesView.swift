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
    @State private var searchText = ""
    @State private var copied = false
    @State private var aiGenerating = false
    @State private var aiResult: String?
    @State private var aiError: String?

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
        let allKeys = Set(store.records.keys)
            .union(store.dailyNotes.keys)
            .union(store.jiraIssueCounts.keys)
            .sorted().reversed()
        return allKeys.compactMap { key in
            let records = store.records[key] ?? [:]
            let total = records.values.reduce(0, +)
            let note = store.dailyNotes[key] ?? ""
            let jiraCounts = store.jiraIssueCounts[key] ?? [:]
            let jiraTotal = jiraCounts.values.reduce(0, +)
            guard total > 0 || !note.isEmpty || jiraTotal > 0 else { return nil }
            guard let date = Self.dateFmt.date(from: key) else { return nil }
            let timestamps = store.tapTimestamps[key] ?? [:]
            return DayEntry(id: key, date: date, display: Self.displayFmt.string(from: date), records: records, total: total, note: note, jiraCounts: jiraCounts, jiraTotal: jiraTotal, timestamps: timestamps)
        }
    }

    private var filteredEntries: [DayEntry] {
        guard !searchText.isEmpty else { return allEntries }
        let query = searchText.lowercased()
        return allEntries.filter {
            $0.note.lowercased().contains(query) ||
            $0.display.contains(query) ||
            $0.records.keys.contains(where: { $0.lowercased().contains(query) })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Text("最近日记")
                    .font(.title3.bold())
                Spacer()
                if store.aiEnabled {
                    Button {
                        generateAIReport()
                    } label: {
                        HStack(spacing: 4) {
                            if aiGenerating {
                                ProgressView()
                                    .controlSize(.small)
                                Text("生成中…")
                                    .font(.caption)
                            } else {
                                Image(systemName: "sparkles")
                                Text("AI 周报")
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(aiGenerating)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if allEntries.isEmpty {
                ContentUnavailableView {
                    Label("暂无记录", systemImage: "book.closed")
                } description: {
                    Text("开始记录你的日常工作吧")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(weekGroups) { week in
                        Section {
                            ForEach(week.entries) { item in
                                dayRow(item)
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Text(week.label)
                                    .font(.headline)
                                if week.isCurrentWeek {
                                    Text("本周")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                                Spacer()
                                let weekTotal = week.entries.reduce(0) { $0 + $1.total }
                                let weekJira = week.entries.reduce(0) { $0 + $1.jiraTotal }
                                if weekTotal > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "folder.fill")
                                            .font(.caption2)
                                        Text("\(weekTotal)")
                                            .font(.caption.bold())
                                    }
                                    .foregroundStyle(.blue)
                                }
                                if weekJira > 0 {
                                    HStack(spacing: 4) {
                                        Image(systemName: "ticket.fill")
                                            .font(.caption2)
                                        Text("\(weekJira)")
                                            .font(.caption.bold())
                                    }
                                    .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $searchText, prompt: "搜索记录")
        .sheet(isPresented: Binding(
            get: { aiResult != nil || aiError != nil },
            set: { if !$0 { aiResult = nil; aiError = nil } }
        )) {
            aiResultSheet
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private func dayRow(_ item: DayEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Date header
            HStack(spacing: 8) {
                Text(item.display)
                    .font(.subheadline.bold())
                Spacer()
                if item.total > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.caption2)
                        Text("\(item.total)")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.blue)
                }
                if item.jiraTotal > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "ticket.fill")
                            .font(.caption2)
                        Text("\(item.jiraTotal)")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.orange)
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
                        .background(Color.accentColor.opacity(0.15))
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
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                    }
                }
            }

            // Note content
            if !item.note.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    MarkdownContentView(text: item.note)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    // MARK: - AI Report

    @ViewBuilder
    private var aiResultSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 周报")
                    .font(.headline)
                Spacer()
                if aiResult != nil {
                    Button("复制") {
                        copyAIResult(aiResult!)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button("关闭") {
                    aiResult = nil
                    aiError = nil
                }
                .controlSize(.small)
            }

            Divider()

            if let error = aiError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            } else if let result = aiResult {
                ScrollView {
                    MarkdownContentView(text: result)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .frame(minWidth: 500, maxWidth: 500, minHeight: 300, maxHeight: 600)
    }

    private func generateAIReport() {
        aiGenerating = true
        aiResult = nil
        aiError = nil
        let rawReport = WeeklyReport.generate(from: store)
        let config = store.aiConfig
        Task {
            do {
                let result = try await AIService.shared.generateWeeklyReport(
                    rawReport: rawReport, config: config
                )
                aiResult = result
            } catch {
                aiError = error.localizedDescription
            }
            aiGenerating = false
        }
    }

    private func copyAIResult(_ markdown: String) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // 1. 纯文本（Markdown 原文）
        pb.setString(markdown, forType: .string)

        // 2. 转换为 AttributedString，用于生成富文本格式
        guard let attributed = try? AttributedString(markdown: markdown) else { return }
        let nsAttr = NSAttributedString(attributed)
        let range = NSRange(location: 0, length: nsAttr.length)

        // 3. RTF 富文本
        if let rtfData = try? nsAttr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pb.setData(rtfData, forType: .rtf)
        }

        // 4. HTML（兼容更多应用）
        if let htmlData = try? nsAttr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) {
            pb.setData(htmlData, forType: .html)
        }
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
