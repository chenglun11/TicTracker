//
//  TodoView.swift
//  TicTracker
//
//  Created on 2026-03-04.
//

import SwiftUI

enum TaskFilter: String, CaseIterable {
    case all = "全部"
    case active = "进行中"
    case completed = "已完成"
}

struct TodoView: View {
    @Bindable var store: DataStore
    @State private var selectedDate = Date()
    @State private var filter: TaskFilter = .all
    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var editingTask: TodoTask?
    @State private var hoveredTaskID: UUID?

    private var selectedKey: String {
        DataStore.dateKey(from: selectedDate)
    }

    private var allTasks: [TodoTask] {
        let tasksForDate = store.tasksForKey(selectedKey)
        let tasksWithDeadline = store.todoTasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            return Calendar.current.isDate(dueDate, inSameDayAs: selectedDate) && task.dateKey != selectedKey
        }
        return tasksForDate + tasksWithDeadline
    }

    private var filteredTasks: [TodoTask] {
        var tasks = allTasks

        switch filter {
        case .all: break
        case .active: tasks = tasks.filter { !$0.isCompleted }
        case .completed: tasks = tasks.filter { $0.isCompleted }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            tasks = tasks.filter {
                $0.title.lowercased().contains(query) ||
                $0.description.lowercased().contains(query)
            }
        }

        return tasks.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted {
                return !lhs.isCompleted
            }
            if lhs.priority.sortOrder != rhs.priority.sortOrder {
                return lhs.priority.sortOrder > rhs.priority.sortOrder
            }
            if let lhsDue = lhs.dueDate, let rhsDue = rhs.dueDate {
                return lhsDue < rhsDue
            }
            if lhs.dueDate != nil { return true }
            if rhs.dueDate != nil { return false }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var activeCount: Int {
        allTasks.filter { !$0.isCompleted }.count
    }

    private var completedCount: Int {
        allTasks.filter { $0.isCompleted }.count
    }

    private var totalCount: Int {
        allTasks.count
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private static let headerDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 EEEE"
        return fmt
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            contentSection
            footerSection
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingAddSheet) {
            TaskEditSheet(store: store, dateKey: selectedKey, task: nil) {
                showingAddSheet = false
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditSheet(store: store, dateKey: selectedKey, task: task) {
                editingTask = nil
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                // Date nav
                HStack(spacing: 6) {
                    Button {
                        selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.headerDateFormatter.string(from: selectedDate))
                            .font(.system(size: 14, weight: .semibold))
                        if isToday {
                            Text("今天")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                    }

                    Button {
                        selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    if !isToday {
                        Button {
                            selectedDate = Date()
                        } label: {
                            Text("回到今天")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Stats
                if totalCount > 0 {
                    HStack(spacing: 4) {
                        Text("\(completedCount)/\(totalCount)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)

                        ProgressView(value: Double(completedCount), total: Double(totalCount))
                            .progressViewStyle(.linear)
                            .frame(width: 36)
                            .tint(completedCount == totalCount ? .green : .accentColor)
                    }
                }
            }

            // Filter + Search
            HStack(spacing: 8) {
                HStack(spacing: 1) {
                    ForEach(TaskFilter.allCases, id: \.self) { f in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { filter = f }
                        } label: {
                            Text(f.rawValue)
                                .font(.system(size: 11, weight: filter == f ? .semibold : .regular))
                                .foregroundStyle(filter == f ? .white : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    filter == f
                                        ? Capsule().fill(Color.accentColor)
                                        : Capsule().fill(Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(Capsule())

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("搜索", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    private var contentSection: some View {
        Group {
            if filteredTasks.isEmpty {
                emptyStateView
            } else {
                taskListView
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.quaternary)

            VStack(spacing: 4) {
                Text(searchText.isEmpty ? "暂无任务" : "无匹配结果")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(searchText.isEmpty ? "点击下方添加第一个任务" : "尝试其他关键词")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
    }

    private var taskListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredTasks) { task in
                    TaskRow(
                        task: task,
                        dateKey: selectedKey,
                        store: store,
                        isHovered: hoveredTaskID == task.id,
                        onEdit: { editingTask = task }
                    )
                    .onHover { hoveredTaskID = $0 ? task.id : nil }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                showingAddSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                    Text("添加任务")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - TaskRow

struct TaskRow: View {
    let task: TodoTask
    let dateKey: String
    @Bindable var store: DataStore
    var isHovered: Bool = false
    let onEdit: () -> Void

    private var isOverdue: Bool {
        guard let dueDate = task.dueDate, !task.isCompleted else { return false }
        return dueDate < Date()
    }

    private var priorityColor: Color {
        switch task.priority {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private static let dueDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox
            Button {
                toggleCompletion()
            } label: {
                ZStack {
                    if task.isCompleted {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 18, height: 18)
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Circle()
                            .strokeBorder(priorityColor.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)

            // Priority indicator
            RoundedRectangle(cornerRadius: 1)
                .fill(task.isCompleted ? Color.clear : priorityColor)
                .frame(width: 2.5, height: 24)
                .opacity(task.isCompleted ? 0 : 1)

            // Content (tap to edit)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .tertiary : .primary)
                    .lineLimit(1)

                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }

            Spacer(minLength: 4)

            // Due time badge
            if let dueDate = task.dueDate {
                HStack(spacing: 2) {
                    if isOverdue {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                    }
                    Text(Self.dueDateFormatter.string(from: dueDate))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(isOverdue ? .red : .secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOverdue ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                )
            }

            // Hover edit
            if isHovered {
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(task.isCompleted ? "标记为未完成" : "标记为完成") { toggleCompletion() }
            Button("编辑") { onEdit() }
            Divider()
            Button("删除", role: .destructive) { deleteTask() }
        }
    }

    private func toggleCompletion() {
        var updatedTask = task
        updatedTask.isCompleted.toggle()
        updatedTask.completedAt = updatedTask.isCompleted ? Date() : nil

        if updatedTask.isCompleted, let notificationID = updatedTask.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
        }

        if !updatedTask.isCompleted, let dueDate = updatedTask.dueDate, dueDate > Date() {
            let notificationID = updatedTask.notificationID ?? "task-\(updatedTask.id.uuidString)"
            updatedTask.notificationID = notificationID
            NotificationManager.shared.scheduleTaskNotification(task: updatedTask, dateKey: dateKey)
        }

        store.updateTask(updatedTask, forKey: dateKey)
    }

    private func deleteTask() {
        if let notificationID = task.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
        }
        store.deleteTask(id: task.id, forKey: dateKey)
    }
}

// MARK: - TaskEditSheet

struct TaskEditSheet: View {
    @Bindable var store: DataStore
    let dateKey: String
    let task: TodoTask?
    let onDismiss: () -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var priority: TaskPriority = .medium
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isCompleted = false
    @State private var hasReminder = false
    @State private var reminderValue = 15
    @State private var reminderUnit = 0 // 0=分钟, 1=小时, 2=天

    private var isEditing: Bool { task != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)

                Spacer()

                Text(isEditing ? "编辑任务" : "新建任务")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                // Save button in header
                Button(isEditing ? "保存" : "添加") { saveTask() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // Completion status (only when editing)
                    if isEditing {
                        Button {
                            isCompleted.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(isCompleted ? .green : .secondary)
                                Text(isCompleted ? "已完成" : "标记为完成")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Label("标题", systemImage: "textformat")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("输入任务标题", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                    }

                    // Description
                    VStack(alignment: .leading, spacing: 6) {
                        Label("描述", systemImage: "text.alignleft")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("添加描述（可选）", text: $description, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .lineLimit(2...4)
                    }

                    // Priority
                    VStack(alignment: .leading, spacing: 8) {
                        Label("优先级", systemImage: "flag")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(TaskPriority.allCases, id: \.self) { p in
                                let selected = priority == p
                                let color = priorityColor(for: p)
                                Button { priority = p } label: {
                                    HStack(spacing: 4) {
                                        Circle().fill(color).frame(width: 6, height: 6)
                                        Text(p.rawValue)
                                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                    }
                                    .foregroundStyle(selected ? color : .secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(selected ? color.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(selected ? color.opacity(0.3) : .clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Due date section
                    DueDateSection(hasDueDate: $hasDueDate, dueDate: $dueDate)

                    // Reminder section
                    if hasDueDate {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("提醒时间", systemImage: "bell")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Toggle("", isOn: $hasReminder)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                            }

                            if hasReminder {
                                HStack(spacing: 8) {
                                    Text("提前")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)

                                    TextField("", value: $reminderValue, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .font(.system(size: 12))

                                    Picker("", selection: $reminderUnit) {
                                        Text("分钟").tag(0)
                                        Text("小时").tag(1)
                                        Text("天").tag(2)
                                    }
                                    .labelsHidden()
                                    .frame(width: 80)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 580)
        .onAppear {
            if let task {
                title = task.title
                description = task.description
                priority = task.priority
                isCompleted = task.isCompleted
                if let due = task.dueDate {
                    hasDueDate = true
                    dueDate = due
                }
                if let minutes = task.reminderMinutes {
                    hasReminder = true
                    if minutes % 1440 == 0 {
                        reminderValue = minutes / 1440
                        reminderUnit = 2
                    } else if minutes % 60 == 0 {
                        reminderValue = minutes / 60
                        reminderUnit = 1
                    } else {
                        reminderValue = minutes
                        reminderUnit = 0
                    }
                }
            }
        }
    }

    private func saveTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        let reminderMinutes: Int? = {
            guard hasReminder else { return nil }
            switch reminderUnit {
            case 0: return reminderValue
            case 1: return reminderValue * 60
            case 2: return reminderValue * 1440
            default: return nil
            }
        }()

        if let existingTask = task {
            var updatedTask = existingTask
            updatedTask.title = trimmedTitle
            updatedTask.description = description
            updatedTask.priority = priority
            updatedTask.dueDate = hasDueDate ? dueDate : nil
            updatedTask.isCompleted = isCompleted
            updatedTask.completedAt = isCompleted ? (existingTask.isCompleted ? existingTask.completedAt : Date()) : nil
            updatedTask.reminderMinutes = reminderMinutes

            if let oldNotificationID = existingTask.notificationID {
                NotificationManager.shared.cancelTaskNotification(notificationID: oldNotificationID)
            }

            if reminderMinutes != nil, !updatedTask.isCompleted {
                let notificationID = "task-\(updatedTask.id.uuidString)"
                updatedTask.notificationID = notificationID
                NotificationManager.shared.scheduleTaskNotification(task: updatedTask, dateKey: dateKey)
            } else {
                updatedTask.notificationID = nil
            }

            store.updateTask(updatedTask, forKey: dateKey)
        } else {
            let newTask = TodoTask(
                title: trimmedTitle,
                description: description,
                dueDate: hasDueDate ? dueDate : nil,
                priority: priority,
                notificationID: reminderMinutes != nil ? "task-\(UUID().uuidString)" : nil,
                dateKey: dateKey,
                reminderMinutes: reminderMinutes
            )

            store.addTask(newTask, forKey: dateKey)

            if reminderMinutes != nil {
                NotificationManager.shared.scheduleTaskNotification(task: newTask, dateKey: dateKey)
            }
        }

        onDismiss()
    }

    private func priorityColor(for priority: TaskPriority) -> Color {
        switch priority {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

// MARK: - DueDateSection

private struct DueDateSection: View {
    @Binding var hasDueDate: Bool
    @Binding var dueDate: Date

    @State private var displayMonth: Date = Date()

    private let calendar = Calendar.current
    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    private static let monthFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy年M月"
        return fmt
    }()

    private static let summaryFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 EEEE HH:mm"
        return fmt
    }()

    private var daysInMonth: [Date?] {
        let range = calendar.range(of: .day, in: .month, for: displayMonth)!
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: displayMonth))!
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1 // 0=Sun

        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in range {
            var comps = calendar.dateComponents([.year, .month], from: firstOfMonth)
            comps.day = day
            days.append(calendar.date(from: comps))
        }
        return days
    }

    private func isSelected(_ date: Date) -> Bool {
        hasDueDate && calendar.isDate(date, inSameDayAs: dueDate)
    }

    private func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    private func isPast(_ date: Date) -> Bool {
        calendar.startOfDay(for: date) < calendar.startOfDay(for: Date())
    }

    private func selectDate(_ date: Date) {
        let hour = calendar.component(.hour, from: dueDate)
        let minute = calendar.component(.minute, from: dueDate)
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = minute
        dueDate = calendar.date(from: comps) ?? date
        hasDueDate = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("截止时间", systemImage: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                // Month nav
                HStack {
                    Button {
                        displayMonth = calendar.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text(Self.monthFormatter.string(from: displayMonth))
                        .font(.system(size: 12, weight: .medium))

                    Spacer()

                    Button {
                        displayMonth = calendar.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                // Weekday header
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(weekdays, id: \.self) { day in
                        Text(day)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(height: 16)
                    }
                }

                // Day grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                    ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                        if let date {
                            let selected = isSelected(date)
                            let today = isToday(date)
                            let past = isPast(date)

                            Button { selectDate(date) } label: {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.system(size: 11, weight: selected ? .bold : today ? .semibold : .regular))
                                    .foregroundStyle(
                                        selected ? Color.white :
                                        past ? Color.secondary.opacity(0.4) :
                                        today ? Color.accentColor : Color.primary
                                    )
                                    .frame(width: 26, height: 26)
                                    .background(
                                        Circle().fill(selected ? Color.accentColor : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Color.clear.frame(width: 26, height: 26)
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                // Time row
                HStack {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("时间")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Hour : Minute
                    HStack(spacing: 3) {
                        TimeField(
                            value: Binding(
                                get: { calendar.component(.hour, from: dueDate) },
                                set: { newHour in
                                    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
                                    comps.hour = max(0, min(23, newHour))
                                    dueDate = calendar.date(from: comps) ?? dueDate
                                    hasDueDate = true
                                }
                            ),
                            range: 0...23
                        )

                        Text(":")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)

                        TimeField(
                            value: Binding(
                                get: { calendar.component(.minute, from: dueDate) },
                                set: { newMinute in
                                    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
                                    comps.minute = max(0, min(59, newMinute))
                                    dueDate = calendar.date(from: comps) ?? dueDate
                                    hasDueDate = true
                                }
                            ),
                            range: 0...59
                        )
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Summary + clear
            if hasDueDate {
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9))
                        Text(Self.summaryFormatter.string(from: dueDate))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    Button {
                        withAnimation { hasDueDate = false }
                    } label: {
                        Text("清除")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            if hasDueDate {
                displayMonth = dueDate
            }
        }
    }
}

// MARK: - TimeField

private struct TimeField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Up button
            Button {
                if value < range.upperBound { value += 1 }
                else { value = range.lowerBound }
                syncText()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Editable text field
            TextField("", text: $text)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(width: 36, height: 22)
                .focused($isFocused)
                .onSubmit { commitEdit() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitEdit() }
                }

            // Down button
            Button {
                if value > range.lowerBound { value -= 1 }
                else { value = range.upperBound }
                syncText()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { syncText() }
        .onChange(of: value) { syncText() }
    }

    private func syncText() {
        text = String(format: "%02d", value)
    }

    private func commitEdit() {
        if let parsed = Int(text.trimmingCharacters(in: .whitespaces)) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        syncText()
    }
}
