import SwiftUI

struct MenuBarView: View {
    @Bindable var store: DataStore
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false
    @State private var noteText = ""
    @State private var selectedDate = Date()

    private var selectedKey: String {
        DataStore.dateKey(from: selectedDate)
    }

    private var isToday: Bool {
        selectedKey == store.todayKey
    }

    private var displayDate: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d (EEE)"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: selectedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date navigation
            HStack {
                Button { shiftDate(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(store.popoverTitle)
                    .font(.headline)

                Text("· \(displayDate)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button { shiftDate(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(isToday)
            }

            if !isToday {
                Button("回到今天") {
                    selectedDate = Date()
                    noteText = store.noteForKey(store.todayKey)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }

            if store.departments.isEmpty {
                Text("暂无项目，请在设置中添加")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.departments, id: \.self) { dept in
                    HStack {
                        Text(dept)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(store.recordsForKey(selectedKey)[dept, default: 0])")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                        Button { store.decrementForKey(selectedKey, dept: dept) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.recordsForKey(selectedKey)[dept, default: 0] == 0)
                        Button { store.incrementForKey(selectedKey, dept: dept) } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            // Mini weekly trend chart
            if store.past7DaysTotals.contains(where: { $0.total > 0 }) {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("本周趋势")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.currentStreak > 0 {
                            Text("🔥 连续 \(store.currentStreak) 天")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    MiniChartView(data: store.past7DaysTotals, todayKey: store.todayKey)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(store.noteTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $noteText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if noteText.isEmpty {
                            Text("记录今天做了什么…")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .onChange(of: noteText) { _, newValue in
                        store.setNoteForKey(selectedKey, text: newValue)
                    }
            }

            Divider()

            HStack {
                Button(copied ? "已复制 ✓" : "复制本周汇总") {
                    WeeklyReport.copyToClipboard(from: store)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
                Spacer()
                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "recent-notes")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .help("查看日报")
                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("设置")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("退出")
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear { noteText = store.noteForKey(selectedKey) }
    }

    private func shiftDate(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            // Don't go past today
            selectedDate = min(d, Date())
            noteText = store.noteForKey(selectedKey)
        }
    }
}

private struct MiniChartView: View {
    let data: [(date: String, weekday: String, total: Int)]
    let todayKey: String

    var body: some View {
        let maxVal = max(data.map(\.total).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(data, id: \.date) { item in
                VStack(spacing: 2) {
                    if item.total > 0 {
                        Text("\(item.total)")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.date == todayKey ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(height: max(CGFloat(item.total) / CGFloat(maxVal) * 30, item.total > 0 ? 4 : 1))
                    Text(item.weekday)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 50)
    }
}
