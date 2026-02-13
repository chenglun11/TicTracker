import SwiftUI

private struct NoteContentView: View {
    let text: String
    let inlineMarkdown: (String) -> AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                        Text(inlineMarkdown(String(line.dropFirst(2))))
                    }
                } else if line.isEmpty {
                    Spacer().frame(height: 4)
                } else {
                    Text(inlineMarkdown(line))
                }
            }
        }
    }
}

struct RecentNotesView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""

    private struct DayEntry: Identifiable {
        let id: String // date key
        let display: String
        let records: [String: Int]
        let total: Int
        let note: String
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

    private var allEntries: [DayEntry] {
        let allKeys = Set(store.records.keys).union(store.dailyNotes.keys).sorted().reversed()
        return allKeys.compactMap { key in
            let records = store.records[key] ?? [:]
            let total = records.values.reduce(0, +)
            let note = store.dailyNotes[key] ?? ""
            guard total > 0 || !note.isEmpty else { return nil }
            guard let date = Self.dateFmt.date(from: key) else { return nil }
            return DayEntry(id: key, display: Self.displayFmt.string(from: date), records: records, total: total, note: note)
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

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if allEntries.isEmpty {
                Text("暂无记录")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.display)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if item.total > 0 {
                                Text("共 \(item.total) 次")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if item.total > 0 {
                            let sorted = store.departments.filter { item.records[$0, default: 0] > 0 }
                                + item.records.keys.filter { !store.departments.contains($0) && item.records[$0, default: 0] > 0 }.sorted()
                            FlowLayout(spacing: 6) {
                                ForEach(sorted, id: \.self) { dept in
                                    Text("\(dept) \(item.records[dept]!)")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                        }

                        if !item.note.isEmpty {
                            NoteContentView(text: item.note, inlineMarkdown: inlineMarkdown)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索记录")
        .navigationTitle("最近日报")
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
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
