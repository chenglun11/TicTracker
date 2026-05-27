import SwiftUI

struct LinearTab: View {
    @Bindable var store: DataStore
    let isActive: Bool
    @State private var tokenInput = ""
    @State private var tokenSaved = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var isTesting = false
    @State private var teams: [LinearTeam] = []
    @State private var projects: [LinearProject] = []
    @State private var states: [LinearState] = []
    @State private var isLoadingTeams = false
    @State private var isLoadingProjects = false
    @State private var members: [LinearUser] = []
    @FocusState private var isTokenFocused: Bool
    @State private var saveState = AutoSaveState()
    @State private var didLoadToken = false

    private var linkedMembers: [TeamMember] {
        store.teamMembers.filter { store.linearConfig.assigneeMapping[$0.name] != nil }
    }
    @State private var newLinearStateName = ""
    @State private var newLocalStatus: IssueStatus = .pending

    var body: some View {
        Form {
            Section("Linear 入口") {
                Toggle(isOn: Bindable(store).linearConfig.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Linear 入口")
                        Text("开启后作为外部工单入口自动轮询并同步变更")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.linearConfig.enabled) { _, newValue in
                    saveState.triggerSave()
                    if newValue {
                        LinearService.shared.restartPolling()
                    } else {
                        LinearService.shared.stopPolling()
                    }
                }
            }

            Section("使用状态") {
                SettingsStatusRow(
                    title: "入口",
                    value: store.linearConfig.enabled ? "已启用" : "未启用",
                    systemImage: "power",
                    tint: store.linearConfig.enabled ? .green : .secondary
                )
                SettingsStatusRow(
                    title: "Team",
                    value: selectedTeamDisplay,
                    systemImage: "person.3.fill",
                    tint: store.linearConfig.teamId.isEmpty ? .orange : .green
                )
                SettingsStatusRow(
                    title: "Project",
                    value: selectedProjectDisplay,
                    systemImage: "folder.fill",
                    tint: store.linearConfig.projectId.isEmpty ? .secondary : .green
                )
                SettingsStatusRow(
                    title: "Issue 范围",
                    value: issueScopeDisplay,
                    systemImage: "line.3.horizontal.decrease.circle",
                    tint: store.linearConfig.teamId.isEmpty ? .orange : .blue
                )
                SettingsStatusRow(
                    title: "成员映射",
                    value: "\(store.linearConfig.assigneeMapping.count) 个",
                    systemImage: "arrow.left.arrow.right.circle",
                    tint: store.linearConfig.assigneeMapping.isEmpty ? .orange : .green
                )
                SettingsHint(text: "Linear 的同步范围是 Team > Project > Issue。未指定 Project 时会读取当前 Team 下的全部 issues；指定 Project 后只跟踪这个项目里的 issues。")
            }

            Section("入口配置 🔒") {
                autoSaveSecureField("API Token", text: $tokenInput, saved: $tokenSaved, focused: $isTokenFocused, onSave: saveToken)
                HStack {
                    Button(isTesting ? "测试中…" : "测试连接") {
                        if !tokenInput.isEmpty {
                            saveToken()
                        }
                        testConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isTesting || tokenInput.isEmpty)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(testSuccess ? .green : .red)
                    }
                }
            }

            Section {
                HStack {
                    Picker("团队", selection: Bindable(store).linearConfig.teamId) {
                        Text("未选择").tag("")
                        ForEach(teams) { team in
                            Text(team.name).tag(team.id)
                        }
                    }
                    .pickerStyle(.menu)
                    if isLoadingTeams {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .onChange(of: store.linearConfig.teamId) { _, newId in
                    if let team = teams.first(where: { $0.id == newId }) {
                        store.linearConfig.teamName = team.name
                    } else {
                        store.linearConfig.teamName = ""
                    }
                    store.linearConfig.projectId = ""
                    store.linearConfig.projectName = ""
                    store.linearConfig.defaultAssigneeId = ""
                    store.linearConfig.defaultAssigneeName = ""
                    loadProjectsAndStates()
                    saveState.triggerSave()
                }

                HStack {
                    Picker("项目范围", selection: Bindable(store).linearConfig.projectId) {
                        Text("全部（不限项目）").tag("")
                        ForEach(projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .pickerStyle(.menu)
                    if isLoadingProjects {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .disabled(store.linearConfig.teamId.isEmpty)
                .onChange(of: store.linearConfig.projectId) { _, newId in
                    if let project = projects.first(where: { $0.id == newId }) {
                        store.linearConfig.projectName = project.name
                    } else {
                        store.linearConfig.projectName = ""
                    }
                    saveState.triggerSave()
                }

                Picker("默认负责人", selection: Bindable(store).linearConfig.defaultAssigneeId) {
                    Text("未指定").tag("")
                    ForEach(linkedMembers) { member in
                        Text(member.name).tag(store.linearConfig.assigneeMapping[member.name] ?? "")
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: store.linearConfig.defaultAssigneeId) { _, newId in
                    if let member = linkedMembers.first(where: { store.linearConfig.assigneeMapping[$0.name] == newId }) {
                        store.linearConfig.defaultAssigneeName = member.name
                    } else {
                        store.linearConfig.defaultAssigneeName = ""
                    }
                    saveState.triggerSave()
                }
                if linkedMembers.isEmpty {
                    Text("请在下方「成员映射」中绑定 Linear 成员与本地成员。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("团队与项目")
            } footer: {
                Text(store.linearConfig.projectId.isEmpty ? "当前没有限定 Project，会同步 Team 下所有符合条件的 issues。" : "当前只同步所选 Project 下的 issues。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("成员映射") {
                if members.isEmpty {
                    Text("选择 Team 后 Linear 成员会自动加载，届时可配置映射。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(members) { linearUser in
                        HStack {
                            Text(linearUser.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            Picker("", selection: Binding(
                                get: { localNameForLinearUser(linearUser.id) },
                                set: { newLocalName in
                                    setMapping(linearUserId: linearUser.id, localName: newLocalName)
                                }
                            )) {
                                Text("未映射").tag("")
                                ForEach(store.teamMembers) { tm in
                                    Text(tm.name).tag(tm.name)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 140)
                        }
                    }
                    if store.teamMembers.isEmpty {
                        Text("先在「问题追踪 > 团队成员」中添加本地成员。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("标签映射") {
                if store.linearConfig.teamLabels.isEmpty {
                    Text("选择 Team 后 Linear 标签会自动加载，届时可配置映射。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("将 Linear 标签映射到本地类型，同步时自动设置 issue 类型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(store.linearConfig.teamLabels) { label in
                        HStack {
                            Text(label.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.tertiary)
                            Picker("", selection: Binding(
                                get: { store.linearConfig.labelMapping[label.name] ?? "" },
                                set: { newValue in
                                    if newValue.isEmpty {
                                        store.linearConfig.labelMapping.removeValue(forKey: label.name)
                                    } else {
                                        store.linearConfig.labelMapping[label.name] = newValue
                                    }
                                    saveState.triggerSave()
                                }
                            )) {
                                Text("未映射").tag("")
                                ForEach(IssueType.allCases, id: \.self) { type in
                                    Text(type.rawValue).tag(type.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 120)
                        }
                    }
                }
            }

            Section("轮询") {
                HStack {
                    Text("轮询间隔")
                    Spacer()
                    Picker("", selection: Bindable(store).linearConfig.pollingInterval) {
                        Text("5 分钟").tag(5)
                        Text("10 分钟").tag(10)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .onChange(of: store.linearConfig.pollingInterval) { _, _ in
                        saveState.triggerSave()
                        if store.linearConfig.enabled {
                            LinearService.shared.restartPolling()
                        }
                    }
                }
                HStack {
                    Text("轮询时段")
                    Spacer()
                    Picker("", selection: Bindable(store).linearConfig.pollingStartHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 80)
                    Text("—")
                        .foregroundStyle(.tertiary)
                    Picker("", selection: Bindable(store).linearConfig.pollingEndHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
                .onChange(of: store.linearConfig.pollingStartHour) { _, _ in
                    saveState.triggerSave()
                    if store.linearConfig.enabled {
                        LinearService.shared.restartPolling()
                    }
                }
                .onChange(of: store.linearConfig.pollingEndHour) { _, _ in
                    saveState.triggerSave()
                    if store.linearConfig.enabled {
                        LinearService.shared.restartPolling()
                    }
                }
            }

            Section("状态映射") {
                Text("将 Linear 状态映射到本地状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(store.linearConfig.statusMapping.sorted(by: { $0.key < $1.key })), id: \.key) { linearName, localCase in
                    HStack(spacing: 8) {
                        Text(linearName)
                            .frame(minWidth: 80, alignment: .leading)
                        Text("→")
                            .foregroundStyle(.secondary)
                        if let status = IssueStatus.fromCaseName(localCase) {
                            Text(status.rawValue)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(localCase)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Button {
                            store.linearConfig.statusMapping.removeValue(forKey: linearName)
                            saveState.triggerSave()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
                if !states.isEmpty {
                    ForEach(states.filter { store.linearConfig.statusMapping[$0.name] == nil }) { state in
                        HStack(spacing: 8) {
                            Text(state.name)
                                .frame(minWidth: 80, alignment: .leading)
                            Text("→")
                                .foregroundStyle(.secondary)
                            Picker("", selection: Binding<String>(
                                get: {
                                    store.linearConfig.statusMapping[state.name] ?? ""
                                },
                                set: { newValue in
                                    if newValue.isEmpty {
                                        store.linearConfig.statusMapping.removeValue(forKey: state.name)
                                    } else {
                                        store.linearConfig.statusMapping[state.name] = newValue
                                    }
                                    saveState.triggerSave()
                                }
                            )) {
                                Text("未映射").tag("")
                                ForEach(IssueStatus.allCases, id: \.self) { s in
                                    Text(s.rawValue).tag(s.caseName)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 100)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("Linear 状态名", text: $newLinearStateName)
                            .textFieldStyle(UnderlineTextFieldStyle())
                            .frame(minWidth: 100)
                        Text("→")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $newLocalStatus) {
                            ForEach(IssueStatus.allCases, id: \.self) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                        Button("添加") {
                            let name = newLinearStateName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            store.linearConfig.statusMapping[name] = newLocalStatus.caseName
                            newLinearStateName = ""
                            saveState.triggerSave()
                        }
                        .controlSize(.small)
                        .disabled(newLinearStateName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .tunedForResponsiveScroll()
        .autoSaveIndicator(saveState)
        .onChange(of: isActive) { _, active in
            if active { loadTokenIfNeeded() }
        }
        .task {
            if isActive { loadTokenIfNeeded() }
        }
    }

    private func loadTokenIfNeeded() {
        guard !didLoadToken else { return }
        didLoadToken = true
        if let data = KeychainHelper.load(service: KeychainHelper.service, account: LinearConfig.keychainTokenKey),
           let str = String(data: data, encoding: .utf8) {
            tokenInput = str
            LinearService.shared.updateCachedToken(str)
            loadTeams()
        }
    }

    private var selectedTeamDisplay: String {
        if !store.linearConfig.teamName.isEmpty {
            return store.linearConfig.teamName
        }
        return store.linearConfig.teamId.isEmpty ? "未选择" : "已选择"
    }

    private var selectedProjectDisplay: String {
        if !store.linearConfig.projectName.isEmpty {
            return store.linearConfig.projectName
        }
        return store.linearConfig.projectId.isEmpty ? "全部 Project" : "已选择"
    }

    private var issueScopeDisplay: String {
        if store.linearConfig.teamId.isEmpty {
            return "先选择 Team"
        }
        if store.linearConfig.projectId.isEmpty {
            return "Team 下全部 issues"
        }
        return "所选 Project issues"
    }

    private func saveToken() {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            KeychainHelper.delete(service: KeychainHelper.service, account: LinearConfig.keychainTokenKey)
            LinearService.shared.updateCachedToken(nil)
            return
        }

        if let data = trimmed.data(using: .utf8),
           KeychainHelper.save(service: KeychainHelper.service, account: LinearConfig.keychainTokenKey, data: data) {
            LinearService.shared.updateCachedToken(trimmed)
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            let error = await LinearService.shared.testConnection()
            if error == .ok {
                testResult = "连接成功"
                testSuccess = true
                loadTeams()
            } else {
                testResult = error.rawValue
                testSuccess = false
            }
            isTesting = false
        }
    }

    private func loadTeams() {
        isLoadingTeams = true
        Task {
            let result = await LinearService.shared.fetchTeams()
            teams = result
            isLoadingTeams = false
            if !store.linearConfig.teamId.isEmpty {
                loadProjectsAndStates()
            }
        }
    }

    private func loadProjectsAndStates() {
        let teamId = store.linearConfig.teamId
        guard !teamId.isEmpty else {
            projects = []
            states = []
            members = []
            store.linearConfig.teamMembers = []
            store.linearConfig.teamLabels = []
            isLoadingProjects = false
            return
        }
        isLoadingProjects = true
        Task {
            async let fetchedProjects = LinearService.shared.fetchProjects(teamId: teamId)
            async let fetchedStates = LinearService.shared.fetchTeamStates(teamId: teamId)
            async let fetchedMembers = LinearService.shared.fetchTeamMembers(teamId: teamId)
            async let fetchedLabels = LinearService.shared.fetchTeamLabels(teamId: teamId)
            let loadedProjects = await fetchedProjects
            let loadedStates = await fetchedStates
            let loadedMembers = await fetchedMembers
            let loadedLabels = await fetchedLabels
            guard store.linearConfig.teamId == teamId else {
                if store.linearConfig.teamId.isEmpty {
                    isLoadingProjects = false
                }
                return
            }
            projects = loadedProjects
            states = loadedStates
            members = loadedMembers
            store.linearConfig.teamMembers = loadedMembers
            store.linearConfig.teamLabels = loadedLabels
            saveState.triggerSave()
            isLoadingProjects = false
        }
    }

    // MARK: - Assignee Mapping Helpers

    /// Reverse lookup: given a Linear user ID, find which local member name is mapped to it.
    private func localNameForLinearUser(_ linearUserId: String) -> String {
        store.linearConfig.assigneeMapping.first(where: { $0.value == linearUserId })?.key ?? ""
    }

    /// Set or clear the mapping for a Linear user.
    private func setMapping(linearUserId: String, localName: String) {
        // Remove any existing mapping pointing to this Linear user
        for (key, value) in store.linearConfig.assigneeMapping where value == linearUserId {
            store.linearConfig.assigneeMapping.removeValue(forKey: key)
        }
        // Set new mapping if a local name was selected
        if !localName.isEmpty {
            store.linearConfig.assigneeMapping[localName] = linearUserId
        }
        saveState.triggerSave()
    }
}
