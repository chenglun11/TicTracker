import SwiftUI

struct BugView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var statusFilter: BugStatusFilter = .unresolved
    @State private var newBugTitle = ""
    @State private var newBugAssignee: String?
    @State private var newBugJiraKey = ""
    @State private var showJiraPanel = false
    @State private var jiraRefreshing = false

    private enum BugStatusFilter: String, CaseIterable {
        case all = "全部"
        case unresolved = "未解决"
        case fixed = "已修复"
        case ignored = "已忽略"
    }

    private var filteredBugs: [BugEntry] {
        var bugs = store.bugEntries

        switch statusFilter {
        case .all: break
        case .unresolved: bugs = bugs.filter { !$0.status.isResolved }
        case .fixed: bugs = bugs.filter { $0.status == .fixed }
        case .ignored: bugs = bugs.filter { $0.status == .ignored }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            bugs = bugs.filter {
                $0.title.lowercased().contains(query) ||
                ($0.assignee?.lowercased().contains(query) ?? false) ||
                ($0.jiraKey?.lowercased().contains(query) ?? false) ||
                ($0.note?.lowercased().contains(query) ?? false)
            }
        }

        return bugs.sorted { $0.createdAt > $1.createdAt }
    }

    private var unresolvedCount: Int {
        store.bugEntries.filter { !$0.status.isResolved }.count
    }

    /// Jira issues not yet linked to any bug
    private var unlinkedJiraIssues: [JiraIssue] {
        let linkedKeys = Set(store.bugEntries.compactMap(\.jiraKey))
        return store.jiraIssues.filter { !linkedKeys.contains($0.key) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main bug list
            bugListPanel

            // Jira sidebar
            if store.jiraConfig.enabled && showJiraPanel {
                Divider()
                jiraPanel
                    .frame(width: 260)
            }
        }
        .frame(minWidth: store.jiraConfig.enabled && showJiraPanel ? 820 : 550, minHeight: 400)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Bug List Panel

    @ViewBuilder
    private var bugListPanel: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    statCard(title: "总计", value: "\(store.bugEntries.count)", color: .blue)
                    statCard(title: "未解决", value: "\(unresolvedCount)", color: unresolvedCount > 0 ? .red : .green)
                    statCard(title: "已修复", value: "\(store.bugEntries.filter { $0.status == .fixed }.count)", color: .green)
                    statCard(title: "已忽略", value: "\(store.bugEntries.filter { $0.status == .ignored }.count)", color: .secondary)
                }
                .padding(.horizontal)

                // Filter + Search + Jira toggle
                HStack(spacing: 8) {
                    ForEach(BugStatusFilter.allCases, id: \.self) { filter in
                        Button(filter.rawValue) {
                            statusFilter = filter
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            statusFilter == filter ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(statusFilter == filter ? .white : .primary)
                    }
                    Spacer()
                    if store.jiraConfig.enabled {
                        Button {
                            withAnimation { showJiraPanel.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "server.rack")
                                Text("Jira")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(showJiraPanel ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: 160)
                }
                .padding(.horizontal)

                // Add new bug
                HStack(spacing: 8) {
                    TextField("新 Bug 描述…", text: $newBugTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addBug() }
                    if !store.bugTeamMembers.isEmpty {
                        Picker("", selection: $newBugAssignee) {
                            Text("未指派").tag(String?.none)
                            ForEach(store.bugTeamMembers, id: \.self) { member in
                                Text(member).tag(String?.some(member))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    if store.jiraConfig.enabled && !store.jiraIssues.isEmpty {
                        Picker("", selection: $newBugJiraKey) {
                            Text("无关联").tag("")
                            ForEach(store.jiraIssues) { issue in
                                Text("\(issue.key) \(issue.summary)").tag(issue.key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    } else {
                        TextField("Jira 单号", text: $newBugJiraKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    Button("添加") { addBug() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newBugTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Bug list
            if filteredBugs.isEmpty {
                ContentUnavailableView {
                    Label("无 Bug 记录", systemImage: "ladybug")
                } description: {
                    Text(searchText.isEmpty ? "点击上方添加新的 Bug" : "没有匹配的结果")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(filteredBugs) { bug in
                    bugRow(bug)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: - Jira Panel

    @ViewBuilder
    private var jiraPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Jira 工单")
                    .font(.headline)
                Spacer()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if store.jiraIssues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("暂无工单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !unlinkedJiraIssues.isEmpty {
                        Section("未关联 (\(unlinkedJiraIssues.count))") {
                            ForEach(unlinkedJiraIssues) { issue in
                                jiraIssueRow(issue)
                            }
                        }
                    }
                    let linked = store.jiraIssues.filter { issue in
                        store.bugEntries.contains { $0.jiraKey == issue.key }
                    }
                    if !linked.isEmpty {
                        Section("已关联 (\(linked.count))") {
                            ForEach(linked) { issue in
                                jiraIssueRow(issue, linked: true)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func jiraIssueRow(_ issue: JiraIssue, linked: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(issue.key)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.blue)
                if let type = issue.issueType {
                    Text(type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(issue.status)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(jiraStatusColor(issue.statusCategoryKey).opacity(0.15))
                    .clipShape(Capsule())
            }
            Text(issue.summary)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
            if !linked {
                Button {
                    createBugFromJira(issue)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("创建 Bug")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func jiraStatusColor(_ categoryKey: String) -> Color {
        switch categoryKey {
        case "new": return .blue
        case "indeterminate": return .yellow
        case "done": return .green
        default: return .gray
        }
    }

    // MARK: - Bug Row

    @ViewBuilder
    private func bugRow(_ bug: BugEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Status menu
                Menu {
                    ForEach(BugStatus.allCases, id: \.self) { status in
                        Button {
                            store.updateBugStatus(id: bug.id, status: status)
                        } label: {
                            Label(status.rawValue, systemImage: status.icon)
                        }
                        .disabled(bug.status == status)
                    }
                } label: {
                    Image(systemName: bug.status.icon)
                        .foregroundStyle(statusColor(bug.status))
                        .frame(width: 20)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)

                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text(bug.title)
                        .strikethrough(bug.status.isResolved)
                        .foregroundStyle(bug.status.isResolved ? .secondary : .primary)
                    HStack(spacing: 6) {
                        Text(bug.dateKey)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if store.jiraConfig.enabled && !store.jiraIssues.isEmpty {
                            Menu {
                                Button("无关联") {
                                    store.updateBugJiraKey(id: bug.id, jiraKey: nil)
                                }
                                Divider()
                                ForEach(store.jiraIssues) { issue in
                                    Button("\(issue.key) \(issue.summary)") {
                                        store.updateBugJiraKey(id: bug.id, jiraKey: issue.key)
                                    }
                                }
                            } label: {
                                if let jira = bug.jiraKey {
                                    Text(jira)
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.15))
                                        .clipShape(Capsule())
                                } else {
                                    Image(systemName: "link.badge.plus")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .menuStyle(.borderlessButton)
                        } else if let jira = bug.jiraKey {
                            Text(jira)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                // Assignee
                if !store.bugTeamMembers.isEmpty {
                    Menu {
                        Button("未指派") {
                            store.updateBugAssignee(id: bug.id, assignee: nil)
                        }
                        Divider()
                        ForEach(store.bugTeamMembers, id: \.self) { member in
                            Button(member) {
                                store.updateBugAssignee(id: bug.id, assignee: member)
                            }
                        }
                    } label: {
                        if let assignee = bug.assignee {
                            Text(assignee)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .clipShape(Capsule())
                        } else {
                            Image(systemName: "person.badge.plus")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80, alignment: .trailing)
                } else if let assignee = bug.assignee {
                    Text(assignee)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }

                // Delete
                Button {
                    store.deleteBug(id: bug.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
            }

            // Note
            TextField("备注…", text: Binding(
                get: { bug.note ?? "" },
                set: { store.updateBugNote(id: bug.id, note: $0.isEmpty ? nil : $0) }
            ))
            .font(.caption)
            .textFieldStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func statusColor(_ status: BugStatus) -> Color {
        switch status {
        case .pending: return .red
        case .inProgress: return .orange
        case .fixed: return .green
        case .ignored: return .secondary
        }
    }

    @ViewBuilder
    private func statCard(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func addBug() {
        let title = newBugTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let jira = newBugJiraKey.trimmingCharacters(in: .whitespaces)
        let todayKey = store.todayKey
        store.addBug(title, forKey: todayKey, assignee: newBugAssignee, jiraKey: jira.isEmpty ? nil : jira)
        newBugTitle = ""
        newBugJiraKey = ""
    }

    private func createBugFromJira(_ issue: JiraIssue) {
        store.addBug(issue.summary, forKey: store.todayKey, jiraKey: issue.key)
    }
}
