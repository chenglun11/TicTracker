import SwiftUI

struct JiraView: View {
    @Bindable var store: DataStore
    @State private var searchText = ""
    @State private var refreshing = false
    @State private var transitionsFor: String?
    @State private var transitions: [JiraTransition] = []
    @State private var transitioning = false
    @State private var errorMessage: String?

    private var filteredIssues: [JiraIssue] {
        if searchText.isEmpty { return store.jiraIssues }
        let q = searchText.lowercased()
        return store.jiraIssues.filter {
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
            HStack(spacing: 8) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(refreshing)

                TextField("搜索工单…", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Text("\(filteredIssues.count) 个工单")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("今日 Jira 支持：\(todayJiraTotal) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if refreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(statusColor(issue.statusCategoryKey))
                .frame(width: 8, height: 8)
                .help(issue.status)

            // Key (clickable)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
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
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }

                    if let priority = issue.priority {
                        Text(priority)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(issue.summary)
                    .font(.callout)
                    .lineLimit(2)
            }

            Spacer()

            // Counts
            let todayCount = store.jiraTodayCount(issueKey: issue.key)
            let totalCount = store.jiraTotalCount(issueKey: issue.key)

            VStack(spacing: 2) {
                Text("今日 \(todayCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("总计 \(totalCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            .fixedSize()

            // +1 / -1
            Button {
                store.jiraDecrementForKey(todayKey, issueKey: issue.key)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(todayCount == 0)

            Button {
                store.jiraIncrementForKey(todayKey, issueKey: issue.key)
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)

            // Transition button
            Button {
                loadTransitions(issue.key)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .help("状态流转")
            .popover(isPresented: Binding(
                get: { transitionsFor == issue.key },
                set: { if !$0 { transitionsFor = nil } }
            )) {
                transitionPopover(issueKey: issue.key)
            }
        }
        .padding(.vertical, 2)
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
            if let err = await JiraService.shared.fetchMyIssues() {
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
