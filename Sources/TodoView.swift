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

    private var selectedKey: String {
        DataStore.dateKey(from: selectedDate)
    }

    private var filteredTasks: [TodoTask] {
        var tasks = store.tasksForKey(selectedKey)

        // Apply filter
        switch filter {
        case .all: break
        case .active: tasks = tasks.filter { !$0.isCompleted }
        case .completed: tasks = tasks.filter { $0.isCompleted }
        }

        // Apply search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            tasks = tasks.filter {
                $0.title.lowercased().contains(query) ||
                $0.description.lowercased().contains(query)
            }
        }

        // Sort: incomplete first, then by priority (high to low), then by due date, then by creation date
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
        store.tasksForKey(selectedKey).filter { !$0.isCompleted }.count
    }

    private static let displayDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月d日 (EEE)"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .frame(width: 120)

                Spacer()

                Picker("", selection: $filter) {
                    ForEach(TaskFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                if activeCount > 0 {
                    Text("\(activeCount) 个进行中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("搜索任务", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Task list
            if filteredTasks.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? "暂无任务" : "无匹配任务", systemImage: "checklist")
                } description: {
                    if searchText.isEmpty {
                        Text("点击下方 + 按钮添加新任务")
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTasks) { task in
                            TaskRow(task: task, dateKey: selectedKey, store: store) {
                                editingTask = task
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                            if task.id != filteredTasks.last?.id {
                                Divider()
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
            }

            Divider()

            // Bottom toolbar
            HStack(spacing: 12) {
                Button {
                    showingAddSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("添加任务")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)

                Spacer()

                Text("\(filteredTasks.count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
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
    }
}

struct TaskRow: View {
    let task: TodoTask
    let dateKey: String
    @Bindable var store: DataStore
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
        fmt.dateFormat = "M/d HH:mm"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    var body: some View {
        HStack(spacing: 12) {
            Button {
                toggleCompletion()
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(priorityColor)
                        .frame(width: 6, height: 6)

                    Text(task.title)
                        .font(.body)
                        .strikethrough(task.isCompleted)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)

                    Spacer()

                    if let dueDate = task.dueDate {
                        HStack(spacing: 4) {
                            Image(systemName: isOverdue ? "exclamationmark.triangle.fill" : "clock")
                                .font(.caption2)
                            Text(Self.dueDateFormatter.string(from: dueDate))
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isOverdue ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                        .foregroundStyle(isOverdue ? .red : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onEdit()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteTask()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                toggleCompletion()
            } label: {
                Label(task.isCompleted ? "未完成" : "完成", systemImage: task.isCompleted ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(task.isCompleted ? .orange : .green)
        }
        .contextMenu {
            Button(task.isCompleted ? "标记为未完成" : "标记为完成") {
                toggleCompletion()
            }
            Button("编辑") {
                onEdit()
            }
            Divider()
            Button("删除", role: .destructive) {
                deleteTask()
            }
        }
    }

    private func toggleCompletion() {
        var updatedTask = task
        updatedTask.isCompleted.toggle()
        updatedTask.completedAt = updatedTask.isCompleted ? Date() : nil

        // Cancel notification if completing
        if updatedTask.isCompleted, let notificationID = updatedTask.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
        }

        // Reschedule notification if uncompleting and has future due date
        if !updatedTask.isCompleted, let dueDate = updatedTask.dueDate, dueDate > Date() {
            let notificationID = updatedTask.notificationID ?? "task-\(updatedTask.id.uuidString)"
            updatedTask.notificationID = notificationID
            NotificationManager.shared.scheduleTaskNotification(task: updatedTask, dateKey: dateKey)
        }

        store.updateTask(updatedTask, forKey: dateKey)
    }

    private func deleteTask() {
        // Cancel notification if exists
        if let notificationID = task.notificationID {
            NotificationManager.shared.cancelTaskNotification(notificationID: notificationID)
        }
        store.deleteTask(id: task.id, forKey: dateKey)
    }
}

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

    private var isEditing: Bool {
        task != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "编辑任务" : "新建任务")
                    .font(.headline)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标题")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("输入任务标题", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("描述")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("添加任务描述（可选）", text: $description, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("优先级")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $priority) {
                            ForEach(TaskPriority.allCases, id: \.self) { p in
                                HStack {
                                    Circle()
                                        .fill(priorityColor(for: p))
                                        .frame(width: 8, height: 8)
                                    Text(p.rawValue)
                                }
                                .tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider()

                    Toggle(isOn: $hasDueDate) {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text("设置截止时间")
                        }
                    }
                    .toggleStyle(.switch)

                    if hasDueDate {
                        DatePicker("截止时间", selection: $dueDate)
                            .datePickerStyle(.graphical)
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack(spacing: 12) {
                Button("取消") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Spacer()

                Button(isEditing ? "保存" : "添加") {
                    saveTask()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 450, height: 550)
        .onAppear {
            if let task {
                title = task.title
                description = task.description
                priority = task.priority
                if let due = task.dueDate {
                    hasDueDate = true
                    dueDate = due
                }
            }
        }
    }

    private func saveTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        if let existingTask = task {
            // Update existing task
            var updatedTask = existingTask
            updatedTask.title = trimmedTitle
            updatedTask.description = description
            updatedTask.priority = priority
            updatedTask.dueDate = hasDueDate ? dueDate : nil

            // Update notification if due date changed
            if let oldNotificationID = existingTask.notificationID {
                NotificationManager.shared.cancelTaskNotification(notificationID: oldNotificationID)
            }

            if hasDueDate, !updatedTask.isCompleted, dueDate > Date() {
                let notificationID = "task-\(updatedTask.id.uuidString)"
                updatedTask.notificationID = notificationID
                NotificationManager.shared.scheduleTaskNotification(task: updatedTask, dateKey: dateKey)
            } else {
                updatedTask.notificationID = nil
            }

            store.updateTask(updatedTask, forKey: dateKey)
        } else {
            // Create new task
            let notificationID = hasDueDate && dueDate > Date() ? "task-\(UUID().uuidString)" : nil
            let newTask = TodoTask(
                title: trimmedTitle,
                description: description,
                dueDate: hasDueDate ? dueDate : nil,
                priority: priority,
                notificationID: notificationID
            )

            store.addTask(newTask, forKey: dateKey)

            // Schedule notification if has future due date
            if hasDueDate && dueDate > Date() {
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
