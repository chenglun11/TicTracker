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
    @State private var linearSyncing = false
    @State private var showLinearPicker = false
    @State private var linearSearchText = ""
    @State private var linearSearchResults: [LinearIssue] = []
    @State private var linearMyIssues: [LinearIssue] = []
    @State private var linearPickerLoading = false
    @State private var linearPickerTab: LinearPickerTab = .myIssues

    private enum LinearPickerTab: String, CaseIterable {
        case myIssues = "我的 Issues"
        case search = "搜索"
    }

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
                "#\($0.issueNumber)".contains(query) ||
                "\($0.issueNumber)".contains(query) ||
                $0.title.lowercased().contains(query) ||
                ($0.assignee?.lowercased().contains(query) ?? false) ||
                ($0.jiraKey?.lowercased().contains(query) ?? false) ||
                ($0.ticketURL?.lowercased().contains(query) ?? false) ||
                ($0.feishuTaskGuid?.lowercased().contains(query) ?? false) ||
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
            sidebar
            detailPane
        }
        .onAppear {
            syncFeishuBoundTasks()
            if selectedIssueID == nil, let first = filteredIssues.first {
                selectedIssueID = first.id
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: selectedIssueID) {
            isEditingTitle = false
            isEditingTime = false
            newCommentText = ""
            sendResult = nil
        }
        .task(id: store.feishuBotConfig.taskPollingInterval) {
            await runFeishuSyncLoop()
        }
        .onChange(of: searchText) {
            if let id = selectedIssueID, !filteredIssues.contains(where: { $0.id == id }) {
                selectedIssueID = filteredIssues.first?.id
            }
        }
        .onChange(of: typeFilter) {
            keepSelectionVisible()
        }
        .onChange(of: statusFilter) {
            keepSelectionVisible()
        }
        .autoSaveIndicator(saveState)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()
            filterBar
            Divider()
            issueList
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("问题追踪")
                        .font(.headline)
                    HStack(spacing: 10) {
                        statBadge(title: "总计", value: store.visibleTrackedIssues.count, color: .blue)
                        statBadge(title: "未解决", value: unresolvedCount, color: unresolvedCount > 0 ? .orange : .green)
                    }
                }

                Spacer(minLength: 8)

                if feishuSyncInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在同步飞书任务状态…")
                }

                Button {
                    addNewIssue()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("新增问题")
            }

            HStack(spacing: 6) {
                Button {
                    syncFeishuBoundTasks()
                } label: {
                    Label("同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(feishuSyncInProgress || !canSyncFeishuTasks)
                .help(store.feishuBotConfig.taskAuthMode == .botTenant ? "使用 Bot / 应用身份同步飞书任务" : "使用用户 OAuth 同步飞书任务")

                Button {
                    sendToFeishu()
                } label: {
                    Label(sendingFeishu ? "发送中" : "日报", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sendingFeishu || store.feishuBotConfig.webhooks.isEmpty)
                .help("发送完整日报")

                if store.jiraConfig.enabled {
                    Button {
                        syncJiraIssues()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(jiraSyncing ? .degrees(360) : .zero)
                            .animation(jiraSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: jiraSyncing)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(jiraSyncing)
                    .help("同步 Jira 入口")
                }

                if store.linearConfig.enabled {
                    Button {
                        syncLinearIssues()
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .rotationEffect(linearSyncing ? .degrees(360) : .zero)
                            .animation(linearSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: linearSyncing)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(linearSyncing)
                    .help("同步 Linear")
                }

                Spacer(minLength: 0)
            }

            if let result = sendResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(sendSuccess ? .green : .red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索编号、标题、负责人、备注", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 5) {
                Text("类型")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("类型", selection: $typeFilter) {
                    ForEach(TypeFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("状态")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("状态", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var issueList: some View {
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

    @ViewBuilder
    private func listRow(_ issue: TrackedIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if issue.issueNumber > 0 {
                    Text("#\(issue.issueNumber)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(issue.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Image(systemName: issue.status.icon)
                    .font(.caption)
                    .foregroundStyle(statusColor(issue.status))
                    .help(issue.status.rawValue)
            }

            HStack(spacing: 5) {
                issueTag(issue.type.rawValue, systemImage: issue.type.icon, color: issue.type.color)
                issueTag(issue.status.rawValue, systemImage: nil, color: statusColor(issue.status))

                if let assignee = issue.assignee, !assignee.isEmpty {
                    issueTag(assignee, systemImage: "person", color: .blue)
                }

                Spacer(minLength: 2)

                Text(issue.dateKey)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if issue.source != .manual || issue.hasDevActivity || issue.isEscalated || issue.feishuTaskGuid?.isEmpty == false {
                HStack(spacing: 5) {
                    if issue.source != .manual {
                        issueTag(issue.source.rawValue, systemImage: "link", color: .secondary)
                    }
                    if issue.hasDevActivity {
                        issueTag("开发中", systemImage: "hammer", color: .green)
                    }
                    if issue.isEscalated {
                        issueTag("Escalated", systemImage: "exclamationmark.arrow.triangle.2.circlepath", color: .red)
                    }
                    if issue.feishuTaskGuid?.isEmpty == false {
                        issueTag("飞书任务", systemImage: "checklist", color: .indigo)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Issue Detail

    private var detailPane: some View {
        Group {
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
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func issueDetail(_ issue: TrackedIssue) -> some View {
        let isReadOnly = issue.source.isReadOnly

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                issueSummaryHeader(issue, isReadOnly: isReadOnly)
                primaryFieldsSection(issue, isReadOnly: isReadOnly)
                externalLinksSection(issue, isReadOnly: isReadOnly)
                commentsSection(issue, isReadOnly: isReadOnly)
                metadataAndDangerSection(issue, isReadOnly: isReadOnly)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func issueSummaryHeader(_ issue: TrackedIssue, isReadOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if issue.issueNumber > 0 {
                    Text("#\(issue.issueNumber)")
                        .font(.title3.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                summaryChip(issue.type.rawValue, systemImage: issue.type.icon, color: issue.type.color)
                summaryChip(issue.status.rawValue, systemImage: issue.status.icon, color: statusColor(issue.status))

                Spacer(minLength: 0)
            }

            if isEditingTitle {
                TextEditor(text: $editingTitle)
                    .font(.title2.weight(.semibold))
                    .frame(minHeight: 80, maxHeight: 120)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                HStack(spacing: 8) {
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
            } else {
                Text(issue.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isReadOnly else { return }
                        editingTitle = issue.title
                        isEditingTitle = true
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    summaryChip(issue.assignee ?? "未指派", systemImage: "person", color: .blue)
                    if let department = issue.department, !department.isEmpty {
                        summaryChip(department, systemImage: "folder", color: .teal)
                    }
                    if issue.source != .manual {
                        summaryChip(displaySourceName(issue.source), systemImage: "link", color: .gray)
                    }
                    Spacer(minLength: 0)
                }

                if issue.hasDevActivity || issue.isEscalated || issue.feishuTaskGuid?.isEmpty == false {
                    HStack(spacing: 6) {
                        if issue.hasDevActivity {
                            summaryChip("开发中", systemImage: "hammer", color: .green)
                        }
                        if issue.isEscalated {
                            summaryChip("Escalated", systemImage: "exclamationmark.arrow.triangle.2.circlepath", color: .red)
                        }
                        if issue.feishuTaskGuid?.isEmpty == false {
                            summaryChip("飞书任务", systemImage: "checklist", color: .indigo)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func primaryFieldsSection(_ issue: TrackedIssue, isReadOnly: Bool) -> some View {
        workbenchSection("主信息", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                fieldRow("状态", systemImage: "circle.dashed") {
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
                        fieldButtonLabel(issue.status.rawValue, systemImage: issue.status.icon, color: statusColor(issue.status))
                    }
                    .disabled(isReadOnly)
                }

                fieldRow("负责人", systemImage: "person") {
                    if store.bugTeamMembers.isEmpty {
                        mutedValue(issue.assignee ?? "未配置负责人")
                    } else {
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
                            fieldButtonLabel(issue.assignee ?? "未指派", systemImage: "person", color: .blue)
                        }
                        .disabled(isReadOnly)
                    }
                }

                fieldRow("类型", systemImage: issue.type.icon) {
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
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180, alignment: .leading)
                    .disabled(isReadOnly)
                }

                fieldRow("项目", systemImage: "folder") {
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
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                        .disabled(isReadOnly)
                    } else if let department = issue.department, !department.isEmpty {
                        mutedValue(department)
                    } else {
                        mutedValue("仅 Support 类型需要项目")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func externalLinksSection(_ issue: TrackedIssue, isReadOnly: Bool) -> some View {
        workbenchSection("关联信息", systemImage: "link") {
            VStack(alignment: .leading, spacing: 12) {
                fieldRow("来源", systemImage: "tray.and.arrow.down") {
                    Picker("来源", selection: Binding(
                        get: { issue.source },
                        set: {
                            store.updateIssueSource(id: issue.id, source: $0)
                            saveState.triggerSave()
                        }
                    )) {
                        ForEach(IssueSource.allCases, id: \.self) { source in
                            Text(displaySourceName(source)).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(isReadOnly)
                }

                Divider()

                switch issue.source {
                case .jira:
                    jiraLinkFields(issue)
                case .meta:
                    metaLinkFields(issue)
                case .feishu:
                    feishuDocFields(issue)
                case .linear:
                    linearLinkFields(issue)
                case .manual:
                    fieldRow("外部工单", systemImage: "link.slash") {
                        mutedValue("未关联")
                    }
                }

                Divider()

                linkedTaskControl(issue)
            }
        }
    }

    @ViewBuilder
    private func jiraLinkFields(_ issue: TrackedIssue) -> some View {
        fieldRow("历史入口", systemImage: "number") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("外部工单 Key", text: Binding(
                    get: { issue.jiraKey ?? "" },
                    set: {
                        store.updateIssueJiraKey(id: issue.id, jiraKey: $0.isEmpty ? nil : $0)
                        saveState.debouncedSave()
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

                HStack(spacing: 8) {
                    if !store.filteredJiraIssues.isEmpty {
                        Button {
                            jiraSearchText = ""
                            showJiraPicker.toggle()
                        } label: {
                            Label("关联入口", systemImage: "link")
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
                            Label("打开", systemImage: "arrow.up.forward.square")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("在浏览器中打开历史入口")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metaLinkFields(_ issue: TrackedIssue) -> some View {
        fieldRow("Meta", systemImage: "link") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("工单链接", text: Binding(
                    get: { issue.ticketURL ?? "" },
                    set: {
                        store.updateIssueTicketURL(id: issue.id, ticketURL: $0.isEmpty ? nil : $0)
                        saveState.debouncedSave()
                    }
                ))
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    if let url = issue.ticketURL, !url.isEmpty {
                        Button {
                            openURL(url)
                        } label: {
                            Label("打开", systemImage: "arrow.up.forward.square")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
            }
        }
    }

    @ViewBuilder
    private func feishuDocFields(_ issue: TrackedIssue) -> some View {
        fieldRow("飞书文档", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 8) {
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
                        Label("打开", systemImage: "arrow.up.forward.square")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("在浏览器中打开")
                }
            }
        }
    }

    @ViewBuilder
    private func linearLinkFields(_ issue: TrackedIssue) -> some View {
        fieldRow("Linear", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 8) {
                if let key = issue.linearKey, !key.isEmpty {
                    HStack {
                        Text(key)
                            .font(.body.monospaced())
                        Spacer()
                        if let url = issue.linearUrl, !url.isEmpty {
                            Button {
                                openURL(url)
                            } label: {
                                Label("打开", systemImage: "arrow.up.forward.square")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("在浏览器中打开 Linear")
                        }
                    }

                    Button {
                        store.updateIssueLinearLink(id: issue.id, issueId: nil, key: nil, url: nil)
                        saveState.triggerSave()
                    } label: {
                        Label("解除关联", systemImage: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    HStack(spacing: 8) {
                        Text("未关联 Linear Issue")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        Button {
                            linearSearchText = ""
                            linearSearchResults = []
                            linearPickerTab = .myIssues
                            showLinearPicker = true
                            loadLinearMyIssues()
                        } label: {
                            Label("关联 Linear Issue", systemImage: "link")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .popover(isPresented: $showLinearPicker, arrowEdge: .bottom) {
                            linearPickerPopover(issue: issue)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func linkedTaskControl(_ issue: TrackedIssue) -> some View {
        fieldRow("飞书任务", systemImage: "checklist") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("飞书任务 GUID", text: Binding(
                    get: { issue.feishuTaskGuid ?? "" },
                    set: {
                        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.updateIssueFeishuTaskGuid(id: issue.id, guid: trimmed.isEmpty ? nil : trimmed)
                        saveState.debouncedSave()
                    }
                ))
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button {
                        loadFeishuTasks()
                        showFeishuTaskPicker = true
                    } label: {
                        Label(issue.feishuTaskGuid?.isEmpty == false ? "更换任务" : "关联任务", systemImage: "link")
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
        }
    }

    @ViewBuilder
    private func commentsSection(_ issue: TrackedIssue, isReadOnly: Bool) -> some View {
        workbenchSection("沟通记录", systemImage: "text.bubble") {
            VStack(alignment: .leading, spacing: 10) {
                if !isReadOnly {
                    HStack(spacing: 8) {
                        TextField("添加备注…", text: $newCommentText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                submitComment(issue)
                            }

                        Button {
                            submitComment(issue)
                        } label: {
                            Label("提交", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newCommentText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if issue.comments.isEmpty {
                    Text("暂无备注")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(issue.comments.sorted { $0.createdAt > $1.createdAt }) { comment in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Text(Self.timeFmt.string(from: comment.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    commentSourceBadge(comment)
                                }
                                Text(comment.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }

                            Spacer(minLength: 8)

                            if comment.jiraCommentId == nil && !isReadOnly {
                                Button {
                                    store.deleteIssueComment(issueID: issue.id, commentID: comment.id)
                                    saveState.triggerSave()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.borderless)
                                .help("删除备注")
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataAndDangerSection(_ issue: TrackedIssue, isReadOnly: Bool) -> some View {
        workbenchSection("系统信息", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 12) {
                if isEditingTime {
                    VStack(alignment: .leading, spacing: 10) {
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

                        Button("完成") {
                            isEditingTime = false
                        }
                        .controlSize(.small)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        metadataItem(title: "创建时间", value: Self.timeFmt.string(from: issue.createdAt))
                        if let updated = issue.updatedAt {
                            metadataItem(title: "更新时间", value: Self.timeFmt.string(from: updated))
                        }
                        Spacer(minLength: 0)
                        if !isReadOnly {
                            Button {
                                isEditingTime = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("编辑时间")
                        }
                    }
                }

                Divider()

                if !isReadOnly {
                    Button {
                        store.deleteIssue(id: issue.id)
                        selectedIssueID = filteredIssues.first?.id
                        saveState.triggerSave()
                    } label: {
                        Label("删除问题", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
        }
    }

    // MARK: - Helpers

    private static let timeFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d HH:mm"
        return fmt
    }()

    @ViewBuilder
    private func workbenchSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .frame(width: 82, alignment: .leading)
                .padding(.top, 5)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func issueTag(_ title: String, systemImage: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.caption2)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func summaryChip(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func fieldButtonLabel(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func mutedValue(_ value: String) -> some View {
        Text(value)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.vertical, 5)
    }

    @ViewBuilder
    private func metadataItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func commentSourceBadge(_ comment: IssueComment) -> some View {
        if let jiraCommentId = comment.jiraCommentId, jiraCommentId.hasPrefix("linear:") {
            Text("Linear")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.purple)
        } else if comment.jiraCommentId != nil {
            Text("历史同步")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.blue)
        } else if comment.text.hasPrefix("[Linear]") {
            Text("Linear")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.purple.opacity(0.7))
        } else if comment.text.hasPrefix("[Jira]") {
            Text("历史同步")
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.blue.opacity(0.7))
        } else {
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
                            bindFeishuTask(task, to: issue)
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
            .frame(minHeight: 280, maxHeight: 360)
        }
        .frame(width: 760)
        .frame(minHeight: 380)
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

    @ViewBuilder
    private func linearPickerPopover(issue: TrackedIssue) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $linearPickerTab) {
                ForEach(LinearPickerTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            if linearPickerTab == .search {
                HStack(spacing: 6) {
                    TextField("搜索 Linear Issue…", text: $linearSearchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            searchLinearIssues()
                        }
                    Button {
                        searchLinearIssues()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(linearSearchText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            Divider()

            let items = linearPickerTab == .myIssues ? linearMyIssues : linearSearchResults

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { linearIssue in
                        Button {
                            store.updateIssueLinearLink(
                                id: issue.id,
                                issueId: linearIssue.id,
                                key: linearIssue.identifier,
                                url: linearIssue.url
                            )
                            saveState.triggerSave()
                            showLinearPicker = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(linearIssue.identifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(linearIssue.title)
                                        .lineLimit(1)
                                    if let state = linearIssue.state {
                                        Text(state.name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let assignee = linearIssue.assignee {
                                    Text(assignee.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }

                    if linearPickerLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else if items.isEmpty {
                        Text(linearPickerTab == .search ? "输入关键词搜索" : "无 Issues")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 420)
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
                applyFeishuTaskAssignee(issueID: issue.id, candidate: task)
                saveState.triggerSave()
            } catch {
                DevLog.shared.error("IssueTracker", "创建飞书任务失败 #\(issue.issueNumber): \(error.localizedDescription)")
            }
            creatingFeishuTaskIssueID = nil
        }
    }

    private func bindFeishuTask(_ task: FeishuTaskCandidate, to issue: TrackedIssue) {
        store.updateIssueFeishuTaskGuid(id: issue.id, guid: task.guid)
        applyFeishuTaskCompletionStatus(issueID: issue.id, candidate: task)
        applyFeishuTaskAssignee(issueID: issue.id, candidate: task)
        saveState.triggerSave()
        showFeishuTaskPicker = false

        guard task.assigneeIDs.isEmpty else { return }
        Task {
            do {
                let detail = try await FeishuTaskService.shared.taskDetail(store: store, guid: task.guid)
                applyFeishuTaskCompletionStatus(issueID: issue.id, candidate: detail)
                applyFeishuTaskAssignee(issueID: issue.id, candidate: detail)
                saveState.triggerSave()
            } catch {
                DevLog.shared.error("IssueTracker", "读取飞书任务详情失败 #\(issue.issueNumber) [guid=\(task.guid)]: \(error.localizedDescription)")
            }
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

    private func applyFeishuTaskAssignee(issueID: UUID, candidate: FeishuTaskCandidate) {
        guard let assignee = store.assigneeText(fromFeishuTask: candidate),
              let issue = store.trackedIssues.first(where: { $0.id == issueID }) else { return }
        let boundGUID = issue.feishuTaskGuid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard boundGUID == candidate.guid || issue.source == .feishu else { return }
        guard issue.assignee != assignee else { return }
        store.updateIssueAssignee(id: issueID, assignee: assignee)
        DevLog.shared.info("IssueTracker", "飞书任务负责人已同步 #\(issue.issueNumber) [guid=\(candidate.guid), assigneeIDs=\(candidate.assigneeIDs.joined(separator: ", ")), assignee=\(assignee)]")
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
                        applyFeishuTaskAssignee(issueID: issue.id, candidate: task)
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

    private func runFeishuSyncLoop() async {
        let minutes = max(store.feishuBotConfig.taskPollingInterval, 1)
        DevLog.shared.info("IssueTracker", "飞书任务单向同步循环已启动，每 \(minutes) 分钟检查一次")
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)
                guard !Task.isCancelled, NSApp.isActive, !NSApp.isHidden else { continue }
                syncFeishuBoundTasks()
            } catch {
                break
            }
        }
        DevLog.shared.info("IssueTracker", "飞书任务单向同步循环已停止")
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

    private func keepSelectionVisible() {
        if let id = selectedIssueID, filteredIssues.contains(where: { $0.id == id }) {
            return
        }
        selectedIssueID = filteredIssues.first?.id
    }

    private func submitComment(_ issue: TrackedIssue) {
        let text = newCommentText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.addIssueComment(id: issue.id, text: text)
        newCommentText = ""
        saveState.triggerSave()
    }

    private func syncJiraIssues() {
        jiraSyncing = true
        Task {
            async let myResult = JiraService.shared.fetchMyIssues()
            async let reportedResult = JiraService.shared.fetchReportedIssues()
            _ = await (myResult, reportedResult)
            await JiraService.shared.syncTrackedIssues()
            jiraSyncing = false
            saveState.triggerSave()
        }
    }

    private func syncLinearIssues() {
        linearSyncing = true
        Task {
            await LinearService.shared.syncTrackedIssues()
            linearSyncing = false
            saveState.triggerSave()
        }
    }

    private func loadLinearMyIssues() {
        linearPickerLoading = true
        Task {
            let teamId = store.linearConfig.teamId.isEmpty ? nil : store.linearConfig.teamId
            let projectId = store.linearConfig.projectId.isEmpty ? nil : store.linearConfig.projectId
            linearMyIssues = await LinearService.shared.fetchMyIssues(teamId: teamId, projectId: projectId)
            linearPickerLoading = false
        }
    }

    private func searchLinearIssues() {
        let query = linearSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        linearPickerLoading = true
        Task {
            let teamId = store.linearConfig.teamId.isEmpty ? nil : store.linearConfig.teamId
            linearSearchResults = await LinearService.shared.searchIssues(query: query, teamId: teamId)
            linearPickerLoading = false
        }
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

    private func displaySourceName(_ source: IssueSource) -> String {
        switch source {
        case .jira: return "历史入口"
        default: return source.rawValue
        }
    }

}
