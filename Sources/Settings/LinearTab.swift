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
    @State private var projectSearchText = ""
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
                    title: "已选 Team",
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
                    title: "订阅 Project",
                    value: importProjectScopeDisplay,
                    systemImage: "tray.and.arrow.down.fill",
                    tint: store.linearConfig.importProjects.isEmpty ? .secondary : .teal
                )
                SettingsStatusRow(
                    title: "候选处理",
                    value: store.linearConfig.autoImportCandidates ? "自动导入" : "手动确认",
                    systemImage: store.linearConfig.autoImportCandidates ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.square",
                    tint: store.linearConfig.autoImportCandidates ? .green : .secondary
                )
                SettingsStatusRow(
                    title: "成员映射",
                    value: "\(store.linearConfig.assigneeMapping.count) 个",
                    systemImage: "arrow.left.arrow.right.circle",
                    tint: store.linearConfig.assigneeMapping.isEmpty ? .orange : .green
                )
                SettingsHint(text: "未指定任何 Project 时，只候选带飞书反馈特征的 issues；指定 Project 后，会把这些 Project 下未导入的 Linear issues 放进候选队列。开启自动导入后，常规同步会直接写入本地问题。")
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("订阅团队", systemImage: "person.3")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !store.linearConfig.selectedTeams.isEmpty {
                            Text("已选 \(store.linearConfig.selectedTeams.count) 个")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if isLoadingTeams {
                        ProgressView()
                            .controlSize(.small)
                    } else if teams.isEmpty {
                        Text("连接 Linear 后加载可用团队。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(teams) { team in
                            Toggle(isOn: Binding(
                                get: { isTeamSelected(team) },
                                set: { setTeam(team, selected: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(team.name)
                                    Text(team.key)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                TextField("搜索 Linear Project", text: $projectSearchText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(store.linearConfig.teamId.isEmpty || projects.isEmpty)

                HStack {
                    Picker("项目范围", selection: Bindable(store).linearConfig.projectId) {
                        Text("全部（不限项目）").tag("")
                        ForEach(projectPickerProjects) { project in
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
                    store.linearConfig.importProjects.removeAll { $0.id == newId }
                    saveState.triggerSave()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("订阅 Project", systemImage: "tray.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !store.linearConfig.importProjects.isEmpty {
                            Button("清空") {
                                store.linearConfig.importProjects = []
                                saveState.triggerSave()
                            }
                            .controlSize(.small)
                        }
                    }

                    if store.linearConfig.teamId.isEmpty {
                        Text("先勾选一个或多个 Team，再订阅这些团队的 Project。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if importProjectPickerProjects.isEmpty {
                        Text(projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无可选 Project。" : "没有匹配的 Project。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let visibleProjects = Array(importProjectPickerProjects.prefix(30))
                        ForEach(visibleProjects) { project in
                            Toggle(isOn: Binding(
                                get: { isImportProjectSelected(project) },
                                set: { setImportProject(project, selected: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .lineLimit(1)
                                    if let teamName = project.teamName, !teamName.isEmpty {
                                        Text(teamName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if project.id != project.name {
                                        Text(project.id)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        if importProjectPickerProjects.count > visibleProjects.count {
                            Text("继续输入 Project 名称可缩小范围。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Toggle(isOn: Bindable(store).linearConfig.autoImportCandidates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动导入候选队列")
                        Text("开启后，Linear 同步会自动把候选 issue 创建成本地问题，并继续同步状态、负责人和评论。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(store.linearConfig.teamId.isEmpty)
                .onChange(of: store.linearConfig.autoImportCandidates) { _, _ in
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
                Text("团队与 Project 订阅")
            } footer: {
                Text(projectScopeFooterText)
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
                        Picker("", selection: Binding<String>(
                            get: {
                                IssueStatus.fromCaseName(localCase) == nil ? "" : localCase
                            },
                            set: { newValue in
                                store.linearConfig.setStatusMapping(
                                    linearStateName: linearName,
                                    localCase: newValue.isEmpty ? nil : newValue
                                )
                                saveState.triggerSave()
                            }
                        )) {
                            Text("未映射").tag("")
                            ForEach(IssueStatus.allCases, id: \.self) { status in
                                Text(status.rawValue).tag(status.caseName)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                        Spacer()
                        Button {
                            store.linearConfig.setStatusMapping(linearStateName: linearName, localCase: nil)
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
                    ForEach(states.filter { store.linearConfig.mappedStatusCase(for: $0.name) == nil }) { state in
                        HStack(spacing: 8) {
                            Text(state.name)
                                .frame(minWidth: 80, alignment: .leading)
                            Text("→")
                                .foregroundStyle(.secondary)
                            Picker("", selection: Binding<String>(
                                get: {
                                    store.linearConfig.mappedStatusCase(for: state.name) ?? ""
                                },
                                set: { newValue in
                                    store.linearConfig.setStatusMapping(
                                        linearStateName: state.name,
                                        localCase: newValue.isEmpty ? nil : newValue
                                    )
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
                            store.linearConfig.setStatusMapping(linearStateName: name, localCase: newLocalStatus.caseName)
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
        let configuredTeams = store.linearConfig.configuredTeams
        if configuredTeams.count > 1 {
            return "\(configuredTeams.count) 个团队"
        }
        if let team = configuredTeams.first {
            return team.name
        }
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

    private var filteredProjects: [LinearProject] {
        let query = projectSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(query) || project.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var projectPickerProjects: [LinearProject] {
        var result = filteredProjects.filter { $0.teamId == store.linearConfig.teamId }
        let selectedID = store.linearConfig.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedID.isEmpty, !result.contains(where: { $0.id == selectedID }) else {
            return result
        }
        if let selected = projects.first(where: { $0.id == selectedID }) {
            result.insert(selected, at: 0)
        } else {
            let fallbackName = store.linearConfig.projectName.isEmpty ? selectedID : store.linearConfig.projectName
            result.insert(LinearProject(id: selectedID, name: fallbackName), at: 0)
        }
        return result
    }

    private var importProjectPickerProjects: [LinearProject] {
        let primaryProjectID = store.linearConfig.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = filteredProjects.filter { $0.id != primaryProjectID }
        var seen = Set(result.map(\.id))
        for project in store.linearConfig.importProjects
            where project.id != primaryProjectID
                && !seen.contains(project.id)
                && (store.linearConfig.selectedTeams.contains { $0.id == project.teamId } || project.teamId == nil) {
            result.insert(project, at: 0)
            seen.insert(project.id)
        }
        return result
    }

    private var issueScopeDisplay: String {
        if store.linearConfig.teamId.isEmpty {
            return "先选择 Team"
        }
        let projectCount = store.linearConfig.configuredImportProjects.count
        if projectCount == 0 {
            return "Team 全部 issues（手动候选）"
        }
        return "\(projectCount) 个 Project issues"
    }

    private var importProjectScopeDisplay: String {
        let count = store.linearConfig.importProjects.count
        guard count > 0 else { return "未订阅" }
        if count == 1 {
            return store.linearConfig.importProjects[0].name
        }
        return "\(count) 个"
    }

    private var projectScopeFooterText: String {
        let count = store.linearConfig.configuredImportProjects.count
        guard count > 0 else {
            return "手动候选页会显示所选 Team 的全部未导入 issues；自动同步仍只导入带飞书反馈特征的 issues，避免无人确认时批量导入整个 Team。"
        }
        if store.linearConfig.autoImportCandidates {
            return "同步时会自动导入已指定的 \(count) 个 Project 下所有未导入 Linear issues。"
        }
        return "候选队列会读取已指定的 \(count) 个 Project 下所有未导入 Linear issues。"
    }

    private func isImportProjectSelected(_ project: LinearProject) -> Bool {
        store.linearConfig.importProjects.contains { $0.id == project.id }
    }

    private func setImportProject(_ project: LinearProject, selected: Bool) {
        if selected {
            guard !isImportProjectSelected(project) else { return }
            store.linearConfig.importProjects.append(normalizedProject(project))
        } else {
            store.linearConfig.importProjects.removeAll { $0.id == project.id }
        }
        saveState.triggerSave()
    }

    private func normalizedProject(_ project: LinearProject) -> LinearProject {
        let id = project.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinearProject(
            id: id,
            name: name.isEmpty ? id : name,
            teamId: project.teamId ?? store.linearConfig.teamId,
            teamName: project.teamName ?? store.linearConfig.teamName
        )
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
            if store.linearConfig.selectedTeams.isEmpty,
               let legacyTeam = result.first(where: { $0.id == store.linearConfig.teamId }) {
                store.linearConfig.selectedTeams = [legacyTeam]
            } else if !store.linearConfig.selectedTeams.isEmpty {
                store.linearConfig.selectedTeams = store.linearConfig.selectedTeams.map { selected in
                    result.first(where: { $0.id == selected.id }) ?? selected
                }
            }
            isLoadingTeams = false
            if !store.linearConfig.configuredTeams.isEmpty {
                loadProjectsAndStates()
            }
        }
    }

    private func loadProjectsAndStates() {
        let selectedTeams = store.linearConfig.configuredTeams
        guard !selectedTeams.isEmpty else {
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
            var loadedProjects: [LinearProject] = []
            var loadedStates: [LinearState] = []
            var loadedMembers: [LinearUser] = []
            var loadedLabels: [LinearLabel] = []
            for team in selectedTeams {
                async let fetchedProjects = LinearService.shared.fetchProjects(teamId: team.id)
                async let fetchedStates = LinearService.shared.fetchTeamStates(teamId: team.id)
                async let fetchedMembers = LinearService.shared.fetchTeamMembers(teamId: team.id)
                async let fetchedLabels = LinearService.shared.fetchTeamLabels(teamId: team.id)
                loadedProjects += await fetchedProjects.map {
                    LinearProject(id: $0.id, name: $0.name, teamId: team.id, teamName: team.name)
                }
                loadedStates += await fetchedStates
                loadedMembers += await fetchedMembers
                loadedLabels += await fetchedLabels
            }
            let selectedIds = Set(selectedTeams.map(\.id))
            guard Set(store.linearConfig.configuredTeams.map(\.id)) == selectedIds else { return }
            projects = loadedProjects.sorted {
                if $0.teamName == $1.teamName {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return ($0.teamName ?? "").localizedCaseInsensitiveCompare($1.teamName ?? "") == .orderedAscending
            }
            states = uniqueById(loadedStates)
            members = uniqueById(loadedMembers)
            store.linearConfig.teamMembers = members
            store.linearConfig.teamLabels = uniqueById(loadedLabels)
            saveState.triggerSave()
            isLoadingProjects = false
        }
    }

    private func isTeamSelected(_ team: LinearTeam) -> Bool {
        store.linearConfig.selectedTeams.contains { $0.id == team.id }
    }

    private func setTeam(_ team: LinearTeam, selected: Bool) {
        if selected {
            guard !isTeamSelected(team) else { return }
            store.linearConfig.selectedTeams.append(team)
            if store.linearConfig.teamId.isEmpty {
                store.linearConfig.teamId = team.id
                store.linearConfig.teamName = team.name
            }
        } else {
            store.linearConfig.selectedTeams.removeAll { $0.id == team.id }
            store.linearConfig.importProjects.removeAll { $0.teamId == team.id }
            if store.linearConfig.teamId == team.id {
                let newDefault = store.linearConfig.selectedTeams.first
                store.linearConfig.teamId = newDefault?.id ?? ""
                store.linearConfig.teamName = newDefault?.name ?? ""
                store.linearConfig.projectId = ""
                store.linearConfig.projectName = ""
                store.linearConfig.defaultAssigneeId = ""
                store.linearConfig.defaultAssigneeName = ""
            }
        }
        projectSearchText = ""
        loadProjectsAndStates()
        saveState.triggerSave()
    }

    private func uniqueById<T: Identifiable>(_ values: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
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
