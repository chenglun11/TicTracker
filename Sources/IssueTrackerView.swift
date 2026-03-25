import SwiftUI

struct IssueTrackerView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .unresolved
    @State private var typeFilter: TypeFilter = .all
    @State private var newTitle = ""
    @State private var newType: IssueType = .bug
    @State private var newAssignee: String?
    @State private var newJiraKey = ""
    @State private var newDepartment: String?
    @State private var showJiraPanel = false
    @State private var jiraRefreshing = false
    @State private var jiraSyncing = false
    @State private var commentTexts: [UUID: String] = [:]
    @State private var expandedTimelines: Set<UUID> = []

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

    private var unlinkedJiraIssues: [JiraIssue] {
        let linkedKeys = Set(store.trackedIssues.compactMap(\.jiraKey))
        return store.filteredJiraIssues.filter { !linkedKeys.contains($0.key) }
    }

    var body: some View {
        HStack(spacing: 0) {
            mainPanel

            if store.jiraConfig.enabled && showJiraPanel {
                Divider()
                jiraPanel
                    .frame(width: 260)
            }
        }
        .frame(minWidth: store.jiraConfig.enabled && showJiraPanel ? 820 : 600, minHeight: 400)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Main Panel

    @ViewBuilder
    private var mainPanel: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                // Stat cards
                HStack(spacing: 12) {
                    statCard(title: "总计", value: "\(store.trackedIssues.count)", color: .blue)
                    statCard(title: "未解决", value: "\(unresolvedCount)", color: unresolvedCount > 0 ? .orange : .green)
                    statCard(title: "已修复", value: "\(store.trackedIssues.filter { $0.status == .fixed }.count)", color: .green)
                    statCard(title: "已忽略", value: "\(store.trackedIssues.filter { $0.status == .ignored }.count)", color: .secondary)
                }
                .padding(.horizontal)

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
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
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
                .padding(.horizontal)

                // Status filter + Search + Jira toggle
                HStack(spacing: 8) {
                    ForEach(StatusFilter.allCases, id: \.self) { filter in
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
                            jiraSyncing = true
                            Task {
                                async let myResult = JiraService.shared.fetchMyIssues()
                                async let reportedResult = JiraService.shared.fetchReportedIssues()
                                _ = await (myResult, reportedResult)
                                await JiraService.shared.syncTrackedIssues()
                                jiraSyncing = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: jiraSyncing ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                                    .rotationEffect(jiraSyncing ? .degrees(360) : .zero)
                                    .animation(jiraSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: jiraSyncing)
                                Text("同步Jira")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(jiraSyncing)

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

                // Add new issue
                HStack(spacing: 8) {
                    // Type picker
                    Picker("", selection: $newType) {
                        ForEach(IssueType.allCases, id: \.self) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    TextField("描述…", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addIssue() }

                    if !store.bugTeamMembers.isEmpty {
                        Picker("", selection: $newAssignee) {
                            Text("未指派").tag(String?.none)
                            ForEach(store.bugTeamMembers, id: \.self) { member in
                                Text(member).tag(String?.some(member))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }

                    if store.jiraConfig.enabled && !store.filteredJiraIssues.isEmpty {
                        Picker("", selection: $newJiraKey) {
                            Text("无关联").tag("")
                            ForEach(store.filteredJiraIssues) { issue in
                                Text("\(issue.key) \(issue.summary)").tag(issue.key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    } else {
                        TextField("Jira 单号", text: $newJiraKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }

                    if newType == .issue {
                        Picker("", selection: $newDepartment) {
                            Text("选择项目").tag(String?.none)
                            ForEach(store.departments, id: \.self) { dept in
                                Text(dept).tag(String?.some(dept))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }

                    Button("添加") { addIssue() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Issue list
            if filteredIssues.isEmpty {
                ContentUnavailableView {
                    Label("无记录", systemImage: "tray")
                } description: {
                    Text(searchText.isEmpty ? "点击上方添加新的问题" : "没有匹配的结果")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(filteredIssues) { issue in
                    issueRow(issue)
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

            if store.filteredJiraIssues.isEmpty {
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
                    let linked = store.filteredJiraIssues.filter { jiraIssue in
                        store.trackedIssues.contains { $0.jiraKey == jiraIssue.key }
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
                    createFromJira(issue)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("创建 Bug")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
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

    // MARK: - Issue Row

    @ViewBuilder
    private func issueRow(_ issue: TrackedIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Type icon
                Menu {
                    ForEach(IssueType.allCases, id: \.self) { type in
                        Button {
                            store.updateIssueType(id: issue.id, type: type)
                        } label: {
                            Label(type.rawValue, systemImage: type.icon)
                        }
                        .disabled(issue.type == type)
                    }
                } label: {
                    Image(systemName: issue.type.icon)
                        .foregroundStyle(issue.type.color)
                        .frame(width: 18)
                }
                .menuIndicator(.hidden)
                .fixedSize()

                // Status menu
                Menu {
                    ForEach(IssueStatus.allCases, id: \.self) { status in
                        Button {
                            store.updateIssueStatus(id: issue.id, status: status)
                        } label: {
                            Label(status.rawValue, systemImage: status.icon)
                        }
                        .disabled(issue.status == status)
                    }
                } label: {
                    Image(systemName: issue.status.icon)
                        .foregroundStyle(statusColor(issue.status))
                        .frame(width: 18)
                }
                .menuIndicator(.hidden)
                .fixedSize()

                // Title + metadata
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .strikethrough(issue.status.isResolved)
                        .foregroundStyle(issue.status.isResolved ? .secondary : .primary)
                    HStack(spacing: 6) {
                        Text(issue.dateKey)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        // Department badge
                        if let dept = issue.department, !dept.isEmpty {
                            Text(dept)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        // Jira key
                        if store.jiraConfig.enabled && !store.filteredJiraIssues.isEmpty {
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
                                if let jira = issue.jiraKey {
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
                            .menuIndicator(.hidden)
                        } else if let jira = issue.jiraKey {
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
                            store.updateIssueAssignee(id: issue.id, assignee: nil)
                        }
                        Divider()
                        ForEach(store.bugTeamMembers, id: \.self) { member in
                            Button(member) {
                                store.updateIssueAssignee(id: issue.id, assignee: member)
                            }
                        }
                    } label: {
                        if let assignee = issue.assignee {
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
                    .menuIndicator(.hidden)
                    .frame(width: 80, alignment: .trailing)
                } else if let assignee = issue.assignee {
                    Text(assignee)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }

                // Delete
                Button {
                    store.deleteIssue(id: issue.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.borderless)
            }

            // Timeline comments
            if !issue.comments.isEmpty {
                let sorted = issue.comments.sorted { $0.createdAt > $1.createdAt }
                let isExpanded = expandedTimelines.contains(issue.id)
                let visible = isExpanded ? sorted : Array(sorted.prefix(2))

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(visible) { comment in
                        HStack(alignment: .top, spacing: 6) {
                            Text(Self.commentTimeFmt.string(from: comment.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(width: 80, alignment: .leading)
                            Text(comment.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                            Spacer()
                            Button {
                                store.deleteIssueComment(issueID: issue.id, commentID: comment.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if sorted.count > 2 && !isExpanded {
                        Button("展开全部 \(sorted.count) 条") {
                            expandedTimelines.insert(issue.id)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.blue)
                    } else if isExpanded && sorted.count > 2 {
                        Button("收起") {
                            expandedTimelines.remove(issue.id)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.blue)
                    }
                }
                .padding(.leading, 46)
            }

            // Add comment
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("添加备注…", text: Binding(
                    get: { commentTexts[issue.id] ?? "" },
                    set: { commentTexts[issue.id] = $0 }
                ))
                .font(.caption)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .onSubmit {
                    let text = (commentTexts[issue.id] ?? "").trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        store.addIssueComment(id: issue.id, text: text)
                        commentTexts[issue.id] = ""
                    }
                }
            }
            .padding(.leading, 46)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private static let commentTimeFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d HH:mm"
        return fmt
    }()

    private func statusColor(_ status: IssueStatus) -> Color {
        switch status {
        case .pending: return .orange
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

    private func addIssue() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let jira = newJiraKey.trimmingCharacters(in: .whitespaces)
        store.addIssue(title, type: newType, forKey: store.todayKey,
                       assignee: newAssignee,
                       jiraKey: jira.isEmpty ? nil : jira,
                       department: newDepartment)
        newTitle = ""
        newJiraKey = ""
        newDepartment = nil
        newAssignee = nil
    }

    private func createFromJira(_ issue: JiraIssue) {
        store.addIssue(issue.summary, type: .bug, forKey: store.todayKey, jiraKey: issue.key)
    }
}
