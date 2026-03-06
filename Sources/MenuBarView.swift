import SwiftUI

struct MenuBarView: View {
    @Bindable var store: DataStore
    @Environment(\.openWindow) private var openWindow
    @State private var noteText = ""
    @State private var selectedDate = Date()
    @State private var trendExpanded = true
    @State private var jiraRefreshing = false
    @State private var animatingDept: String?

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

            Button("回到今天") {
                selectedDate = Date()
                noteText = store.noteForKey(store.todayKey)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .opacity(isToday ? 0 : 1)
            .disabled(isToday)

            if store.departments.isEmpty {
                Text("暂无项目，请在设置中添加")
                    .foregroundStyle(.secondary)
            } else {
                let dayRecords = store.recordsForKey(selectedKey)
                ForEach(store.departments, id: \.self) { dept in
                    HStack {
                        Text(dept)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let count = dayRecords[dept, default: 0]
                        Text("\(count)")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                        Button { store.decrementForKey(selectedKey, dept: dept) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(count == 0)
                        Button {
                            store.incrementForKey(selectedKey, dept: dept)
                            DevLog.shared.info("Click", "\(dept) +1")
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .scaleEffect(animatingDept == dept ? 1.3 : 1.0)
                                .foregroundStyle(animatingDept == dept ? Color.green : Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: animatingDept)
                    }
                }
            }

            // Jira section
            if store.jiraConfig.showInMenuBar {
                Divider()
                jiraSection
            }

            // Mini weekly trend chart
            if store.trendChartEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button {
                            withAnimation { trendExpanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: trendExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .frame(width: 10)
                                Text("本周趋势")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        if store.currentStreak > 0 {
                            Text("🔥 连续 \(store.currentStreak) 天")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if trendExpanded {
                        MiniChartView(data: store.past7DaysBreakdown, departments: store.departments, todayKey: store.todayKey)
                    }
                }
            }

            Divider()

            if store.dailyNoteEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.noteTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $noteText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .frame(height: 80)
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
            }

            // Todo tasks section
            if store.todoEnabled {
                let tasks = store.tasksForKey(selectedKey).filter { !$0.isCompleted }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "checklist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(isToday ? "今日待办" : "当日待办")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !tasks.isEmpty {
                            Text("\(tasks.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            NSApp.setActivationPolicy(.regular)
                            openWindow(id: "todo")
                            NSApp.activate(ignoringOtherApps: true)
                        } label: {
                            Text("打开")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.blue)
                    }

                    if tasks.isEmpty {
                        Text("暂无待办任务")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(tasks.prefix(3)) { task in
                            CompactTaskRow(task: task, dateKey: selectedKey, store: store)
                        }

                        if tasks.count > 3 {
                            Text("还有 \(tasks.count - 3) 个任务…")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)

                Divider()
            }

            HStack {
                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "statistics")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.borderless)
                .help("统计")

                Spacer()

                if store.rssEnabled {
                    Button {
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "rss-reader")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "dot.radiowaves.up.forward")
                    }
                    .buttonStyle(.borderless)
                    .help("RSS 订阅")

                    Spacer()
                }

                if store.jiraConfig.showInMenuBar {
                    Button {
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "jira")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "server.rack")
                    }
                    .buttonStyle(.borderless)
                    .help("Jira 工单")

                    Spacer()
                }

                if store.dailyNoteEnabled {
                    Button {
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "recent-notes")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help("查看日记")

                    Spacer()
                }

                if store.aiEnabled {
                    Button {
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "ai-chat")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderless)
                    .help("AI 对话")

                    Spacer()
                }

                if store.todoEnabled {
                    Button {
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "todo")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .buttonStyle(.borderless)
                    .help("待办任务")

                    Spacer()
                }

                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "dev-log")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(.borderless)
                .help("开发者日志")

                Spacer()

                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("设置")

                Spacer()

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
        .onAppear {
            selectedDate = Date()
            noteText = store.noteForKey(selectedKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyTriggered)) { notification in
            guard let dept = notification.object as? String else { return }
            animatingDept = dept
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                animatingDept = nil
            }
        }
    }

    // MARK: - Jira Section

    @ViewBuilder
    private var jiraSection: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "server.rack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Jira")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if store.jiraConfig.enabled {
                    Text("\(store.jiraIssues.count) 个工单")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if store.jiraConfig.enabled {
                Button {
                    jiraRefreshing = true
                    Task {
                        _ = await JiraService.shared.fetchMyIssues()
                        jiraRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(jiraRefreshing)
            }

            Button {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "jira")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("打开")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
        }
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
                            .foregroundStyle(.secondary)
                    }
                    stackedBar(date: item.date, breakdown: item.breakdown, total: total, maxVal: maxVal)
                    Text(item.weekday)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
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
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            if total > 0 {
                Divider()
                HStack {
                    Text("合计").font(.caption.bold())
                    Spacer()
                    Text("\(total)").font(.caption.bold()).monospacedDigit()
                }
            }
        }
        .padding(8)
        .frame(width: 150)
    }
}

// MARK: - Compact Task Row

struct CompactTaskRow: View {
    let task: TodoTask
    let dateKey: String
    @Bindable var store: DataStore

    private var isOverdue: Bool {
        guard let dueDate = task.dueDate else { return false }
        return dueDate < Date()
    }

    private var priorityColor: Color {
        switch task.priority {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d"
        return fmt
    }()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                toggleCompletion()
            } label: {
                Image(systemName: "circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Circle()
                .fill(priorityColor)
                .frame(width: 4, height: 4)

            Text(task.title)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            if let dueDate = task.dueDate {
                Text(formatDueDate(dueDate))
                    .font(.caption2)
                    .foregroundStyle(isOverdue ? .red : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func toggleCompletion() {
        var updatedTask = task
        updatedTask.isCompleted = true
        updatedTask.completedAt = Date()

        if let notificationID = updatedTask.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
        }

        store.updateTask(updatedTask, forKey: dateKey)
    }

    private func formatDueDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        } else {
            return Self.dateFormatter.string(from: date)
        }
    }
}
