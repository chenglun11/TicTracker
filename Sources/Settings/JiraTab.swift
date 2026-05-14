import SwiftUI

struct JiraTab: View {
    @Bindable var store: DataStore
    let isActive: Bool
    @State private var tokenInput = ""
    @State private var tokenSaved = false
    @State private var newJiraStatusName = ""
    @State private var newLocalStatus: IssueStatus = .pending
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @FocusState private var isTokenFocused: Bool
    @State private var saveState = AutoSaveState()
    @State private var didLoadToken = false

    private let jqlPresets: [(label: String, jql: String)] = [
        ("待处理", "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"),
        ("本周完成", "assignee=currentUser() AND resolved >= startOfWeek() ORDER BY resolved DESC"),
        ("近7天完成", "assignee=currentUser() AND resolved >= -7d ORDER BY resolved DESC"),
        ("全部", "assignee=currentUser() ORDER BY updated DESC"),
    ]

    var body: some View {
        Form {
            Section("Jira 入口") {
                Toggle(isOn: Bindable(store).jiraConfig.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Jira 入口")
                        Text("开启后作为外部工单入口自动轮询并同步变更")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.jiraConfig.enabled) { _, enabled in
                    if enabled {
                        JiraService.shared.startPolling()
                    } else {
                        JiraService.shared.stopPolling()
                    }
                    saveState.triggerSave()
                }
                Toggle(isOn: Bindable(store).jiraConfig.showInMenuBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("在菜单栏显示入口")
                        Text("关闭后隐藏菜单栏中的入口和刷新按钮")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.jiraConfig.showInMenuBar) { _, _ in saveState.triggerSave() }
            }

            Section("入口配置 🔒") {
                TextField("服务器地址", text: Bindable(store).jiraConfig.serverURL, prompt: Text("https://jira.example.com"))
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: store.jiraConfig.serverURL) { _, _ in saveState.debouncedSave() }
                Picker("认证方式", selection: Bindable(store).jiraConfig.authMode) {
                    Text("用户名 + 密码").tag(JiraAuthMode.password)
                    Text("Personal Access Token").tag(JiraAuthMode.pat)
                }
                .pickerStyle(.segmented)
                .onChange(of: store.jiraConfig.authMode) { _, _ in saveState.triggerSave() }
                if store.jiraConfig.authMode == .pat {
                    Text("在 Jira 个人设置中生成 Personal Access Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if store.jiraConfig.authMode == .password {
                    TextField("用户名", text: Bindable(store).jiraConfig.username)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: store.jiraConfig.username) { _, _ in saveState.debouncedSave() }
                    autoSaveSecureField("密码", text: $tokenInput, saved: $tokenSaved, focused: $isTokenFocused, onSave: saveToken)
                } else {
                    autoSaveSecureField("Token", text: $tokenInput, saved: $tokenSaved, focused: $isTokenFocused, onSave: saveToken)
                }
                HStack {
                    Button(testing ? "测试中…" : "测试连接") {
                        if !tokenInput.isEmpty {
                            saveToken()
                        }
                        testConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(testing || store.jiraConfig.serverURL.isEmpty || tokenInput.isEmpty ||
                              (store.jiraConfig.authMode == .password && store.jiraConfig.username.isEmpty))

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(testSuccess ? .green : .red)
                    }
                }
            }

            Section("查询") {
                HStack(spacing: 6) {
                    Text("预设")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(jqlPresets, id: \.label) { preset in
                        Button(preset.label) {
                            store.jiraConfig.jql = preset.jql
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(store.jiraConfig.jql == preset.jql
                                    ? Color.accentColor : Color.secondary.opacity(0.12),
                                    in: Capsule())
                        .foregroundStyle(store.jiraConfig.jql == preset.jql ? .white : .primary)
                    }
                }
                TextField("JQL", text: Bindable(store).jiraConfig.jql)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .font(.callout.monospaced())
                    .onChange(of: store.jiraConfig.jql) { _, _ in saveState.debouncedSave() }
                HStack {
                    Text("轮询间隔")
                    Spacer()
                    Picker("", selection: Bindable(store).jiraConfig.pollingInterval) {
                        Text("5 分钟").tag(5)
                        Text("10 分钟").tag(10)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .onChange(of: store.jiraConfig.pollingInterval) { _, _ in
                        if store.jiraConfig.enabled {
                            JiraService.shared.restartPolling()
                        }
                        saveState.triggerSave()
                    }
                }
                HStack {
                    Text("轮询时段")
                    Spacer()
                    Picker("", selection: Bindable(store).jiraConfig.pollingStartHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                    Text(":")
                        .foregroundStyle(.tertiary)
                    Picker("", selection: Bindable(store).jiraConfig.pollingStartMinute) {
                        ForEach(0..<60, id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                    Text("—")
                        .foregroundStyle(.tertiary)
                    Picker("", selection: Bindable(store).jiraConfig.pollingEndHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                    Text(":")
                        .foregroundStyle(.tertiary)
                    Picker("", selection: Bindable(store).jiraConfig.pollingEndMinute) {
                        ForEach(0..<60, id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                }
                .onChange(of: store.jiraConfig.pollingStartMinute) { _, _ in
                    if store.jiraConfig.enabled { JiraService.shared.restartPolling() }
                    saveState.triggerSave()
                }
                .onChange(of: store.jiraConfig.pollingEndMinute) { _, _ in
                    if store.jiraConfig.enabled { JiraService.shared.restartPolling() }
                    saveState.triggerSave()
                }
            }

            Section("自动映射规则") {
                Text("工单按字段自动关联到项目，从上到下匹配第一条命中的规则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(store.jiraConfig.mappingRules.enumerated()), id: \.element.id) { i, rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Picker("", selection: Bindable(store).jiraConfig.mappingRules[i].field) {
                                ForEach(JiraMappingField.allCases, id: \.self) { f in
                                    Text(f.label).tag(f)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 80)
                            Text("=")
                                .foregroundStyle(.secondary)
                            TextField("值", text: Bindable(store).jiraConfig.mappingRules[i].value)
                                .textFieldStyle(UnderlineTextFieldStyle())
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Text("→")
                                .foregroundStyle(.secondary)
                            Picker("", selection: Bindable(store).jiraConfig.mappingRules[i].department) {
                                Text("无").tag("")
                                ForEach(store.departments, id: \.self) { dept in
                                    Text(dept).tag(dept)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            Spacer()
                            Button {
                                store.jiraConfig.mappingRules.remove(at: i)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
                Button("添加规则") {
                    store.jiraConfig.mappingRules.append(
                        JiraMappingRule(field: .issueType, value: "", department: "")
                    )
                }
                .controlSize(.small)
            }

            Section("状态映射") {
                Text("将 Jira 状态名映射到本地状态，未命中的按默认 Category 规则处理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(store.jiraConfig.statusMapping.sorted(by: { $0.key < $1.key })), id: \.key) { jiraName, localCase in
                    HStack(spacing: 8) {
                        Text(jiraName)
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
                            store.jiraConfig.statusMapping.removeValue(forKey: jiraName)
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
                HStack(spacing: 8) {
                    TextField("Jira 状态名", text: $newJiraStatusName)
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
                        let name = newJiraStatusName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        store.jiraConfig.statusMapping[name] = newLocalStatus.caseName
                        newJiraStatusName = ""
                        saveState.triggerSave()
                    }
                    .controlSize(.small)
                    .disabled(newJiraStatusName.trimmingCharacters(in: .whitespaces).isEmpty)
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
        if let data = KeychainHelper.load(), let str = String(data: data, encoding: .utf8) {
            tokenInput = str
        }
    }

    private func saveToken() {
        if let data = tokenInput.data(using: .utf8) {
            KeychainHelper.save(data: data)
        }
    }

    private func testConnection() {
        testing = true
        testResult = nil
        Task {
            let result = await JiraService.shared.testConnection()
            switch result {
            case .success:
                testResult = "连接成功"
                testSuccess = true
            case .authError:
                testResult = "认证失败，请检查用户名和 Token"
                testSuccess = false
            case .networkError(let msg):
                testResult = "连接失败：\(msg)"
                testSuccess = false
            case .parseError:
                testResult = "解析失败"
                testSuccess = false
            }
            testing = false
        }
    }
}

// MARK: - Feishu Bot Tab
