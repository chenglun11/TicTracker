import SwiftUI
import Combine

let departmentColors: [Color] = [.blue, .purple, .orange, .green, .pink, .yellow, .red, .gray, Color(red: 0, green: 0.8, blue: 0.8)]

// MARK: - NoteTextView (NSViewRepresentable)

struct NoteTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @ObservedObject var store: DataStore
    @State private var noteText = ""
    @State private var selectedDate = Date()
    @State private var trendExpanded = true
    @State private var weeklyReportLoading = false
    @State private var weeklyReportResult: String?

    private var selectedKey: String {
        DataStore.dateKey(from: selectedDate)
    }

    private var isToday: Bool {
        selectedKey == store.todayKey
    }

    private static let displayDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d (EEE)"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    private var displayDate: String {
        Self.displayDateFormatter.string(from: selectedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date navigation
            HStack {
                Button(action: { shiftDate(-1) }) {
                    Text("◀")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(store.popoverTitle)
                    .font(.headline)

                Text("· \(displayDate)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { shiftDate(1) }) {
                    Text("▶")
                }
                .buttonStyle(.borderless)
                .disabled(isToday)
            }

            Button("回到今天") {
                selectedDate = Date()
                noteText = store.noteForKey(store.todayKey)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundColor(Color.accentColor)
            .opacity(isToday ? 0 : 1)
            .disabled(isToday)

            // Department counters
            if store.departments.isEmpty {
                Text("暂无项目，请在设置中添加")
                    .foregroundColor(.secondary)
            } else {
                let dayRecords = store.recordsForKey(selectedKey)
                ForEach(store.departments, id: \.self) { dept in
                    HStack {
                        Text(dept)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let count = dayRecords[dept, default: 0]
                        Text("\(count)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 30, alignment: .trailing)
                        Button(action: { store.decrementForKey(selectedKey, dept: dept) }) {
                            Text("−")
                        }
                        .buttonStyle(.borderless)
                        .disabled(count == 0)
                        Button(action: { store.incrementForKey(selectedKey, dept: dept) }) {
                            Text("+")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            // Mini weekly trend chart
            if store.trendChartEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button(action: {
                            withAnimation { trendExpanded.toggle() }
                        }) {
                            HStack(spacing: 4) {
                                Text(trendExpanded ? "▼" : "▶")
                                    .font(.system(size: 10))
                                    .frame(width: 10)
                                Text("本周趋势")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        if store.currentStreak > 0 {
                            Text("连续 \(store.currentStreak) 天")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    if trendExpanded {
                        MiniChartView(data: store.past7DaysBreakdown, departments: store.departments, todayKey: store.todayKey)
                    }
                }
            }

            Divider()

            // Daily notes
            if store.dailyNoteEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.noteTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    ZStack(alignment: .topLeading) {
                        NoteTextView(text: $noteText)
                            .frame(height: 80)
                        if noteText.isEmpty {
                            Text("记录今天做了什么…")
                                .font(.body)
                                .foregroundColor(Color.secondary.opacity(0.5))
                                .padding(.leading, 8)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .onReceive(Just(noteText)) { newValue in
                        store.setNoteForKey(selectedKey, text: newValue)
                    }
                }

                Divider()
            }

            // Weekly report result
            if let result = weeklyReportResult {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("AI 周报")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("关闭") {
                            weeklyReportResult = nil
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                    Text(result)
                        .font(.caption)
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
            }

            // Bottom toolbar
            HStack {
                Button(action: {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }) {
                    Text("⚙")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: {
                    generateWeeklyReport()
                }) {
                    if weeklyReportLoading {
                        Text("生成中…")
                            .font(.caption)
                    } else {
                        Text("周报")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(weeklyReportLoading)

                Spacer()

                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Text("✕")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            selectedDate = Date()
            noteText = store.noteForKey(selectedKey)
        }
    }

    // MARK: - Helpers

    private func shiftDate(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = min(d, Date())
            noteText = store.noteForKey(selectedKey)
        }
    }

    private func generateWeeklyReport() {
        let rawReport = WeeklyReport.generate(from: store)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawReport, forType: .string)

        if store.aiEnabled {
            weeklyReportLoading = true
            let config = store.aiConfig
            Task { @MainActor in
                do {
                    let aiReport = try await AIService.shared.generateWeeklyReport(rawReport: rawReport, config: config)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(aiReport, forType: .string)
                    weeklyReportResult = aiReport
                } catch {
                    weeklyReportResult = "AI 生成失败: \(error.localizedDescription)"
                }
                weeklyReportLoading = false
            }
        }
    }
}

// MARK: - MiniChartView

private struct MiniChartView: View {
    let data: [(date: String, weekday: String, breakdown: [(dept: String, count: Int)])]
    let departments: [String]
    let todayKey: String
    @State private var selectedDay: String?

    var body: some View {
        let maxVal = max(data.map { $0.breakdown.reduce(0) { $0 + $1.count } }.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(data, id: \.date) { item in
                let total = item.breakdown.reduce(0) { $0 + $1.count }
                VStack(spacing: 2) {
                    if total > 0 {
                        Text("\(total)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    stackedBar(date: item.date, breakdown: item.breakdown, total: total, maxVal: maxVal)
                    Text(item.weekday)
                        .font(.system(size: 9))
                        .foregroundColor(Color.secondary.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedDay = selectedDay == item.date ? nil : item.date
                }
                .popover(isPresented: Binding(
                    get: { selectedDay == item.date },
                    set: { if !$0 { selectedDay = nil } }
                )) {
                    dayDetail(date: item.date, weekday: item.weekday, breakdown: item.breakdown, total: total)
                }
            }
        }
        .frame(height: 50)
    }

    @ViewBuilder
    private func stackedBar(date: String, breakdown: [(dept: String, count: Int)], total: Int, maxVal: Int) -> some View {
        let barHeight = max(CGFloat(total) / CGFloat(maxVal) * 30, total > 0 ? 4 : 1)
        let isToday = date == todayKey
        if breakdown.isEmpty {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(breakdown.reversed().enumerated()), id: \.offset) { _, segment in
                    let segmentHeight = CGFloat(segment.count) / CGFloat(total) * barHeight
                    let colorIndex = departments.firstIndex(of: segment.dept) ?? 0
                    Rectangle()
                        .fill(departmentColors[colorIndex % departmentColors.count].opacity(isToday ? 1.0 : 0.55))
                        .frame(height: segmentHeight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .frame(height: barHeight)
        }
    }

    private func dayDetail(date: String, weekday: String, breakdown: [(dept: String, count: Int)], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(date) \(weekday)")
                .font(.caption.bold())
            Divider()
            ForEach(breakdown, id: \.dept) { segment in
                HStack {
                    let colorIndex = departments.firstIndex(of: segment.dept) ?? 0
                    Circle()
                        .fill(departmentColors[colorIndex % departmentColors.count])
                        .frame(width: 6, height: 6)
                    Text(segment.dept)
                        .font(.caption)
                    Spacer()
                    Text("\(segment.count)")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            if total > 0 {
                Divider()
                HStack {
                    Text("合计").font(.caption.bold())
                    Spacer()
                    Text("\(total)").font(.system(.caption, design: .monospaced)).bold()
                }
            }
        }
        .padding(8)
        .frame(width: 150)
    }
}
