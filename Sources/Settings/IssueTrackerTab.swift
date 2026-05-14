import SwiftUI

struct IssueTrackerTab: View {
    @Bindable var store: DataStore
    @State private var newMember = ""
    @State private var saveState = AutoSaveState()
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
                Section("团队成员") {
                    ForEach(store.bugTeamMembers, id: \.self) { member in
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(member)
                            Spacer()
                            Button {
                                store.bugTeamMembers.removeAll { $0 == member }
                                saveState.triggerSave()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
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
        guard !name.isEmpty, !store.bugTeamMembers.contains(name) else { return }
        store.bugTeamMembers.append(name)
        newMember = ""
        saveState.triggerSave()
    }
}

// MARK: - RSS Tab
