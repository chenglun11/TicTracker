import SwiftUI

struct IssueTrackerView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .unresolved
    @State private var typeFilter: TypeFilter = .all
    @State private var selectedIssueID: UUID?
    @State private var jiraSyncing = false
    @State private var newCommentText = ""
    @State private var editingTitle = ""
    @State private var isEditingTitle = false
    @State private var isEditingTime = false
    @State private var saveState = AutoSaveState()
    @State private var showJiraPicker = false
    @State private var jiraSearchText = ""

    private enum StatusFilter: String, CaseIterable {
        case all = "全部"
        case unresolved = "未解决"
        case fixed = "已修复"
        case ignored = "已忽略"
    }

    private enum TypeFilter: String, CaseIterable {
        case all = "全部"
        case bug = "Bug"
        case hotfix = "Feature"
        case issue = "Support"

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
                                saveState.triggerSave()
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
                    Label("选择问题查看详情", systemImage: "exclamationmark.triangle")
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
        .onChange(of: selectedIssueID) {
            isEditingTitle = false
            isEditingTime = false
            newCommentText = ""
        }
        .onChange(of: searchText) {
            if let id = selectedIssueID, !filteredIssues.contains(where: { $0.id == id }) {
                selectedIssueID = filteredIssues.first?.id
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .autoSaveIndicator(saveState)
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
            if issue.issueNumber > 0 {
                Text("#\(issue.issueNumber)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(issue.title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            if issue.hasDevActivity {
                Text("开发中")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Color.green, in: Capsule())
            }
            if let assignee = issue.assignee {
                Text(assignee)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
            if issue.source != .manual {
                Text(issue.source.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 8) {
                    if isEditingTitle {
                        TextEditor(text: $editingTitle)
                            .font(.title2.bold())
                            .frame(height: 100)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if issue.issueNumber > 0 {
                                    Text("#\(issue.issueNumber)")
                                        .font(.title3.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(issue.title)
                                    .font(.title2.bold())
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                        .onTapGesture {
                            editingTitle = issue.title
                            isEditingTitle = true
                        }
                    }

                    if isEditingTitle {
                        HStack {
                            Button("保存") {
                                store.updateIssueTitle(id: issue.id, title: editingTitle)
                                isEditingTitle = false
                                saveState.triggerSave()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("取消") {
                                isEditingTitle = false
                            }
                            .controlSize(.small)
                        }
                    }
                }

                // Type, Status, Assignee, Department
                HStack(spacing: 12) {
                    Picker("类型", selection: Binding(
                        get: { issue.type },
                        set: {
                            store.updateIssueType(id: issue.id, type: $0)
                            saveState.triggerSave()
                        }
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
                                saveState.triggerSave()
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
                                saveState.triggerSave()
                            }
                            Divider()
                            ForEach(store.bugTeamMembers, id: \.self) { member in
                                Button(member) {
                                    store.updateIssueAssignee(id: issue.id, assignee: member)
                                    saveState.triggerSave()
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
                            set: {
                                store.updateIssueDepartment(id: issue.id, department: $0)
                                saveState.triggerSave()
                            }
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

                // 来源 & 工单关联
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("来源")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { issue.source },
                            set: {
                                store.updateIssueSource(id: issue.id, source: $0)
                                saveState.triggerSave()
                            }
                        )) {
                            ForEach(IssueSource.allCases, id: \.self) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    switch issue.source {
                    case .jira:
                        HStack(spacing: 8) {
                            TextField("Jira Key", text: Binding(
                                get: { issue.jiraKey ?? "" },
                                set: {
                                    store.updateIssueJiraKey(id: issue.id, jiraKey: $0.isEmpty ? nil : $0)
                                    saveState.debouncedSave()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)

                            if !store.filteredJiraIssues.isEmpty {
                                Button {
                                    jiraSearchText = ""
                                    showJiraPicker.toggle()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "link")
                                        Text("关联工单")
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .popover(isPresented: $showJiraPicker, arrowEdge: .bottom) {
                                    jiraPickerPopover(issue: issue)
                                }
                            }

                            if let jiraKey = issue.jiraKey, !jiraKey.isEmpty {
                                Button {
                                    openJiraInBrowser(jiraKey)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.borderless)
                                .help("在浏览器中打开 Jira 工单")
                            }
                        }
                    case .meta:
                        HStack(spacing: 8) {
                            TextField("工单链接", text: Binding(
                                get: { issue.ticketURL ?? "" },
                                set: {
                                    store.updateIssueTicketURL(id: issue.id, ticketURL: $0.isEmpty ? nil : $0)
                                    saveState.debouncedSave()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)

                            if let url = issue.ticketURL, !url.isEmpty {
                                Button {
                                    openURL(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.borderless)
                                .help("在浏览器中打开")
                            }
                        }
                    case .feishu:
                        HStack(spacing: 8) {
                            TextField("飞书文档链接", text: Binding(
                                get: { issue.ticketURL ?? "" },
                                set: {
                                    store.updateIssueTicketURL(id: issue.id, ticketURL: $0.isEmpty ? nil : $0)
                                    saveState.debouncedSave()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)

                            if let url = issue.ticketURL, !url.isEmpty {
                                Button {
                                    openURL(url)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.borderless)
                                .help("在浏览器中打开")
                            }
                        }
                    case .manual:
                        EmptyView()
                    }
                }

                Divider()

                // Timestamps
                HStack(spacing: 16) {
                    if isEditingTime {
                        DatePicker("创建时间", selection: Binding(
                            get: { issue.createdAt },
                            set: {
                                store.updateIssueCreatedAt(id: issue.id, date: $0)
                                saveState.debouncedSave()
                            }
                        ))
                        .font(.callout)

                        DatePicker("更新时间", selection: Binding(
                            get: { issue.updatedAt ?? issue.createdAt },
                            set: {
                                store.updateIssueUpdatedAt(id: issue.id, date: $0)
                                saveState.debouncedSave()
                            }
                        ))
                        .font(.callout)

                        Button("完成") { isEditingTime = false }
                            .controlSize(.small)
                    } else {
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
                        Button {
                            isEditingTime = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
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
                                    HStack(spacing: 4) {
                                        Text(Self.timeFmt.string(from: comment.createdAt))
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        commentSourceBadge(comment)
                                    }
                                    Text(comment.text)
                                        .font(.callout)
                                }
                                Spacer()
                                if comment.jiraCommentId == nil {
                                    Button {
                                        store.deleteIssueComment(issueID: issue.id, commentID: comment.id)
                                        saveState.triggerSave()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.borderless)
                                }
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
                                saveState.triggerSave()
                            }
                        }
                    Button("提交") {
                        let text = newCommentText.trimmingCharacters(in: .whitespaces)
                        if !text.isEmpty {
                            store.addIssueComment(id: issue.id, text: text)
                            newCommentText = ""
                            saveState.triggerSave()
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
                    saveState.triggerSave()
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
    private func commentSourceBadge(_ comment: IssueComment) -> some View {
        if comment.jiraCommentId != nil {
            // Jira 同步的原生评论
            Text("Jira")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.blue)
        } else if comment.text.hasPrefix("[Jira]") {
            // Jira 状态变更等系统自动生成的评论
            Text("Jira 同步")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.blue.opacity(0.7))
        } else {
            // 用户手动添加的本地评论
            Text("本地")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.secondary)
        }
    }

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

    @ViewBuilder
    private func jiraPickerPopover(issue: TrackedIssue) -> some View {
        VStack(spacing: 0) {
            TextField("搜索工单…", text: $jiraSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            let query = jiraSearchText.lowercased()
            let filtered = store.filteredJiraIssues.filter { jiraIssue in
                query.isEmpty ||
                jiraIssue.key.lowercased().contains(query) ||
                jiraIssue.summary.lowercased().contains(query)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Button {
                        store.updateIssueJiraKey(id: issue.id, jiraKey: nil)
                        saveState.triggerSave()
                        showJiraPicker = false
                    } label: {
                        Text("无关联")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Divider()

                    ForEach(filtered) { jiraIssue in
                        Button {
                            store.updateIssueJiraKey(id: issue.id, jiraKey: jiraIssue.key)
                            saveState.triggerSave()
                            showJiraPicker = false
                        } label: {
                            HStack(spacing: 6) {
                                Text(jiraIssue.key)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.blue)
                                Text(jiraIssue.summary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }

                    if filtered.isEmpty {
                        Text("无匹配结果")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 340)
    }

    private func openJiraInBrowser(_ key: String) {
        let base = store.jiraConfig.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/browse/\(key)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func addNewIssue() {
        store.addIssue("新问题", type: .bug, forKey: store.todayKey)
        if let newIssue = store.trackedIssues.last {
            selectedIssueID = newIssue.id
        }
        saveState.triggerSave()
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
