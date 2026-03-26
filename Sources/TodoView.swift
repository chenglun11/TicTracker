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
    @State private var selectedTaskID: UUID?
    @State private var hoveredTaskID: UUID?

    private var selectedKey: String {
        DataStore.dateKey(from: selectedDate)
    }

    private var allTasks: [TodoTask] {
        store.allTasksForDate(selectedDate)
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

    private var selectedTask: TodoTask? {
        guard let id = selectedTaskID else { return nil }
        return allTasks.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            // 左侧面板
            VStack(spacing: 0) {
                headerSection
                contentSection
                footerSection
            }
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)
            .searchable(text: $searchText, prompt: "搜索任务")

            // 右侧详情
            if let task = selectedTask {
                taskDetail(task)
            } else {
                ContentUnavailableView {
                    Label("选择任务查看详情", systemImage: "checklist")
                } description: {
                    Text("在左侧列表中选择任务")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Task Detail

    @ViewBuilder
    private func taskDetail(_ task: TodoTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title
                VStack(alignment: .leading, spacing: 6) {
                    Label("标题", systemImage: "textformat")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("输入任务标题", text: Binding(
                        get: { task.title },
                        set: { updateTask(task, title: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }

                // Description
                VStack(alignment: .leading, spacing: 6) {
                    Label("描述", systemImage: "text.alignleft")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("添加描述（可选）", text: Binding(
                        get: { task.description },
                        set: { updateTask(task, description: $0) }
                    ), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .lineLimit(2...6)
                }

                // Priority
                VStack(alignment: .leading, spacing: 8) {
                    Label("优先级", systemImage: "flag")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        ForEach(TaskPriority.allCases, id: \.self) { p in
                            let selected = task.priority == p
                            let color = priorityColor(for: p)
                            Button {
                                updateTask(task, priority: p)
                            } label: {
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

                // Due date
                VStack(alignment: .leading, spacing: 8) {
                    Label("截止时间", systemImage: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    DatePicker("", selection: Binding(
                        get: { task.dueDate ?? Date() },
                        set: { newDate in
                            var updated = task
                            updated.dueDate = newDate
                            store.updateTask(updated, forKey: selectedKey)
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .disabled(task.dueDate == nil)

                    Toggle("设置截止时间", isOn: Binding(
                        get: { task.dueDate != nil },
                        set: { enabled in
                            var updated = task
                            updated.dueDate = enabled ? Date() : nil
                            store.updateTask(updated, forKey: selectedKey)
                        }
                    ))
                    .font(.system(size: 12))
                }

                // Reminder
                if task.dueDate != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("提醒", systemImage: "bell")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Picker("提前提醒", selection: Binding(
                            get: { task.reminderMinutes ?? 0 },
                            set: { minutes in
                                var updated = task
                                updated.reminderMinutes = minutes > 0 ? minutes : nil
                                store.updateTask(updated, forKey: selectedKey)
                            }
                        )) {
                            Text("不提醒").tag(0)
                            Text("准时").tag(0)
                            Text("提前5分钟").tag(5)
                            Text("提前15分钟").tag(15)
                            Text("提前30分钟").tag(30)
                            Text("提前1小时").tag(60)
                        }
                        .labelsHidden()
                    }
                }

                Divider()

                // Metadata
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("创建于 \(task.createdAt, style: .date) \(task.createdAt, style: .time)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let completedAt = task.completedAt {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text("完成于 \(completedAt, style: .date) \(completedAt, style: .time)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Actions
                HStack(spacing: 12) {
                    Button {
                        toggleTaskCompletion(task)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: task.isCompleted ? "arrow.uturn.backward" : "checkmark.circle.fill")
                            Text(task.isCompleted ? "标记为未完成" : "标记为完成")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(task.isCompleted ? .orange : .green)

                    Button(role: .destructive) {
                        deleteTaskAndClearSelection(task)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("删除")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
    }

    private func updateTask(_ task: TodoTask, title: String? = nil, description: String? = nil, priority: TaskPriority? = nil) {
        var updated = task
        if let title = title { updated.title = title }
        if let description = description { updated.description = description }
        if let priority = priority { updated.priority = priority }
        store.updateTask(updated, forKey: selectedKey)
    }

    private func toggleTaskCompletion(_ task: TodoTask) {
        var updated = task
        updated.isCompleted.toggle()
        updated.completedAt = updated.isCompleted ? Date() : nil

        if updated.isCompleted, let notificationID = updated.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
        }

        if !updated.isCompleted, let dueDate = updated.dueDate, dueDate > Date() {
            let notificationID = updated.notificationID ?? "task-\(updated.id.uuidString)"
            updated.notificationID = notificationID
            NotificationManager.shared.scheduleTaskNotification(task: updated, dateKey: selectedKey)
        }

        store.updateTask(updated, forKey: selectedKey)
    }

    private func deleteTaskAndClearSelection(_ task: TodoTask) {
        if let notificationID = task.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
        }
        store.deleteTask(id: task.id, forKey: selectedKey)
        selectedTaskID = nil
    }

    private func priorityColor(for priority: TaskPriority) -> Color {
        switch priority {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
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
        List(selection: $selectedTaskID) {
            ForEach(filteredTasks) { task in
                TaskRow(
                    task: task,
                    dateKey: selectedKey,
                    store: store,
                    isHovered: hoveredTaskID == task.id
                )
                .tag(task.id)
                .onHover { hoveredTaskID = $0 ? task.id : nil }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                let newTask = TodoTask(title: "", dateKey: selectedKey)
                store.addTask(newTask, forKey: selectedKey)
                selectedTaskID = newTask.id
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

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "新任务" : task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.title.isEmpty ? .tertiary : (task.isCompleted ? .tertiary : .primary))
                    .lineLimit(1)
            }

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
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button(task.isCompleted ? "标记为未完成" : "标记为完成") { toggleCompletion() }
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

// MARK: - TaskDueDateSection

private struct TaskDueDateSection: View {
    let task: TodoTask
    @Bindable var store: DataStore
    let dateKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("截止时间", systemImage: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if let dueDate = task.dueDate {
                VStack(spacing: 8) {
                    HStack {
                        Text(dueDate, style: .date)
                            .font(.system(size: 13, weight: .medium))
                        Text(dueDate, style: .time)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("清除") {
                            var updated = task
                            updated.dueDate = nil
                            store.updateTask(updated, forKey: dateKey)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    DatePicker("", selection: Binding(
                        get: { task.dueDate ?? Date() },
                        set: { newDate in
                            var updated = task
                            updated.dueDate = newDate
                            store.updateTask(updated, forKey: dateKey)
                        }
                    ))
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                }
            } else {
                Button {
                    var updated = task
                    updated.dueDate = Date()
                    store.updateTask(updated, forKey: dateKey)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("设置截止时间")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - TaskReminderSection

private struct TaskReminderSection: View {
    let task: TodoTask
    @Bindable var store: DataStore
    let dateKey: String

    @State private var reminderValue = 15
    @State private var reminderUnit = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("提醒时间", systemImage: "bell")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { task.reminderMinutes != nil },
                    set: { enabled in
                        var updated = task
                        if enabled {
                            updated.reminderMinutes = 15
                            let notificationID = "task-\(updated.id.uuidString)"
                            updated.notificationID = notificationID
                            store.updateTask(updated, forKey: dateKey)
                            NotificationManager.shared.scheduleTaskNotification(task: updated, dateKey: dateKey)
                        } else {
                            if let notificationID = updated.notificationID {
                                NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
                            }
                            updated.reminderMinutes = nil
                            updated.notificationID = nil
                            store.updateTask(updated, forKey: dateKey)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if task.reminderMinutes != nil {
                HStack(spacing: 8) {
                    Text("提前")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField("", value: $reminderValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .font(.system(size: 12))
                        .onChange(of: reminderValue) { _, newValue in
                            updateReminder(newValue, reminderUnit)
                        }

                    Picker("", selection: $reminderUnit) {
                        Text("分钟").tag(0)
                        Text("小时").tag(1)
                        Text("天").tag(2)
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    .onChange(of: reminderUnit) { _, newUnit in
                        updateReminder(reminderValue, newUnit)
                    }
                }
            }
        }
        .onAppear {
            if let minutes = task.reminderMinutes {
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

    private func updateReminder(_ value: Int, _ unit: Int) {
        let minutes: Int = {
            switch unit {
            case 0: return value
            case 1: return value * 60
            case 2: return value * 1440
            default: return value
            }
        }()

        var updated = task
        updated.reminderMinutes = minutes

        if let oldNotificationID = updated.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: oldNotificationID)
        }

        if !updated.isCompleted {
            let notificationID = "task-\(updated.id.uuidString)"
            updated.notificationID = notificationID
            store.updateTask(updated, forKey: dateKey)
            NotificationManager.shared.scheduleTaskNotification(task: updated, dateKey: dateKey)
        } else {
            store.updateTask(updated, forKey: dateKey)
        }
    }
}

