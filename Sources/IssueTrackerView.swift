import SwiftUI

struct IssueTrackerView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var workbenchFilter: WorkbenchFilter = .all
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
    @State private var creatingLinearIssueID: UUID?
    @State private var feishuSyncInProgress = false
    @State private var linearSyncing = false
    @State private var showLinearPicker = false
    @State private var linearSearchText = ""
    @State private var linearProjects: [LinearProject] = []
    @State private var linearSearchResults: [LinearIssue] = []
    @State private var linearMyIssues: [LinearIssue] = []
    @State private var linearImportCandidates: [LinearIssue] = []
    @State private var selectedLinearImportIDs: Set<String> = []
    @State private var linearImportLoading = false
    @State private var linearImportMessage: String?
    @State private var showingLinearImportPage = false
    @State private var linearPickerLoading = false
    @State private var linearProjectLoading = false
    @State private var linearPickerTab: LinearPickerTab = .myIssues

    private enum LinearPickerTab: String, CaseIterable {
        case myIssues = "全部 Issues"
        case search = "搜索"
    }

    private enum StatusFilter: String, CaseIterable {
        case all = "全部"
        case unresolved = "未解决"
        case observing = "观测中"
        case fixed = "已修复"
        case ignored = "已忽略"
    }

    private enum WorkbenchFilter: String, CaseIterable {
        case all = "全部"
        case reportedByMe = "我提交的"
        case reportedToday = "今日提交"
        case myOpen = "我提交未关闭"
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

        switch workbenchFilter {
        case .all:
            break
        case .reportedByMe:
            issues = issues.filter { isReportedByCurrentMember($0) }
        case .reportedToday:
            issues = issues.filter { issue in
                guard isReportedByCurrentMember(issue) else { return false }
                if let reportedAt = issue.reportedAt {
                    return DataStore.dateKey(from: reportedAt) == store.todayKey
                }
                return issue.dateKey == store.todayKey
            }
        case .myOpen:
            issues = issues.filter { isReportedByCurrentMember($0) && !$0.status.isResolved }
        }

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
                ($0.feishuTaskSummary?.lowercased().contains(query) ?? false) ||
                ($0.department?.lowercased().contains(query) ?? false) ||
                ($0.reporterName?.lowercased().contains(query) ?? false) ||
                $0.issueTags.contains(where: { $0.lowercased().contains(query) }) ||
                $0.comments.contains(where: { $0.text.lowercased().contains(query) })
            }
        }

        return issues.sorted { $0.createdAt > $1.createdAt }
    }

    private var unresolvedCount: Int {
        store.visibleTrackedIssues.filter { !$0.status.isResolved && $0.status != .observing }.count
    }

    private var myReportedCount: Int {
        store.visibleTrackedIssues.filter { isReportedByCurrentMember($0) }.count
    }

    private var myReportedTodayCount: Int {
        store.visibleTrackedIssues.filter { issue in
            guard isReportedByCurrentMember(issue) else { return false }
            if let reportedAt = issue.reportedAt {
                return DataStore.dateKey(from: reportedAt) == store.todayKey
            }
            return issue.dateKey == store.todayKey
        }.count
    }

    private var myOpenCount: Int {
        store.visibleTrackedIssues.filter { isReportedByCurrentMember($0) && !$0.status.isResolved }.count
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

    private var syncInProgress: Bool {
        feishuSyncInProgress || jiraSyncing || linearSyncing
    }

    private var canSyncAnyIssueSource: Bool {
        canSyncFeishuTasks || store.jiraConfig.enabled || store.linearConfig.enabled
    }

    private var syncButtonHelp: String {
        var sources: [String] = []
        if canSyncFeishuTasks { sources.append("飞书任务") }
        if store.jiraConfig.enabled { sources.append("Jira") }
        if store.linearConfig.enabled { sources.append("Linear") }
        return sources.isEmpty ? "没有可同步的入口" : "同步：" + sources.joined(separator: "、")
    }

    var body: some View {
        HSplitView {
            sidebar
            detailPane
        }
        .onAppear {
            syncFeishuBoundTasks()
            if store.linearConfig.enabled {
                refreshLinearImportCandidates()
            }
            if selectedIssueID == nil, let first = filteredIssues.first {
                selectedIssueID = first.id
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .onChange(of: selectedIssueID) {
            showingLinearImportPage = false
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
        .onChange(of: workbenchFilter) {
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
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.12))
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("问题反馈")
                        .font(.headline.weight(.semibold))
                    Text("\(store.visibleTrackedIssues.count) 个已有问题")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if syncInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在同步问题入口…")
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
                statBadge(title: "总计", value: store.visibleTrackedIssues.count, color: .blue)
                statBadge(title: "未解决", value: unresolvedCount, color: unresolvedCount > 0 ? .orange : .green)
                statBadge(title: "今日", value: myReportedTodayCount, color: .green)
            }

            HStack(spacing: 6) {
                Button {
                    syncAllIssueSources()
                } label: {
                    Label(syncInProgress ? "同步中" : "同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(syncInProgress || !canSyncAnyIssueSource)
                .help(syncButtonHelp)

                Button {
                    sendToFeishu()
                } label: {
                    Label(sendingFeishu ? "发送中" : "日报", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(sendingFeishu || store.feishuBotConfig.webhooks.isEmpty)
                .help("发送完整日报")

                Spacer(minLength: 0)

                if store.linearConfig.enabled {
                    Button {
                        showingLinearImportPage = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tray.and.arrow.down")
                            Text("待确认")
                            Text("\(linearImportCandidates.count)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.teal)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.teal.opacity(0.12), in: Capsule())
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(showingLinearImportPage ? .teal : .accentColor)
                    .controlSize(.small)
                    .help("查看 Linear 待确认提交")
                }
            }

            if let result = sendResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(sendSuccess ? .green : .red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            workbenchQuickFilters

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("搜索编号、标题、负责人、提交人、Tag、备注", text: $searchText)
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
    private var linearImportPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.teal.opacity(0.14))
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.teal)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("候选队列")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(linearImportCandidates.count)")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.teal.opacity(0.13), in: Capsule())
                    }
                    Text(linearImportScopeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if linearImportLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    refreshLinearImportCandidates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(linearImportLoading || store.linearConfig.teamId.isEmpty)
                .help("刷新 Linear 候选提交")
            }

            if linearImportCandidates.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: linearImportLoading ? "clock" : "checkmark.seal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(linearImportLoading ? Color.secondary : Color.green)
                        .frame(width: 24, height: 24)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                    Text(linearImportMessage ?? "暂无待导入的 LarkQPush 提交")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
                )
            } else {
                HStack(spacing: 7) {
                    Button {
                        toggleAllLinearImportCandidates()
                    } label: {
                        Label(
                            selectedLinearImportIDs.count == linearImportCandidates.count ? "取消" : "全选",
                            systemImage: selectedLinearImportIDs.count == linearImportCandidates.count ? "checkmark.square.fill" : "square"
                        )
                    }
                    .controlSize(.small)

                    Spacer()

                    Text("\(selectedLinearImportIDs.count)/\(linearImportCandidates.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(selectedLinearImportIDs.isEmpty ? Color.secondary : Color.teal)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.08), in: Capsule())

                    Button {
                        importSelectedLinearCandidates()
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedLinearImportIDs.isEmpty)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(linearImportCandidates) { candidate in
                            linearImportCandidateRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 520)
                .tunedForResponsiveScroll()

                if let linearImportMessage {
                    Text(linearImportMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.92),
                    Color.teal.opacity(0.055)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private func linearImportCandidateRow(_ issue: LinearIssue) -> some View {
        let selected = selectedLinearImportIDs.contains(issue.id)
        HStack(alignment: .top, spacing: 9) {
            Toggle("", isOn: Binding(
                get: { selectedLinearImportIDs.contains(issue.id) },
                set: { isOn in
                    if isOn {
                        selectedLinearImportIDs.insert(issue.id)
                    } else {
                        selectedLinearImportIDs.remove(issue.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(issue.identifier)
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))

                    Text("LarkQPush")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))

                    Spacer(minLength: 0)

                    if !issue.url.isEmpty {
                        Button {
                            openURL(issue.url)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .help("打开 Linear")
                    }
                }

                Text(issue.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 72), spacing: 5, alignment: .leading)],
                    alignment: .leading,
                    spacing: 5
                ) {
                    linearImportMetaChip(issue.state?.name, systemImage: "circle.dotted", color: .orange)
                    linearImportMetaChip(issue.project?.name, systemImage: "folder", color: .purple)
                    linearImportMetaChip(issue.assignee?.name, systemImage: "person", color: .blue)
                    linearImportMetaChip(linearImportDateText(issue.createdAt), systemImage: "calendar", color: .gray)
                }
            }
        }
        .padding(9)
        .background(
            selected ? Color.teal.opacity(0.12) : Color(nsColor: .textBackgroundColor).opacity(0.70),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.teal.opacity(0.45) : Color.secondary.opacity(0.10), lineWidth: 1)
        )
    }

    private var linearImportScopeText: String {
        if !store.linearConfig.projectName.isEmpty {
            return store.linearConfig.projectName
        }
        if !store.linearConfig.teamName.isEmpty {
            return store.linearConfig.teamName
        }
        return "Linear"
    }

    @ViewBuilder
    private func linearImportMetaChip(_ value: String?, systemImage: String, color: Color) -> some View {
        if let value, !value.isEmpty {
            Label(value, systemImage: systemImage)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private var workbenchQuickFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("我的工作台", systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(store.currentMemberName.isEmpty ? "未选择我是谁" : store.currentMemberName)
                    .font(.caption2)
                    .foregroundStyle(store.currentMemberName.isEmpty ? .orange : .secondary)
                    .lineLimit(1)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                workbenchButton(.all, count: store.visibleTrackedIssues.count)
                workbenchButton(.reportedByMe, count: myReportedCount)
                workbenchButton(.reportedToday, count: myReportedTodayCount)
                workbenchButton(.myOpen, count: myOpenCount)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func workbenchButton(_ filter: WorkbenchFilter, count: Int) -> some View {
        Button {
            workbenchFilter = filter
        } label: {
            HStack(spacing: 4) {
                Text(filter.rawValue)
                    .lineLimit(1)
                    .font(.caption)
                Spacer(minLength: 2)
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(workbenchFilter == filter ? .white.opacity(0.9) : .secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .foregroundStyle(workbenchFilter == filter ? .white : .primary)
            .background(workbenchFilter == filter ? Color.accentColor : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(filter != .all && store.currentMemberName.isEmpty)
        .help(filter == .all ? "查看全部问题" : "需要在设置中选择我是谁")
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
            .tunedForResponsiveScroll()
        }
    }

    @ViewBuilder
    private func listRow(_ issue: TrackedIssue) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor(issue.status))
                .frame(width: 3)
                .padding(.vertical, 3)

            VStack(alignment: .leading, spacing: 7) {
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

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 58), spacing: 5, alignment: .leading)],
                    alignment: .leading,
                    spacing: 5
                ) {
                    issueTag(issue.type.rawValue, systemImage: issue.type.icon, color: issue.type.color)
                    issueTag(issue.status.rawValue, systemImage: nil, color: statusColor(issue.status))

                    if let assignee = issue.assignee, !assignee.isEmpty {
                        issueTag(assignee, systemImage: "person", color: .blue)
                    }
                    if let reporter = issue.reporterName, !reporter.isEmpty {
                        issueTag("提交 \(reporter)", systemImage: "person.crop.circle.badge.checkmark", color: .green)
                    }
                    issueTag(issue.dateKey, systemImage: "calendar", color: .gray)
                }

                if issue.source != .manual || issue.hasDevActivity || issue.isEscalated || issue.feishuTaskGuid?.isEmpty == false || !issue.issueTags.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 70), spacing: 5, alignment: .leading)],
                        alignment: .leading,
                        spacing: 5
                    ) {
                        if issue.source != .manual {
                            issueTag(displaySourceName(issue.source), systemImage: "link", color: .secondary)
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
                        ForEach(issue.issueTags.prefix(2), id: \.self) { tag in
                            issueTag(tag, systemImage: "tag", color: .pink)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
        )
        .padding(.vertical, 2)
    }

    // MARK: - Issue Detail

    private var detailPane: some View {
        Group {
            if showingLinearImportPage {
                linearImportPage
            } else if let issue = selectedIssue {
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
    }

    @ViewBuilder
    private var linearImportPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.teal.opacity(0.13))
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.teal)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Linear 待确认提交")
                            .font(.title2.weight(.semibold))
                        Text(linearImportScopeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        refreshLinearImportCandidates()
                    } label: {
                        Label(linearImportLoading ? "刷新中" : "刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(linearImportLoading || store.linearConfig.teamId.isEmpty)

                    Button {
                        showingLinearImportPage = false
                    } label: {
                        Label("返回问题", systemImage: "sidebar.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(16)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.80), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )

                linearImportPanel
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
                    )
            }
            .padding(18)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tunedForResponsiveScroll()
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
            .padding(18)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .tunedForResponsiveScroll()
    }

    @ViewBuilder
    private func issueSummaryHeader(_ issue: TrackedIssue, isReadOnly: Bool) -> some View {
        let accent = statusColor(issue.status)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accent.opacity(0.13))
                    Image(systemName: issue.status.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        if issue.issueNumber > 0 {
                            Text("#\(issue.issueNumber)")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                        }
                        summaryChip(issue.type.rawValue, systemImage: issue.type.icon, color: issue.type.color)
                        summaryChip(issue.status.rawValue, systemImage: issue.status.icon, color: accent)
                        if issue.source != .manual {
                            summaryChip(displaySourceName(issue.source), systemImage: "link", color: .gray)
                        }
                        Spacer(minLength: 0)
                    }

                    if isEditingTitle {
                        TextEditor(text: $editingTitle)
                            .font(.title2.weight(.semibold))
                            .frame(minHeight: 86, maxHeight: 130)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(accent.opacity(0.28), lineWidth: 1)
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
                }

                if !isReadOnly && !isEditingTitle {
                    Button {
                        editingTitle = issue.title
                        isEditingTitle = true
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help("编辑标题")
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                issueSummaryMetaChip(title: "负责人", value: issue.assignee ?? "未指派", systemImage: "person", color: .blue)
                if let reporter = issue.reporterName, !reporter.isEmpty {
                    issueSummaryMetaChip(title: "提交人", value: reporter, systemImage: "person.crop.circle.badge.checkmark", color: .green)
                }
                if let department = issue.department, !department.isEmpty {
                    issueSummaryMetaChip(title: "项目", value: department, systemImage: "folder", color: .teal)
                }
                issueSummaryMetaChip(title: "创建", value: Self.timeFmt.string(from: issue.createdAt), systemImage: "calendar", color: .gray)
                if issue.hasDevActivity {
                    issueSummaryMetaChip(title: "进展", value: "开发中", systemImage: "hammer", color: .green)
                }
                if issue.isEscalated {
                    issueSummaryMetaChip(title: "升级", value: "Escalated", systemImage: "exclamationmark.arrow.triangle.2.circlepath", color: .red)
                }
                if issue.feishuTaskGuid?.isEmpty == false {
                    issueSummaryMetaChip(title: "任务", value: "飞书任务", systemImage: "checklist", color: .indigo)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .textBackgroundColor).opacity(0.98),
                    accent.opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 4)
                .padding(.vertical, 12)
        }
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

                fieldRow("关注人", systemImage: "eye") {
                    if store.bugTeamMembers.isEmpty {
                        mutedValue("未配置成员")
                    } else {
                        HStack(spacing: 6) {
                            if issue.followers.isEmpty {
                                Text("无")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(issue.followers, id: \.self) { name in
                                    Text(name)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.1), in: Capsule())
                                }
                            }
                            Spacer()
                            Menu {
                                ForEach(store.bugTeamMembers, id: \.self) { member in
                                    let isFollowing = issue.followers.contains(member)
                                    Button {
                                        toggleFollower(issueId: issue.id, member: member)
                                    } label: {
                                        if isFollowing {
                                            Label(member, systemImage: "checkmark")
                                        } else {
                                            Text(member)
                                        }
                                    }
                                }
                                if !issue.followers.isEmpty {
                                    Divider()
                                    Button("清空关注人") {
                                        store.updateIssueFollowers(id: issue.id, followers: [])
                                        saveState.triggerSave()
                                    }
                                }
                            } label: {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.blue)
                            }
                            .menuStyle(.button)
                            .fixedSize()
                            .disabled(isReadOnly)
                        }
                    }
                }

                fieldRow("提交人", systemImage: "person.crop.circle.badge.checkmark") {
                    if store.teamMembers.isEmpty {
                        mutedValue(issue.reporterName ?? "未配置成员")
                    } else {
                        Menu {
                            Button("未标记") {
                                store.updateIssueReporter(id: issue.id, member: nil)
                                saveState.triggerSave()
                            }
                            Divider()
                            ForEach(store.teamMembers) { member in
                                Button(member.name) {
                                    store.updateIssueReporter(id: issue.id, member: member)
                                    saveState.triggerSave()
                                }
                            }
                        } label: {
                            fieldButtonLabel(issue.reporterName ?? "未标记", systemImage: "person.crop.circle.badge.checkmark", color: .green)
                        }
                        .disabled(isReadOnly)
                    }
                }

                fieldRow("Tag", systemImage: "tag") {
                    TextField("例如：今日Bug, 待飞书推送", text: Binding(
                        get: { issue.issueTags.joined(separator: ", ") },
                        set: {
                            let tags = $0.components(separatedBy: CharacterSet(charactersIn: ",，"))
                            store.updateIssueTags(id: issue.id, tags: tags)
                            saveState.debouncedSave()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isReadOnly)
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
                    linkedTaskControl(issue)
                case .linear:
                    linearLinkFields(issue)
                case .manual:
                    fieldRow("外部工单", systemImage: "link.slash") {
                        mutedValue("未关联")
                    }
                }
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
    private func linearLinkFields(_ issue: TrackedIssue) -> some View {
        fieldRow("Project", systemImage: "folder") {
            HStack(spacing: 8) {
                Menu {
                    Button("不指定 Project") {
                        selectLinearProject(nil, for: issue)
                    }
                    Divider()
                    ForEach(linearProjectOptions(), id: \.id) { project in
                        Button {
                            selectLinearProject(project, for: issue)
                        } label: {
                            if issue.linearProjectId == project.id {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                } label: {
                    fieldButtonLabel(issue.linearProjectName ?? "选择 Project", systemImage: "folder", color: .purple)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .disabled(!store.linearConfig.enabled)

                Button {
                    loadLinearProjects()
                } label: {
                    if linearProjectLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(linearProjectLoading || store.linearConfig.teamId.isEmpty)
                    .help("刷新 Linear Project")
            }
            .task {
                if linearProjects.isEmpty {
                    loadLinearProjects()
                }
            }
        }

        fieldRow("Issue", systemImage: "arrow.triangle.branch") {
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

                        Menu {
                            Button {
                                linearSearchText = ""
                                linearSearchResults = []
                                linearPickerTab = .myIssues
                                showLinearPicker = true
                                loadLinearMyIssues(for: issue)
                            } label: {
                                Label("关联已有 Issue", systemImage: "link")
                            }
                            Button {
                                createLinearIssue(for: issue)
                            } label: {
                                Label("创建新 Issue", systemImage: "plus")
                            }
                            .disabled(store.linearConfig.teamId.isEmpty)
                        } label: {
                            if creatingLinearIssueID == issue.id {
                                Label("创建中…", systemImage: "arrow.triangle.branch")
                                    .font(.caption)
                            } else {
                                Label("Linear", systemImage: "arrow.triangle.branch")
                                    .font(.caption)
                            }
                        }
                        .menuStyle(.button)
                        .controlSize(.small)
                        .disabled(creatingLinearIssueID != nil || !store.linearConfig.enabled)
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
                        if issue.feishuTaskCompletedAt?.isEmpty == false {
                            Text("飞书已完成")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Text("状态由飞书同步")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Button {
                            openFeishuTask(guid: guid)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .buttonStyle(.borderless)
                        .help("在飞书中打开任务")

                        Button("解绑") {
                            store.updateIssueFeishuTaskBinding(id: issue.id, task: nil)
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
	                    HStack(spacing: 8) {
	                        Image(systemName: "text.bubble")
	                            .foregroundStyle(.secondary)
	                        Text("暂无备注")
	                            .font(.caption)
	                            .foregroundStyle(.secondary)
	                    }
	                    .frame(maxWidth: .infinity, alignment: .leading)
	                    .padding(10)
	                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ForEach(issue.comments.sorted { $0.createdAt > $1.createdAt }) { comment in
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color.secondary.opacity(0.10))
                                Image(systemName: "quote.bubble")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 26, height: 26)

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
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
                        )
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.10))
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 24, height: 24)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
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
                .padding(.top, 6)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
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
    private func issueSummaryMetaChip(title: String, value: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
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
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
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
            .tunedForResponsiveScroll()
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
            .tunedForResponsiveScroll()
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

    private func isReportedByCurrentMember(_ issue: TrackedIssue) -> Bool {
        if !store.currentMemberId.isEmpty, issue.reporterId == store.currentMemberId {
            return true
        }
        if !store.currentMemberName.isEmpty, issue.reporterName == store.currentMemberName {
            return true
        }
        return false
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
                            if let project = linearIssue.project {
                                store.updateIssueLinearProject(id: issue.id, projectId: project.id, name: project.name)
                            }
                            saveState.triggerSave()
                            showLinearPicker = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(linearIssue.identifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(linearIssue.title)
                                        .lineLimit(2)
                                    if let state = linearIssue.state {
                                        Text(state.name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let project = linearIssue.project {
                                        Text(project.name)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
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
            .frame(minHeight: 300, maxHeight: 500)
            .tunedForResponsiveScroll()
        }
        .frame(width: 520)
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
                store.updateIssueFeishuTaskBinding(id: issue.id, task: task)
                applyFeishuTaskCompletionStatus(issueID: issue.id, candidate: task)
                applyFeishuTaskAssignee(issueID: issue.id, candidate: task)
                saveState.triggerSave()
            } catch {
                DevLog.shared.error("IssueTracker", "创建飞书任务失败 #\(issue.issueNumber): \(error.localizedDescription)")
            }
            creatingFeishuTaskIssueID = nil
        }
    }

    private func toggleFollower(issueId: UUID, member: String) {
        guard var issue = store.trackedIssues.first(where: { $0.id == issueId }) else { return }
        if issue.followers.contains(member) {
            issue.followers.removeAll { $0 == member }
        } else {
            issue.followers.append(member)
        }
        store.updateIssueFollowers(id: issueId, followers: issue.followers)
        saveState.triggerSave()
    }

    private func createLinearIssue(for issue: TrackedIssue) {
        creatingLinearIssueID = issue.id
        let config = store.linearConfig
        let teamId = config.teamId
        let selectedProjectId = issue.linearProjectId?.isEmpty == false ? issue.linearProjectId : nil
        // Resolve assignee: local name → Linear user ID via mapping
        let assigneeId: String? = {
            guard let name = issue.assignee, !name.isEmpty else { return nil }
            return config.assigneeMapping[name]
        }()
        // Resolve labels: local type → Linear label IDs via reverse labelMapping
        let labelIds: [String]? = {
            let typeRaw = issue.type.rawValue
            let matchedLabelNames = config.labelMapping.filter { $0.value == typeRaw }.map(\.key)
            guard !matchedLabelNames.isEmpty else { return nil }
            let ids = config.teamLabels.filter { matchedLabelNames.contains($0.name) }.map(\.id)
            return ids.isEmpty ? nil : ids
        }()
        Task {
            if let created = await LinearService.shared.createIssue(
                title: issue.title,
                description: nil,
                teamId: teamId,
                projectId: selectedProjectId,
                assigneeId: assigneeId,
                labelIds: labelIds
            ) {
                store.updateIssueLinearLink(id: issue.id, issueId: created.id, key: created.identifier, url: created.url)
                if let project = created.project {
                    store.updateIssueLinearProject(id: issue.id, projectId: project.id, name: project.name)
                }
                store.updateIssueLinearAssignee(id: issue.id, assignee: issue.assignee)
                store.addIssueComment(id: issue.id, text: "[Linear] 已创建: \(created.identifier)")
                saveState.triggerSave()
                DevLog.shared.info("IssueTracker", "创建 Linear Issue 成功 #\(issue.issueNumber) → \(created.identifier)")
            } else {
                DevLog.shared.error("IssueTracker", "创建 Linear Issue 失败 #\(issue.issueNumber)")
            }
            creatingLinearIssueID = nil
        }
    }

    private func bindFeishuTask(_ task: FeishuTaskCandidate, to issue: TrackedIssue) {
        store.updateIssueFeishuTaskBinding(id: issue.id, task: task)
        applyFeishuTaskCompletionStatus(issueID: issue.id, candidate: task)
        applyFeishuTaskAssignee(issueID: issue.id, candidate: task)
        saveState.triggerSave()
        showFeishuTaskPicker = false

        guard task.assigneeIDs.isEmpty else { return }
        Task {
            do {
                let detail = try await FeishuTaskService.shared.taskDetail(store: store, guid: task.guid)
                store.updateIssueFeishuTaskBinding(id: issue.id, task: detail)
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
        store.updateIssueAssigneeLocally(id: issueID, assignee: assignee)
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
                        store.updateIssueFeishuTaskBinding(id: issue.id, task: task)
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
        store.addIssueComment(id: issue.id, text: text, syncToLinear: true)
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
            await loadLinearImportCandidates()
            linearSyncing = false
            saveState.triggerSave()
        }
    }

    private func refreshLinearImportCandidates() {
        guard store.linearConfig.enabled, !linearImportLoading else { return }
        linearImportLoading = true
        linearImportMessage = nil
        Task {
            await loadLinearImportCandidates()
            linearImportLoading = false
        }
    }

    private func loadLinearImportCandidates() async {
        guard store.linearConfig.enabled else {
            linearImportCandidates = []
            selectedLinearImportIDs = []
            return
        }
        let candidates = await LinearService.shared.fetchImportCandidatesFromConfiguredScope()
        linearImportCandidates = candidates
        let candidateIDs = Set(candidates.map(\.id))
        selectedLinearImportIDs = selectedLinearImportIDs.intersection(candidateIDs)
        linearImportMessage = candidates.isEmpty ? "暂无待导入的 LarkQPush 提交" : nil
    }

    private func toggleAllLinearImportCandidates() {
        let allIDs = Set(linearImportCandidates.map(\.id))
        if selectedLinearImportIDs == allIDs {
            selectedLinearImportIDs = []
        } else {
            selectedLinearImportIDs = allIDs
        }
    }

    private func importSelectedLinearCandidates() {
        let selected = linearImportCandidates.filter { selectedLinearImportIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        var imported = 0
        for issue in selected {
            if store.addIssueFromLinear(issue) {
                imported += 1
            }
        }
        let importedIDs = Set(selected.map(\.id))
        linearImportCandidates.removeAll { importedIDs.contains($0.id) || store.hasIssueFromLinear($0) }
        selectedLinearImportIDs.subtract(importedIDs)
        linearImportMessage = imported > 0 ? "已导入 \(imported) 个提交" : "没有新的提交被导入"
        if let latest = store.trackedIssues.last {
            selectedIssueID = latest.id
        }
        if imported > 0 {
            showingLinearImportPage = false
        }
        saveState.triggerSave()
    }

    private func linearImportDateText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(10))
    }

    private func syncAllIssueSources() {
        if canSyncFeishuTasks {
            syncFeishuBoundTasks()
        }
        if store.jiraConfig.enabled {
            syncJiraIssues()
        }
        if store.linearConfig.enabled {
            syncLinearIssues()
        }
    }

    private func loadLinearProjects() {
        guard !store.linearConfig.teamId.isEmpty else { return }
        linearProjectLoading = true
        Task {
            linearProjects = await LinearService.shared.fetchProjects(teamId: store.linearConfig.teamId)
            linearProjectLoading = false
        }
    }

    private func linearProjectOptions() -> [LinearProject] {
        var result: [LinearProject] = []
        var seen = Set<String>()
        func append(_ project: LinearProject?) {
            guard let project, !project.id.isEmpty, seen.insert(project.id).inserted else { return }
            result.append(project)
        }
        append(store.linearConfig.projectId.isEmpty ? nil : LinearProject(id: store.linearConfig.projectId, name: store.linearConfig.projectName.isEmpty ? store.linearConfig.projectId : store.linearConfig.projectName))
        for project in linearProjects {
            append(project)
        }
        return result
    }

    private func selectLinearProject(_ project: LinearProject?, for issue: TrackedIssue) {
        let projectChanged = issue.linearProjectId != project?.id
        store.updateIssueLinearProject(id: issue.id, projectId: project?.id, name: project?.name)
        if let project {
            if projectChanged {
                store.updateIssueLinearLink(id: issue.id, issueId: nil, key: nil, url: nil)
            }
            if !projectChanged, let linkedId = issue.linearIssueId, !linkedId.isEmpty {
                Task {
                    await LinearService.shared.updateIssueProject(issueId: linkedId, projectId: project.id)
                }
            }
        } else {
            // No Project means "do not filter by Project"; keep the selected Issue intact.
        }
        linearMyIssues = []
        linearSearchResults = []
        saveState.triggerSave()
    }

    private func loadLinearMyIssues(for issue: TrackedIssue) {
        linearPickerLoading = true
        Task {
            let teamId = store.linearConfig.teamId.isEmpty ? nil : store.linearConfig.teamId
            let projectId = issue.linearProjectId?.isEmpty == false ? issue.linearProjectId : nil
            linearMyIssues = await LinearService.shared.fetchIssues(teamId: teamId, projectId: projectId)
            linearPickerLoading = false
        }
    }

    private func searchLinearIssues() {
        let query = linearSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        linearPickerLoading = true
        Task {
            let teamId = store.linearConfig.teamId.isEmpty ? nil : store.linearConfig.teamId
            let results = await LinearService.shared.searchIssues(query: query, teamId: teamId)
            if let selected = selectedIssue, selected.source == .linear, let projectId = selected.linearProjectId, !projectId.isEmpty {
                linearSearchResults = results.filter { $0.project?.id == projectId }
            } else {
                linearSearchResults = results
            }
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
