import SwiftUI

struct IssueTrackerTab: View {
    @Bindable var store: DataStore
    @State private var newMember = ""
    @State private var saveState = AutoSaveState()
    @State private var isImportingFromLinear = false
    @State private var importError: String?
    @FocusState private var memberFieldFocused: Bool

    var body: some View {
        Form {
            Section("问题追踪") {
                Toggle(isOn: Bindable(store).issueTrackerEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用问题追踪")
                        Text("统一管理 Bug、Feat 和项目问题")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.issueTrackerEnabled) { _, _ in saveState.triggerSave() }

                if store.issueTrackerEnabled {
                    Toggle(isOn: Bindable(store).diaryShowAllPending) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("日记展示全部待处理")
                            Text("在日记详情中显示所有未解决问题，当天新增高亮标记")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: store.diaryShowAllPending) { _, _ in saveState.triggerSave() }
                }

                if store.jiraConfig.enabled {
                    Picker("Jira 入口来源", selection: Bindable(store).jiraSourceMode) {
                        Text("指派给我").tag(0)
                        Text("我提交的").tag(1)
                        Text("全部").tag(2)
                    }
                    .onChange(of: store.jiraSourceMode) { _, _ in saveState.triggerSave() }
                }
            }

            if store.issueTrackerEnabled {
                Section {
                    Toggle("手动", isOn: Bindable(store).issueSourceManualEnabled)
                        .onChange(of: store.issueSourceManualEnabled) { _, _ in saveState.triggerSave() }
                    Toggle("Jira 入口", isOn: Bindable(store).issueSourceJiraEnabled)
                        .onChange(of: store.issueSourceJiraEnabled) { _, _ in saveState.triggerSave() }
                    Toggle("Meta Direct Support", isOn: Bindable(store).issueSourceMetaEnabled)
                        .onChange(of: store.issueSourceMetaEnabled) { _, _ in saveState.triggerSave() }
                    Toggle("飞书文档", isOn: Bindable(store).issueSourceFeishuDocEnabled)
                        .onChange(of: store.issueSourceFeishuDocEnabled) { _, _ in saveState.triggerSave() }
                } header: {
                    Text("反馈入口")
                } footer: {
                    Text("关闭某入口后，问题追踪列表与统计将不再展示该来源的 issue；不会删除已同步数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if store.issueTrackerEnabled {
                Section {
                    ForEach($store.teamMembers) { $member in
                        memberRow($member)
                    }
                    HStack {
                        TextField("添加成员…", text: $newMember)
                            .textFieldStyle(.roundedBorder)
                            .focused($memberFieldFocused)
                            .onSubmit { addMember() }
                        Button("添加") {
                            addMember()
                            memberFieldFocused = true
                        }
                        .disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .onAppear { memberFieldFocused = true }
                } header: {
                    HStack {
                        Text("团队成员")
                        Spacer()
                        if store.linearConfig.enabled, !store.linearConfig.teamId.isEmpty {
                            Button {
                                refreshLinearMembers()
                            } label: {
                                if isImportingFromLinear {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isImportingFromLinear)
                            .help("刷新 Linear 成员列表")

                            Button {
                                importFromLinear()
                            } label: {
                                if isImportingFromLinear {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("从 Linear 导入", systemImage: "square.and.arrow.down")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isImportingFromLinear)
                        }
                    }
                } footer: {
                    if let importError {
                        Text(importError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if store.linearConfig.enabled {
                        Text("导入后可在 Linear 设置中配置成员映射，实现负责人双向同步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("统计") {
                    let total = store.visibleTrackedIssues.count
                    let unresolved = store.visibleTrackedIssues.filter { !$0.status.isResolved && $0.status != .observing }.count
                    HStack {
                        Text("总数")
                        Spacer()
                        Text("\(total)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("未解决")
                        Spacer()
                        Text("\(unresolved)")
                            .monospacedDigit()
                            .foregroundStyle(unresolved > 0 ? .red : .green)
                    }
                    ForEach(IssueType.allCases, id: \.self) { type in
                        let count = store.visibleTrackedIssues.filter { $0.type == type }.count
                        if count > 0 {
                            HStack {
                                Image(systemName: type.icon)
                                    .foregroundStyle(type.color)
                                    .frame(width: 20)
                                Text(type.rawValue)
                                Spacer()
                                Text("\(count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .autoSaveIndicator(saveState)
    }

    private func addMember() {
        let name = newMember.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !store.teamMembers.contains(where: { $0.name == name }) else { return }
        store.teamMembers.append(TeamMember(name: name))
        newMember = ""
        saveState.triggerSave()
    }

    @ViewBuilder
    private func memberRow(_ binding: Binding<TeamMember>) -> some View {
        let member = binding.wrappedValue
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(member.name)
            Spacer()
            Button {
                store.linearConfig.assigneeMapping.removeValue(forKey: member.name)
                store.teamMembers.removeAll { $0.id == member.id }
                saveState.triggerSave()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    private func importFromLinear() {
        importError = nil
        let teamId = store.linearConfig.teamId
        guard !teamId.isEmpty else {
            importError = "请先在 Linear 设置中选择 Team"
            return
        }
        isImportingFromLinear = true
        Task {
            let users = await LinearService.shared.fetchTeamMembers(teamId: teamId)
            await MainActor.run {
                isImportingFromLinear = false
                guard !users.isEmpty else {
                    importError = "未获取到 Linear 成员，请检查 Token / Team"
                    return
                }
                store.linearConfig.teamMembers = users
                var existing = store.teamMembers
                for user in users {
                    if existing.contains(where: { $0.name == user.name }) {
                        continue
                    }
                    existing.append(TeamMember(name: user.name))
                }
                store.teamMembers = existing
                saveState.triggerSave()
            }
        }
    }

    private func refreshLinearMembers() {
        importError = nil
        let teamId = store.linearConfig.teamId
        guard !teamId.isEmpty else { return }
        isImportingFromLinear = true
        Task {
            let users = await LinearService.shared.fetchTeamMembers(teamId: teamId)
            await MainActor.run {
                isImportingFromLinear = false
                guard !users.isEmpty else {
                    importError = "刷新失败，请检查网络"
                    return
                }
                store.linearConfig.teamMembers = users
                saveState.triggerSave()
            }
        }
    }
}

// MARK: - RSS Tab
