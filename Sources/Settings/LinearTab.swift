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
    @FocusState private var isTokenFocused: Bool
    @State private var saveState = AutoSaveState()
    @State private var didLoadToken = false
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

            Section("团队与项目") {
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
                    loadProjectsAndStates()
                    saveState.triggerSave()
                }

                HStack {
                    Picker("项目", selection: Bindable(store).linearConfig.projectId) {
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
                .onChange(of: store.linearConfig.projectId) { _, newId in
                    if let project = projects.first(where: { $0.id == newId }) {
                        store.linearConfig.projectName = project.name
                    } else {
                        store.linearConfig.projectName = ""
                    }
                    saveState.triggerSave()
                }

                TextField("默认负责人", text: Bindable(store).linearConfig.defaultAssigneeName)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: store.linearConfig.defaultAssigneeName) { _, _ in saveState.debouncedSave() }
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
                    .onChange(of: store.linearConfig.pollingInterval) { _, _ in saveState.triggerSave() }
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
                .onChange(of: store.linearConfig.pollingStartHour) { _, _ in saveState.triggerSave() }
                .onChange(of: store.linearConfig.pollingEndHour) { _, _ in saveState.triggerSave() }
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
                            Picker("", selection: Binding(
                                get: {
                                    if let caseName = store.linearConfig.statusMapping[state.name],
                                       let status = IssueStatus.fromCaseName(caseName) {
                                        return status
                                    }
                                    return IssueStatus.pending
                                },
                                set: { newStatus in
                                    store.linearConfig.statusMapping[state.name] = newStatus.caseName
                                    saveState.triggerSave()
                                }
                            )) {
                                ForEach(IssueStatus.allCases, id: \.self) { s in
                                    Text(s.rawValue).tag(s)
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
            loadTeams()
        }
    }

    private func saveToken() {
        if let data = tokenInput.data(using: .utf8) {
            _ = KeychainHelper.save(service: KeychainHelper.service, account: LinearConfig.keychainTokenKey, data: data)
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
        guard !store.linearConfig.teamId.isEmpty else {
            projects = []
            states = []
            return
        }
        isLoadingProjects = true
        Task {
            async let fetchedProjects = LinearService.shared.fetchProjects(teamId: store.linearConfig.teamId)
            async let fetchedStates = LinearService.shared.fetchTeamStates(teamId: store.linearConfig.teamId)
            projects = await fetchedProjects
            states = await fetchedStates
            isLoadingProjects = false
        }
    }
}
