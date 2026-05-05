import SwiftUI

struct IssueTrackerView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .unresolved
    @State private var typeFilter: TypeFilter = .all
    @State private var selectedIssueID: UUID?
    @State private var jiraSyncing = false
    @State private var newCommentText = ""
    @State private var sendingFeishu = false
    @State private var sendResult: String?
    @State private var sendSuccess = false
    @State private var editingTitle = ""
    @State private var isEditingTitle = false
    @State private var isEditingTime = false
    @State private var saveState = AutoSaveState()
    @State private var showJiraPicker = false
    @State private var jiraSearchText = ""
    @State private var showFeishuTaskPicker = false
    @State private var feishuTaskSearchText = ""
    @State private var feishuTaskCandidates: [FeishuTaskCandidate] = []
    @State private var feishuTasklists: [FeishuVisibleTasklist] = []
    @State private var selectedFeishuTasklist = ""
    @State private var feishuTaskLoading = false
    @State private var feishuTaskError: String?
    @State private var creatingFeishuTaskIssueID: UUID?
    @State private var feishuSyncInProgress = false
    @State private var syncTimer: Timer?

    private enum StatusFilter: String, CaseIterable {
        case all = "全部"
        case unresolved = "未解决"
        case observing = "观测中"
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
        var issues = store.visibleTrackedIssues

        if let type = typeFilter.issueType {
            issues = issues.filter { $0.type == type }
        }

        switch statusFilter {
        case .all: break
        case .unresolved: issues = issues.filter { !$0.status.isResolved && $0.status != .observing }
        case .observing: issues = issues.filter { $0.status == .observing }
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
        store.visibleTrackedIssues.filter { !$0.status.isResolved && $0.status != .observing }.count
    }

    private var selectedIssue: TrackedIssue? {
        guard let id = selectedIssueID else { return nil }
        return store.visibleTrackedIssues.first { $0.id == id }
    }

    private var canSyncFeishuTasks: Bool {
        switch store.feishuBotConfig.taskAuthMode {
        case .botTenant:
            return !store.feishuBotConfig.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && FeishuBotService.loadAppSecret()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .userOAuth:
            return FeishuOAuthService.shared.isAuthorized
        }
    }

    var body: some View {
        HSplitView {
            // Left sidebar
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    // Stats
                    HStack(spacing: 8) {
                        statBadge(title: "总计", value: store.visibleTrackedIssues.count, color: .blue)
                        statBadge(title: "未解决", value: unresolvedCount, color: unresolvedCount > 0 ? .orange : .green)
                    }
                    Spacer()
                    if feishuSyncInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .help("正在同步飞书任务状态…")
                    }
                    Button {
                        syncFeishuBoundTasks()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("同步任务")
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.regular)
                    .disabled(feishuSyncInProgress || !canSyncFeishuTasks)
                    .help(store.feishuBotConfig.taskAuthMode == .botTenant ? "使用 Bot / 应用身份同步飞书任务" : "使用用户 OAuth 同步飞书任务")
                    Button {
                        sendToFeishu()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text(sendingFeishu ? "发送中…" : "发送完整日报")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(sendingFeishu || store.feishuBotConfig.webhooks.isEmpty)
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

                if let result = sendResult {
                    HStack {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(sendSuccess ? .green : .red)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }

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
            syncFeishuBoundTasks()
            startSyncTimer()
            if selectedIssueID == nil, let first = filteredIssues.first {
                selectedIssueID = first.id
            }
        }
        .onDisappear {
            stopSyncTimer()
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: selectedIssueID) {
            isEditingTitle = false
            isEditingTime = false
            newCommentText = ""
            sendResult = nil
        }
        .onChange(of: store.feishuBotConfig.taskPollingInterval) { _, _ in
            startSyncTimer()
        }
        .onChange(of: searchText) {
            if let id = selectedIssueID, !filteredIssues.contains(where: { $0.id == id }) {
                selectedIssueID = filteredIssues.first?.id
            }
        }
        .autoSaveIndicator(saveState)
    }

    // MARK: - List Row

    @ViewBuilder
    private func listRow(_ issue: TrackedIssue) -> some View {
        HStack(spacing: 6) {
            Image(systemName: issue.type.icon)
                .font(.system(size: 10))
                .frame(width: 12)
                .foregroundStyle(issue.type.color)
            Image(systemName: issue.status.icon)
                .font(.system(size: 10))
                .frame(width: 12)
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
            if issue.isEscalated {
                Text("Escalated")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Color.red, in: Capsule())
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
        let isReadOnly = issue.source.isReadOnly
        let isStatusLocked = issue.feishuTaskGuid != nil
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
                            guard !isReadOnly else { return }
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
                    .disabled(isReadOnly || isStatusLocked)

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
                    .disabled(isReadOnly)

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
                        .disabled(isReadOnly)
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
                        .disabled(isReadOnly)
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
                        .disabled(isReadOnly)
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

                            Toggle(isOn: Binding(
                                get: { issue.isEscalated },
                                set: {
                                    store.updateIssueEscalated(id: issue.id, isEscalated: $0)
                                    saveState.debouncedSave()
                                }
                            )) {
                                Text("Escalated")
                                    .font(.caption)
                            }
                            .toggleStyle(.checkbox)
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

                    linkedTaskControl(issue)
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
                        if !isReadOnly {
                            Button {
                                isEditingTime = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
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
                                if comment.jiraCommentId == nil && !isReadOnly {
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
                if !isReadOnly {
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
                }

                Divider()

                // Delete button
                if !isReadOnly {
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
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("此问题来源于飞书任务，平台仅做同步与状态监测，不支持直接编辑或删除。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func linkedTaskControl(_ issue: TrackedIssue) -> some View {
        HStack(spacing: 8) {
            Text("飞书任务")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("飞书任务 GUID", text: Binding(
                get: { issue.feishuTaskGuid ?? "" },
                set: {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.updateIssueFeishuTaskGuid(id: issue.id, guid: trimmed.isEmpty ? nil : trimmed)
                    saveState.debouncedSave()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320, maxWidth: 520)

            Button {
                loadFeishuTasks()
                showFeishuTaskPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text(issue.feishuTaskGuid?.isEmpty == false ? "更换任务" : "关联任务")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $showFeishuTaskPicker, arrowEdge: .bottom) {
                feishuTaskPickerPopover(issue: issue)
            }

            if let guid = issue.feishuTaskGuid, !guid.isEmpty {
                Text("状态由飞书同步")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    openFeishuTask(guid: guid)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("在飞书中打开任务")
                Button("解绑") {
                    store.updateIssueFeishuTaskGuid(id: issue.id, guid: nil)
                    saveState.triggerSave()
                }
                .controlSize(.small)
            } else {
                Button(creatingFeishuTaskIssueID == issue.id ? "创建中…" : "创建飞书任务") {
                    createFeishuTask(for: issue)
                }
                .controlSize(.small)
                .disabled(creatingFeishuTaskIssueID != nil)
                .help("用 Bot / 应用身份创建飞书任务；如未配置 Bot 清单 GUID，会自动创建 Bot 专用清单")
            }
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

    @ViewBuilder
    private func feishuTaskPickerPopover(issue: TrackedIssue) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("任务清单")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("任务清单", selection: $selectedFeishuTasklist) {
                    ForEach(visibleFeishuTasklists(), id: \.guid) { tl in
                        Text("\(tl.name)  ·  \(tl.guid)").tag(tl.guid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .onChange(of: selectedFeishuTasklist) { _, value in
                loadFeishuTasks(tasklistGUID: value)
            }

            TextField("搜索飞书任务…", text: $feishuTaskSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            if let feishuTaskError {
                Text(feishuTaskError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }

            let query = feishuTaskSearchText.lowercased()
            let filtered = feishuTaskCandidates.filter { task in
                query.isEmpty ||
                task.guid.lowercased().contains(query) ||
                task.summary.lowercased().contains(query)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { task in
                        Button {
                            store.updateIssueFeishuTaskGuid(id: issue.id, guid: task.guid)
                            applyFeishuTaskCompletionStatus(issueID: issue.id, candidate: task)
                            saveState.triggerSave()
                            showFeishuTaskPicker = false
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.summary.isEmpty ? task.guid : task.summary)
                                        .lineLimit(2)
                                    Text(task.guid)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                if let completedAt = task.completedAt, completedAt != "0", !completedAt.isEmpty {
                                    Text("已完成")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }

                    if feishuTaskLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else if filtered.isEmpty {
                        Text("无匹配任务")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 760)
        .task {
            if feishuTaskCandidates.isEmpty {
                loadFeishuTasks(tasklistGUID: selectedFeishuTasklist.isEmpty ? nil : selectedFeishuTasklist)
            }
        }
    }

    private func visibleFeishuTasklists() -> [FeishuVisibleTasklist] {
        if !feishuTasklists.isEmpty { return feishuTasklists }
        let guid = store.feishuBotConfig.tasklistGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        return guid.isEmpty ? [] : [FeishuVisibleTasklist(guid: guid, name: "默认清单")]
    }

    private func loadFeishuTasks(tasklistGUID: String? = nil) {
        feishuTaskLoading = true
        feishuTaskError = nil
        Task {
            do {
                if feishuTasklists.isEmpty {
                    let visible = try await FeishuTaskService.shared.listVisibleTasklistsForPicker(store: store)
                    let fallback = store.feishuBotConfig.tasklistGUID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if visible.isEmpty, !fallback.isEmpty {
                        feishuTasklists = [FeishuVisibleTasklist(guid: fallback, name: "默认清单")]
                    } else {
                        feishuTasklists = visible
                    }
                    if selectedFeishuTasklist.isEmpty {
                        selectedFeishuTasklist = feishuTasklists.first?.guid ?? ""
                    }
                }
                let target = tasklistGUID?.isEmpty == false ? tasklistGUID : (selectedFeishuTasklist.isEmpty ? nil : selectedFeishuTasklist)
                let result = try await FeishuTaskService.shared.listTasks(store: store, tasklistGUID: target)
                if selectedFeishuTasklist.isEmpty {
                    selectedFeishuTasklist = result.selected
                }
                feishuTaskCandidates = result.tasks
                feishuTaskLoading = false
            } catch {
                feishuTaskError = error.localizedDescription
                feishuTaskCandidates = []
                feishuTaskLoading = false
            }
        }
    }

    private func createFeishuTask(for issue: TrackedIssue) {
        creatingFeishuTaskIssueID = issue.id
        Task {
            do {
                let task = try await FeishuTaskService.shared.createTaskForIssue(store: store, issue: issue)
                store.updateIssueFeishuTaskGuid(id: issue.id, guid: task.guid)
                applyFeishuTaskCompletionStatus(issueID: issue.id, candidate: task)
                saveState.triggerSave()
            } catch {
                DevLog.shared.error("IssueTracker", "创建飞书任务失败 #\(issue.issueNumber): \(error.localizedDescription)")
            }
            creatingFeishuTaskIssueID = nil
        }
    }

    private func openFeishuTask(guid: String) {
        guard let url = URL(string: "https://applink.feishu.cn/client/todo/detail?guid=\(guid)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyFeishuTaskCompletionStatus(issueID: UUID, candidate: FeishuTaskCandidate) {
        let isCompleted = (candidate.completedAt ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
            && candidate.completedAt != "0"
        if isCompleted {
            store.updateIssueStatus(id: issueID, status: .fixed)
        } else if let issue = store.trackedIssues.first(where: { $0.id == issueID }), issue.status.isResolved {
            store.updateIssueStatus(id: issueID, status: .pending)
        }
    }

    private func syncFeishuBoundTasks() {
        guard canSyncFeishuTasks else { return }
        let boundGUIDs = store.trackedIssues.compactMap { issue -> String? in
            guard let guid = issue.feishuTaskGuid, !guid.isEmpty else { return nil }
            return guid
        }
        feishuSyncInProgress = true
        Task {
            do {
                let boundResult = try await FeishuTaskService.shared.syncBoundTasks(store: store, boundGUIDs: boundGUIDs)
                for guid in boundResult.deletedGUIDs {
                    if let issue = store.trackedIssues.first(where: { $0.feishuTaskGuid == guid }) {
                        store.markIssueFeishuTaskDeleted(id: issue.id, guid: guid)
                        DevLog.shared.info("IssueTracker", "飞书任务不存在，已保留本地问题并标记已忽略 #\(issue.issueNumber) [guid=\(guid)]")
                    }
                }
                for (guid, task) in boundResult.tasks {
                    if let issue = store.trackedIssues.first(where: { $0.feishuTaskGuid == guid }) {
                        applyFeishuTaskCompletionStatus(issueID: issue.id, candidate: task)
                    }
                }

                do {
                    let tasklistResult = try await FeishuTaskService.shared.listTasks(store: store)
                    var importedCount = 0
                    for task in tasklistResult.tasks {
                        if store.addIssueFromFeishuTask(task, forKey: store.todayKey) {
                            importedCount += 1
                        }
                    }
                    DevLog.shared.info("IssueTracker", "飞书任务清单同步完成：检查 \(tasklistResult.tasks.count) 个任务，新增 \(importedCount) 个本地问题")
                } catch {
                    DevLog.shared.error("IssueTracker", "同步飞书任务清单失败: \(error.localizedDescription)")
                }
                saveState.triggerSave()
            } catch {
                DevLog.shared.error("IssueTracker", "同步飞书任务失败: \(error.localizedDescription)")
            }
            feishuSyncInProgress = false
        }
    }

    private func startSyncTimer() {
        stopSyncTimer()
        let minutes = max(store.feishuBotConfig.taskPollingInterval, 1)
        DevLog.shared.info("IssueTracker", "飞书任务单向同步定时器已启动，每 \(minutes) 分钟检查一次")
        syncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { _ in
            Task { @MainActor in
                guard NSApp.isActive, !NSApp.isHidden else { return }
                syncFeishuBoundTasks()
            }
        }
    }

    private func stopSyncTimer() {
        if syncTimer != nil {
            DevLog.shared.info("IssueTracker", "飞书任务单向同步定时器已停止")
        }
        syncTimer?.invalidate()
        syncTimer = nil
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

    private func sendToFeishu() {
        sendingFeishu = true
        sendResult = nil
        Task {
            let result = await FeishuBotService.shared.sendDirectNow(store: store)
            sendResult = result.message
            sendSuccess = result.success
            if result.success {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                store.feishuBotConfig.lastSentDateTime = fmt.string(from: Date())
                saveState.triggerSave()
            }
            sendingFeishu = false
        }
    }

    private func statusColor(_ status: IssueStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .inProgress: return .orange
        case .testing: return .purple
        case .scheduled: return .teal
        case .observing: return .blue
        case .fixed: return .green
        case .ignored: return .secondary
        }
    }

}
