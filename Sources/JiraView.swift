import SwiftUI

struct JiraView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var refreshing = false
    @State private var transitionsFor: String?
    @State private var transitions: [JiraTransition] = []
    @State private var transitioning = false
    @State private var errorMessage: String?
    @State private var selectedTab: JiraTab = .assigned

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

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Picker("", selection: $selectedTab) {
                    ForEach(JiraTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(refreshing)

                TextField("搜索工单…", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                // Stats
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(filteredIssues.count) 个工单")
                        .font(.caption.bold())
                    Text("今日 \(todayJiraTotal) 次")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Issue list
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
                List(filteredIssues) { issue in
                    issueRow(issue)
                }
                .listStyle(.inset)
            }

            Divider()

            // Bottom bar
            HStack {
                if let errorMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                } else {
                    Text("💡 点击工单编号在浏览器中打开")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if refreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            if store.jiraIssues.isEmpty && store.jiraConfig.enabled {
                refresh()
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private func issueRow(_ issue: JiraIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(spacing: 6) {
                // Status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(issue.statusCategoryKey))
                        .frame(width: 8, height: 8)
                    Text(issue.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor(issue.statusCategoryKey).opacity(0.1), in: Capsule())

                // Key (clickable)
                Text(issue.key)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.blue)
                    .onTapGesture { openInBrowser(issue.key) }
                    .onHover { inside in
                        if inside {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }

                if let type = issue.issueType {
                    Text(type)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }

                if let priority = issue.priority {
                    Text(priority)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Counts
                let todayCount = store.jiraTodayCount(issueKey: issue.key)
                let totalCount = store.jiraTotalCount(issueKey: issue.key)

                HStack(spacing: 8) {
                    VStack(spacing: 0) {
                        Text("\(todayCount)")
                            .font(.caption.bold())
                        Text("今日")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()

                    VStack(spacing: 0) {
                        Text("\(totalCount)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("总计")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .monospacedDigit()
                }
            }

            // Summary
            Text(issue.summary)
                .font(.callout)
                .lineLimit(2)

            // Actions
            HStack(spacing: 8) {
                Button {
                    store.jiraDecrementForKey(todayKey, issueKey: issue.key)
                } label: {
                    Label("", systemImage: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(store.jiraTodayCount(issueKey: issue.key) == 0)
                .help("减少计数")

                Button {
                    store.jiraIncrementForKey(todayKey, issueKey: issue.key)
                } label: {
                    Label("", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("增加计数")

                Spacer()

                Button {
                    loadTransitions(issue.key)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                        Text("流转")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: Binding(
                    get: { transitionsFor == issue.key },
                    set: { if !$0 { transitionsFor = nil } }
                )) {
                    transitionPopover(issueKey: issue.key)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    @ViewBuilder
    private func transitionPopover(issueKey: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("流转到")
                .font(.caption.bold())
                .padding(.bottom, 2)
            if transitions.isEmpty {
                Text("无可用流转")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(transitions) { t in
                    Button {
                        performTransition(issueKey: issueKey, transitionID: t.id)
                    } label: {
                        Text(t.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .disabled(transitioning)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 120)
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
        transitionsFor = issueKey
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
            } else {
                errorMessage = "流转失败，请重试"
            }
            transitioning = false
            transitionsFor = nil
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
