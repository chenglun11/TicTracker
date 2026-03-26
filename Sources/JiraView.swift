import SwiftUI

struct JiraView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var refreshing = false
    @State private var transitions: [JiraTransition] = []
    @State private var transitioning = false
    @State private var errorMessage: String?
    @State private var selectedTab: JiraTab = .assigned
    @State private var selectedIssueKey: String?

    private enum JiraTab: String, CaseIterable {
        case assigned = "分配给我"
        case reported = "我提交的"
    }

    private var filteredIssues: [JiraIssue] {
        let source = selectedTab == .assigned ? store.jiraIssues : store.reportedJiraIssues
        if searchText.isEmpty { return source }
        let q = searchText.lowercased()
        return source.filter {
            $0.key.lowercased().contains(q) || $0.summary.lowercased().contains(q)
        }
    }

    private var todayKey: String { store.todayKey }

    private var todayJiraTotal: Int {
        let dayCounts = store.jiraIssueCounts[todayKey] ?? [:]
        return dayCounts.values.reduce(0, +)
    }

    private var selectedJiraIssue: JiraIssue? {
        guard let key = selectedIssueKey else { return nil }
        return filteredIssues.first { $0.key == key }
    }

    var body: some View {
        HSplitView {
            // Left sidebar
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    Picker("", selection: $selectedTab) {
                        ForEach(JiraTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)

                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(refreshing)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(filteredIssues.count)")
                            .font(.caption.bold())
                        Text("今日 \(todayJiraTotal)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                if store.jiraIssues.isEmpty && !refreshing {
                    ContentUnavailableView {
                        Label("暂无工单", systemImage: "tray")
                    } description: {
                        Text("请先在设置中配置 Jira 连接")
                    }
                    .frame(maxHeight: .infinity)
                } else if refreshing && store.jiraIssues.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedIssueKey) {
                        ForEach(filteredIssues) { issue in
                            sidebarRow(issue)
                                .tag(issue.key)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
            .searchable(text: $searchText, prompt: "搜索工单")

            // Right detail
            if let issue = selectedJiraIssue {
                jiraDetail(issue)
            } else {
                ContentUnavailableView {
                    Label("选择工单查看详情", systemImage: "ticket")
                } description: {
                    Text("在左侧列表中选择工单")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if store.jiraIssues.isEmpty && store.jiraConfig.enabled {
                refresh()
            }
            if selectedIssueKey == nil, let first = filteredIssues.first {
                selectedIssueKey = first.key
            }
        }
        .onChange(of: searchText) {
            if let key = selectedIssueKey, !filteredIssues.contains(where: { $0.key == key }) {
                selectedIssueKey = filteredIssues.first?.key
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Sidebar Row

    @ViewBuilder
    private func sidebarRow(_ issue: JiraIssue) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(issue.statusCategoryKey))
                .frame(width: 6, height: 6)

            Text(issue.key)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.secondary)

            Text(issue.summary)
                .font(.callout)
                .lineLimit(1)

            Spacer()

            if let priority = issue.priority {
                Text(priority)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let todayCount = store.jiraTodayCount(issueKey: issue.key)
            if todayCount > 0 {
                Text("\(todayCount)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Jira Detail

    @ViewBuilder
    private func jiraDetail(_ issue: JiraIssue) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Key header (clickable)
                HStack(spacing: 8) {
                    Text(issue.key)
                        .font(.title2.bold().monospaced())
                        .foregroundStyle(.blue)
                        .onTapGesture { openInBrowser(issue.key) }
                        .onHover { inside in
                            if inside {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }

                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                        .foregroundStyle(.blue.opacity(0.6))

                    Spacer()
                }

                // Summary
                Text(issue.summary)
                    .font(.body)

                // Status / Priority / Type
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor(issue.statusCategoryKey))
                            .frame(width: 8, height: 8)
                        Text(issue.status)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(issue.statusCategoryKey).opacity(0.1), in: Capsule())

                    if let priority = issue.priority {
                        Text(priority)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }

                    if let type = issue.issueType {
                        Text(type)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Divider()

                // Count operations
                let todayCount = store.jiraTodayCount(issueKey: issue.key)
                let totalCount = store.jiraTotalCount(issueKey: issue.key)

                HStack(spacing: 16) {
                    Button {
                        store.jiraDecrementForKey(todayKey, issueKey: issue.key)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(todayCount == 0)

                    VStack(spacing: 4) {
                        Text("\(todayCount)")
                            .font(.title.bold())
                        Text("今日计数")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .frame(minWidth: 80)

                    Button {
                        store.jiraIncrementForKey(todayKey, issueKey: issue.key)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    VStack(spacing: 4) {
                        Text("\(totalCount)")
                            .font(.title3.bold())
                            .foregroundStyle(.secondary)
                        Text("总计")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .monospacedDigit()
                }

                Divider()

                // Transitions
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("流转操作")
                            .font(.headline)
                        Spacer()
                        Button {
                            loadTransitions(issue.key)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    if transitions.isEmpty {
                        Text("点击刷新按钮加载可用流转")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(transitions) { t in
                                Button {
                                    performTransition(issueKey: issue.key, transitionID: t.id)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.right.circle")
                                        Text(t.name)
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(transitioning)
                            }
                        }
                    }
                }

                // Error message
                if let errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(20)
        }
    }

    // MARK: - Actions

    private func refresh() {
        refreshing = true
        errorMessage = nil
        Task {
            async let assigned = JiraService.shared.fetchMyIssues()
            async let reported = JiraService.shared.fetchReportedIssues()
            let err1 = await assigned
            let err2 = await reported
            if let err = err1 ?? err2 {
                errorMessage = "刷新失败：\(err)"
            }
            await JiraService.shared.syncTrackedIssues()
            refreshing = false
        }
    }

    private func openInBrowser(_ key: String) {
        let base = store.jiraConfig.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/browse/\(key)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadTransitions(_ issueKey: String) {
        transitions = []
        Task {
            transitions = await JiraService.shared.fetchTransitions(issueKey: issueKey)
        }
    }

    private func performTransition(issueKey: String, transitionID: String) {
        transitioning = true
        errorMessage = nil
        Task {
            let ok = await JiraService.shared.doTransition(issueKey: issueKey, transitionID: transitionID)
            if ok {
                _ = await JiraService.shared.fetchMyIssues()
                store.jiraTransitioned(todayKey, issueKey: issueKey)
                DevLog.shared.info("Jira", "\(issueKey) 流转 +1")
                transitions = []
            } else {
                errorMessage = "流转失败，请重试"
            }
            transitioning = false
        }
    }

    private func statusColor(_ categoryKey: String) -> Color {
        switch categoryKey {
        case "new": return .blue
        case "indeterminate": return .yellow
        case "done": return .green
        default: return .gray
        }
    }
}

// Simple flow layout for tags
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight + (i > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (i, row) in rows.enumerated() {
            if i > 0 { y += spacing }
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(view)
            x += size.width + spacing
        }
        return rows
    }
}
