import SwiftUI

struct IssueTrackerView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .unresolved
    @State private var typeFilter: TypeFilter = .all
    @State private var selectedIssueID: UUID?
    @State private var jiraSyncing = false
    @State private var newCommentText = ""

    private enum StatusFilter: String, CaseIterable {
        case all = "全部"
        case unresolved = "未解决"
        case fixed = "已修复"
        case ignored = "已忽略"
    }

    private enum TypeFilter: String, CaseIterable {
        case all = "全部"
        case bug = "Bug"
        case hotfix = "Feat"
        case issue = "问题"

        var issueType: IssueType? {
            switch self {
            case .all: return nil
            case .bug: return .bug
            case .hotfix: return .hotfix
            case .issue: return .issue
            }
        }
    }

    private var filteredIssues: [TrackedIssue] {
        var issues = store.trackedIssues

        if let type = typeFilter.issueType {
            issues = issues.filter { $0.type == type }
        }

        switch statusFilter {
        case .all: break
        case .unresolved: issues = issues.filter { !$0.status.isResolved }
        case .fixed: issues = issues.filter { $0.status == .fixed }
        case .ignored: issues = issues.filter { $0.status == .ignored }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            issues = issues.filter {
                $0.title.lowercased().contains(query) ||
                ($0.assignee?.lowercased().contains(query) ?? false) ||
                ($0.jiraKey?.lowercased().contains(query) ?? false) ||
                ($0.department?.lowercased().contains(query) ?? false) ||
                $0.comments.contains(where: { $0.text.lowercased().contains(query) })
            }
        }

        return issues.sorted { $0.createdAt > $1.createdAt }
    }

    private var unresolvedCount: Int {
        store.trackedIssues.filter { !$0.status.isResolved }.count
    }

    private var selectedIssue: TrackedIssue? {
        guard let id = selectedIssueID else { return nil }
        return store.trackedIssues.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            // Left sidebar
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    // Stats
                    HStack(spacing: 8) {
                        statBadge(title: "总计", value: store.trackedIssues.count, color: .blue)
                        statBadge(title: "未解决", value: unresolvedCount, color: unresolvedCount > 0 ? .orange : .green)
                    }
                    Spacer()
                    if store.jiraConfig.enabled {
                        Button {
                            jiraSyncing = true
                            Task {
                                async let myResult = JiraService.shared.fetchMyIssues()
                                async let reportedResult = JiraService.shared.fetchReportedIssues()
                                _ = await (myResult, reportedResult)
                                await JiraService.shared.syncTrackedIssues()
                                jiraSyncing = false
                            }
                        } label: {
                            Image(systemName: jiraSyncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                                .rotationEffect(jiraSyncing ? .degrees(360) : .zero)
                                .animation(jiraSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: jiraSyncing)
                        }
                        .buttonStyle(.borderless)
                        .disabled(jiraSyncing)
                    }
                    Button {
                        addNewIssue()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                // Type filter
                HStack(spacing: 6) {
                    ForEach(TypeFilter.allCases, id: \.self) { filter in
                        Button {
                            typeFilter = filter
                        } label: {
                            HStack(spacing: 4) {
                                if let type = filter.issueType {
                                    Image(systemName: type.icon)
                                        .font(.caption2)
                                }
                                Text(filter.rawValue)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                typeFilter == filter
                                    ? (filter.issueType?.color ?? Color.accentColor)
                                    : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(typeFilter == filter ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Status filter
                HStack(spacing: 6) {
                    ForEach(StatusFilter.allCases, id: \.self) { filter in
                        Button(filter.rawValue) {
                            statusFilter = filter
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            statusFilter == filter ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(statusFilter == filter ? .white : .primary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                Divider()

                // List
                if filteredIssues.isEmpty {
                    ContentUnavailableView {
                        Label("无记录", systemImage: "tray")
                    } description: {
                        Text(searchText.isEmpty ? "点击 + 添加新问题" : "没有匹配的结果")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedIssueID) {
                        ForEach(filteredIssues) { issue in
                            listRow(issue)
                                .tag(issue.id)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)
            .searchable(text: $searchText, prompt: "搜索问题")

            // Right detail
            if let issue = selectedIssue {
                issueDetail(issue)
            } else {
                ContentUnavailableView {
                    Label("选择问题查看详情", systemImage: "ladybug")
                } description: {
                    Text("在左侧列表中选择问题")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedIssueID == nil, let first = filteredIssues.first {
                selectedIssueID = first.id
            }
        }
        .onChange(of: searchText) {
            if let id = selectedIssueID, !filteredIssues.contains(where: { $0.id == id }) {
                selectedIssueID = filteredIssues.first?.id
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - List Row

    @ViewBuilder
    private func listRow(_ issue: TrackedIssue) -> some View {
        HStack(spacing: 6) {
            Image(systemName: issue.type.icon)
                .font(.system(size: 10))
                .foregroundStyle(issue.type.color)
            Image(systemName: issue.status.icon)
                .font(.system(size: 10))
                .foregroundStyle(statusColor(issue.status))
            Text(issue.title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            if let assignee = issue.assignee {
                Text(assignee)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text(issue.dateKey)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Issue Detail

    @ViewBuilder
    private func issueDetail(_ issue: TrackedIssue) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                TextField("标题", text: Binding(
                    get: { issue.title },
                    set: { store.updateIssueTitle(id: issue.id, title: $0) }
                ), axis: .vertical)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .lineLimit(1...5)

                // Type, Status, Assignee, Department
                HStack(spacing: 12) {
                    Picker("类型", selection: Binding(
                        get: { issue.type },
                        set: { store.updateIssueType(id: issue.id, type: $0) }
                    )) {
                        ForEach(IssueType.allCases, id: \.self) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    Menu {
                        ForEach(IssueStatus.allCases, id: \.self) { status in
                            Button {
                                store.updateIssueStatus(id: issue.id, status: status)
                            } label: {
                                Label(status.rawValue, systemImage: status.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: issue.status.icon)
                            Text(issue.status.rawValue)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if !store.bugTeamMembers.isEmpty {
                        Menu {
                            Button("未指派") {
                                store.updateIssueAssignee(id: issue.id, assignee: nil)
                            }
                            Divider()
                            ForEach(store.bugTeamMembers, id: \.self) { member in
                                Button(member) {
                                    store.updateIssueAssignee(id: issue.id, assignee: member)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "person")
                                Text(issue.assignee ?? "未指派")
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    if issue.type == .issue {
                        Picker("项目", selection: Binding(
                            get: { issue.department },
                            set: { store.updateIssueDepartment(id: issue.id, department: $0) }
                        )) {
                            Text("选择项目").tag(String?.none)
                            ForEach(store.departments, id: \.self) { dept in
                                Text(dept).tag(String?.some(dept))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                // Jira
                if store.jiraConfig.enabled {
                    HStack(spacing: 8) {
                        TextField("Jira Key", text: Binding(
                            get: { issue.jiraKey ?? "" },
                            set: { store.updateIssueJiraKey(id: issue.id, jiraKey: $0.isEmpty ? nil : $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                        if !store.filteredJiraIssues.isEmpty {
                            Menu {
                                Button("无关联") {
                                    store.updateIssueJiraKey(id: issue.id, jiraKey: nil)
                                }
                                Divider()
                                ForEach(store.filteredJiraIssues) { jiraIssue in
                                    Button("\(jiraIssue.key) \(jiraIssue.summary)") {
                                        store.updateIssueJiraKey(id: issue.id, jiraKey: jiraIssue.key)
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "link")
                                    Text("关联工单")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                Divider()

                // Timestamps
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("创建时间")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Self.timeFmt.string(from: issue.createdAt))
                            .font(.callout)
                    }
                    if let updated = issue.updatedAt {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("更新时间")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Self.timeFmt.string(from: updated))
                                .font(.callout)
                        }
                    }
                }

                Divider()

                // Comments timeline
                VStack(alignment: .leading, spacing: 8) {
                    Text("备注时间线")
                        .font(.headline)

                    if issue.comments.isEmpty {
                        Text("暂无备注")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(issue.comments.sorted { $0.createdAt > $1.createdAt }) { comment in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.timeFmt.string(from: comment.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(comment.text)
                                        .font(.callout)
                                }
                                Spacer()
                                Button {
                                    store.deleteIssueComment(issueID: issue.id, commentID: comment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // Add comment
                HStack(spacing: 8) {
                    TextField("添加备注…", text: $newCommentText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let text = newCommentText.trimmingCharacters(in: .whitespaces)
                            if !text.isEmpty {
                                store.addIssueComment(id: issue.id, text: text)
                                newCommentText = ""
                            }
                        }
                    Button("提交") {
                        let text = newCommentText.trimmingCharacters(in: .whitespaces)
                        if !text.isEmpty {
                            store.addIssueComment(id: issue.id, text: text)
                            newCommentText = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newCommentText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Divider()

                // Delete button
                Button {
                    store.deleteIssue(id: issue.id)
                    selectedIssueID = filteredIssues.first?.id
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("删除问题")
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private static let timeFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d HH:mm"
        return fmt
    }()

    @ViewBuilder
    private func statBadge(title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.bold())
                .foregroundStyle(color)
        }
    }

    private func addNewIssue() {
        store.addIssue("新问题", type: .bug, forKey: store.todayKey)
        if let newIssue = store.trackedIssues.last {
            selectedIssueID = newIssue.id
        }
    }

    private func statusColor(_ status: IssueStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .inProgress: return .orange
        case .fixed: return .green
        case .ignored: return .secondary
        }
    }

}
