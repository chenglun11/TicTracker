import SwiftUI
import ServiceManagement

let departmentColors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint, .teal]

// MARK: - Underline TextField Style

private struct UnderlineTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .multilineTextAlignment(.leading)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
            }
    }
}

struct SettingsView: View {
    @Bindable var store: DataStore

    var body: some View {
        tabContent
            .frame(minWidth: 560, minHeight: 420)
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
            }
    }

    @ViewBuilder
    private var tabContent: some View {
        let tabs = TabView {
            DepartmentTab(store: store)
                .tabItem { Label("项目", systemImage: "building.2") }
            GeneralTab(store: store)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RSSTab(store: store)
                .tabItem { Label("RSS", systemImage: "dot.radiowaves.up.forward") }
            JiraTab(store: store)
                .tabItem { Label("Jira", systemImage: "server.rack") }
            DataTab(store: store)
                .tabItem { Label("数据", systemImage: "externaldrive") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        if #available(macOS 15, *) {
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }
}

// MARK: - Department Tab

private struct DepartmentTab: View {
    @Bindable var store: DataStore
    @State private var newDept = ""
    @State private var editingDept: String?
    @State private var editText = ""
    @State private var deletingDept: String?

    var body: some View {
        VStack(spacing: 0) {
            // Add row
            HStack(spacing: 8) {
                TextField("新项目名称", text: $newDept)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加", action: add)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newDept.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Sort buttons
            HStack {
                Text("项目列表")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("按名称") {
                    withAnimation { store.departments.sort() }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                Button("按次数") {
                    withAnimation {
                        store.departments.sort {
                            store.totalCountForDepartment($0) > store.totalCountForDepartment($1)
                        }
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Department list — native List drag reorder
            List {
                ForEach(Array(store.departments.enumerated()), id: \.element) { i, dept in
                    if editingDept == dept {
                        HStack(spacing: 8) {
                            TextField("项目名称", text: $editText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { commitRename(dept) }
                            Button("确定") { commitRename(dept) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("取消") { editingDept = nil }
                                .controlSize(.small)
                        }
                    } else {
                        deptRow(i: i, dept: dept)
                    }
                }
                .onMove { from, to in
                    store.departments.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .alert("确认删除「\(deletingDept ?? "")」？", isPresented: Binding(
            get: { deletingDept != nil },
            set: { if !$0 { deletingDept = nil } }
        )) {
            Button("取消", role: .cancel) { deletingDept = nil }
            Button("删除", role: .destructive) {
                if let dept = deletingDept {
                    store.departments.removeAll { $0 == dept }
                    store.hotkeyBindings.removeValue(forKey: dept)
                }
                deletingDept = nil
            }
        } message: {
            let count = store.totalCountForDepartment(deletingDept ?? "")
            Text(count > 0 ? "该项目已有 \(count) 条历史记录，删除后项目名将从列表移除" : "确定要删除这个项目吗？")
        }
    }

    @ViewBuilder
    private func deptRow(i: Int, dept: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(departmentColors[i % departmentColors.count].gradient)
                .frame(width: 8, height: 8)
            Text(dept)
                .font(.body)
            if let binding = store.hotkeyBindings[dept] {
                Text(binding.displayString)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            Text("\(store.totalCountForDepartment(dept)) 次")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                editingDept = dept
                editText = dept
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Button {
                deletingDept = dept
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
    }

    private func add() {
        store.addDepartment(newDept)
        newDept = ""
    }

    private func commitRename(_ oldName: String) {
        store.renameDepartment(from: oldName, to: editText)
        editingDept = nil
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Bindable var store: DataStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var reminderEnabled = UserDefaults.standard.bool(forKey: "reminderEnabled")
    @State private var reminderHour: Int = {
        let h = UserDefaults.standard.integer(forKey: "reminderHour")
        return h == 0 && !UserDefaults.standard.bool(forKey: "reminderEnabled") ? 17 : h
    }()
    @State private var reminderMinute: Int = {
        let m = UserDefaults.standard.integer(forKey: "reminderMinute")
        return m == 0 && !UserDefaults.standard.bool(forKey: "reminderEnabled") ? 30 : m
    }()
    @State private var reminderSaved = false
    @State private var summaryEnabled: Bool = UserDefaults.standard.object(forKey: "summaryEnabled") as? Bool ?? true

    var body: some View {
        Form {
            Section("显示名称") {
                TextField("主标题", text: Bindable(store).popoverTitle)
                    .textFieldStyle(UnderlineTextFieldStyle())
                TextField("小记标题", text: Bindable(store).noteTitle)
                    .textFieldStyle(UnderlineTextFieldStyle())
            }

            Section("启动") {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            }

            Section {
                Toggle("日报记录", isOn: Bindable(store).dailyNoteEnabled)
                Text("关闭后隐藏菜单栏中的日报编辑区和查看日报入口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("本周趋势图", isOn: Bindable(store).trendChartEnabled)
                Text("关闭后隐藏菜单栏中的 7 日趋势图")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("时间戳记录", isOn: Bindable(store).timestampEnabled)
                Text("关闭后点击计数时不再记录具体时间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("功能模块")
            }

            Section("日报提醒") {
                Toggle("每天提醒写日报", isOn: $reminderEnabled)
                    .onChange(of: reminderEnabled) { _, on in
                        UserDefaults.standard.set(on, forKey: "reminderEnabled")
                        if on {
                            applyReminder()
                        } else {
                            NotificationManager.shared.cancelReminder()
                        }
                    }
                if reminderEnabled {
                    HStack {
                        Text("提醒时间")
                        Spacer()
                        Picker("时", selection: $reminderHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 70)
                        Text(":")
                        Picker("分", selection: $reminderMinute) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 70)
                        Button(reminderSaved ? "已保存 ✓" : "保存") {
                            applyReminder()
                            reminderSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                reminderSaved = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                if reminderEnabled {
                    Toggle("下班工作摘要", isOn: $summaryEnabled)
                        .onChange(of: summaryEnabled) { _, on in
                            UserDefaults.standard.set(on, forKey: "summaryEnabled")
                            if on {
                                applyReminder()
                            } else {
                                NotificationManager.shared.cancelSummary()
                            }
                        }
                    Text("在日报提醒 30 分钟后推送今日工作统计")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("快捷键") {
                Toggle("启用全局快捷键", isOn: Bindable(store).hotkeyEnabled)
                Text("关闭后所有全局快捷键将被注销")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.hotkeyEnabled {
                    ForEach(store.departments, id: \.self) { dept in
                        HStack {
                            Text(dept)
                            Spacer()
                            HotkeyRecorderView(
                                binding: Binding(
                                    get: { store.hotkeyBindings[dept] },
                                    set: {
                                        if let b = $0 {
                                            store.hotkeyBindings[dept] = b
                                        } else {
                                            store.hotkeyBindings.removeValue(forKey: dept)
                                        }
                                    }
                                ),
                                allBindings: store.hotkeyBindings,
                                currentDept: dept
                            )
                        }
                    }
                    LabeledContent("快速日报", value: "首个修饰键+0")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            NotificationManager.shared.requestPermission()
        }
    }

    private func applyReminder() {
        UserDefaults.standard.set(reminderHour, forKey: "reminderHour")
        UserDefaults.standard.set(reminderMinute, forKey: "reminderMinute")
        NotificationManager.shared.scheduleReminder(hour: reminderHour, minute: reminderMinute)
    }
}

// MARK: - RSS Tab

private struct RSSTab: View {
    @Bindable var store: DataStore
    @State private var newFeedName = ""
    @State private var newFeedURL = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var deletingFeed: RSSFeed?

    var body: some View {
        Form {
            Section("RSS 订阅") {
                Toggle("启用 RSS 订阅", isOn: Bindable(store).rssEnabled)
                Text("关闭后停止轮询和推送通知，菜单栏中隐藏 RSS 入口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.rssEnabled {
                Section("添加订阅源") {
                    TextField("名称", text: $newFeedName)
                        .textFieldStyle(UnderlineTextFieldStyle())
                    TextField("URL", text: $newFeedURL)
                        .textFieldStyle(UnderlineTextFieldStyle())
                    HStack {
                        Button("添加") { addFeed() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newFeedName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      newFeedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("订阅列表") {
                    if store.rssFeeds.isEmpty {
                        Text("暂无订阅源")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(store.rssFeeds.enumerated()), id: \.element.id) { i, feed in
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { feed.enabled },
                                    set: { store.rssFeeds[i].enabled = $0 }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(feed.name).font(.body)
                                    Text(feed.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text("\(store.rssItems[feed.id.uuidString]?.count ?? 0) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button {
                                    testFeed(feed)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled(checking)
                                .help("立即检查")

                                Button {
                                    deletingFeed = feed
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("轮询设置") {
                    HStack {
                        Text("检查间隔")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.rssPollingInterval },
                            set: {
                                store.rssPollingInterval = $0
                                RSSFeedManager.shared.restartPolling()
                            }
                        )) {
                            Text("5 分钟").tag(5)
                            Text("10 分钟").tag(10)
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("60 分钟").tag(60)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }

                    Button(checking ? "检查中…" : "立即检查全部") {
                        checkAll()
                    }
                    .controlSize(.small)
                    .disabled(checking || store.rssFeeds.isEmpty)
                }

                if let result = checkResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("失败") || result.contains("无效") ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .alert("确认删除「\(deletingFeed?.name ?? "")」？", isPresented: Binding(
            get: { deletingFeed != nil },
            set: { if !$0 { deletingFeed = nil } }
        )) {
            Button("取消", role: .cancel) { deletingFeed = nil }
            Button("删除", role: .destructive) {
                if let feed = deletingFeed {
                    store.rssFeeds.removeAll { $0.id == feed.id }
                    store.rssItems.removeValue(forKey: feed.id.uuidString)
                }
                deletingFeed = nil
            }
        }
    }

    private func addFeed() {
        let name = newFeedName.trimmingCharacters(in: .whitespaces)
        let url = newFeedURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty, URL(string: url)?.scheme != nil else { return }
        let feed = RSSFeed(name: name, url: url)
        store.rssFeeds.append(feed)
        newFeedName = ""
        newFeedURL = ""
    }

    private func testFeed(_ feed: RSSFeed) {
        checking = true
        checkResult = nil
        Task {
            let result = await RSSFeedManager.shared.checkFeed(feed)
            switch result {
            case .success(let newCount, let totalCount):
                checkResult = newCount > 0
                    ? "获取到 \(newCount) 条新条目（共 \(totalCount) 条）"
                    : "已是最新（共 \(totalCount) 条）"
            case .empty:
                checkResult = "连接成功，但该 feed 暂无条目"
            case .fetchError:
                checkResult = "获取失败，请检查网络或 URL"
            case .invalidURL:
                checkResult = "URL 格式无效"
            }
            checking = false
        }
    }

    private func checkAll() {
        checking = true
        checkResult = nil
        Task {
            await RSSFeedManager.shared.checkAllFeeds()
            let total = store.rssFeeds.reduce(0) { $0 + (store.rssItems[$1.id.uuidString]?.count ?? 0) }
            checkResult = "检查完成，共 \(total) 条"
            checking = false
        }
    }
}

// MARK: - Jira Tab

private struct JiraTab: View {
    @Bindable var store: DataStore
    @State private var tokenInput = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSuccess = false

    private let jqlPresets: [(label: String, jql: String)] = [
        ("待处理", "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"),
        ("本周完成", "assignee=currentUser() AND resolved >= startOfWeek() ORDER BY resolved DESC"),
        ("近7天完成", "assignee=currentUser() AND resolved >= -7d ORDER BY resolved DESC"),
        ("全部", "assignee=currentUser() ORDER BY updated DESC"),
    ]

    var body: some View {
        Form {
            Section("连接") {
                TextField("服务器地址", text: Bindable(store).jiraConfig.serverURL, prompt: Text("https://jira.example.com"))
                    .textFieldStyle(UnderlineTextFieldStyle())
                Picker("认证方式", selection: Bindable(store).jiraConfig.authMode) {
                    Text("用户名 + 密码").tag(JiraAuthMode.password)
                    Text("Personal Access Token").tag(JiraAuthMode.pat)
                }
                .pickerStyle(.segmented)
                if store.jiraConfig.authMode == .password {
                    TextField("用户名", text: Bindable(store).jiraConfig.username)
                        .textFieldStyle(UnderlineTextFieldStyle())
                    SecureField("密码", text: $tokenInput)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onSubmit { saveToken() }
                } else {
                    SecureField("Token", text: $tokenInput)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onSubmit { saveToken() }
                    Text("在 Jira 个人设置中生成 Personal Access Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("保存") { saveToken() }
                        .controlSize(.small)
                        .disabled(tokenInput.isEmpty)
                    Button(testing ? "测试中…" : "测试连接") {
                        saveToken()
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
                    }
                }
                HStack {
                    Text("轮询时段")
                    Spacer()
                    Picker("", selection: Bindable(store).jiraConfig.pollingStartHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 80)
                    Text("—")
                        .foregroundStyle(.tertiary)
                    Picker("", selection: Bindable(store).jiraConfig.pollingEndHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
            }

            Section("显示") {
                Toggle("自动轮询 Jira 工单", isOn: Bindable(store).jiraConfig.enabled)
                    .onChange(of: store.jiraConfig.enabled) { _, enabled in
                        if enabled {
                            JiraService.shared.startPolling()
                        } else {
                            JiraService.shared.stopPolling()
                        }
                    }
                Toggle("在菜单栏显示工单列表", isOn: Bindable(store).jiraConfig.showInMenuBar)
            }

            Section("自动映射规则") {
                Text("工单按字段自动关联到项目，从上到下匹配第一条命中的规则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(store.jiraConfig.mappingRules.enumerated()), id: \.element.id) { i, rule in
                    HStack(spacing: 6) {
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
                            .frame(width: 100)

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
                        .frame(width: 100)

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
                Button("添加规则") {
                    store.jiraConfig.mappingRules.append(
                        JiraMappingRule(field: .issueType, value: "", department: "")
                    )
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let data = KeychainHelper.load(), let str = String(data: data, encoding: .utf8) {
                tokenInput = str
            }
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

// MARK: - Data Tab

private struct DataTab: View {
    @Bindable var store: DataStore
    @State private var showClearTodayAlert = false
    @State private var showClearAllAlert = false
    @State private var importResult: String?

    var body: some View {
        Form {
            Section("统计") {
                LabeledContent("已记录天数", value: "\(store.totalDaysTracked) 天")
                LabeledContent("累计点击次数", value: "\(store.totalSupportCount) 次")
            }

            Section("导出 / 导入") {
                HStack {
                    Button("导出 JSON") {
                        exportData()
                    }
                    Button("导出 CSV") {
                        exportCSV()
                    }
                    Button("导入 JSON") {
                        importData()
                    }
                }
                if let result = importResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("成功") ? .green : .red)
                }
            }

            Section("清除数据") {
                HStack {
                    Button("清除今日数据") {
                        showClearTodayAlert = true
                    }
                    Button("清除全部历史") {
                        showClearAllAlert = true
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .alert("确认清除今日数据？", isPresented: $showClearTodayAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { store.clearToday() }
        } message: {
            Text("今日的支持记录和日报将被删除")
        }
        .alert("确认清除全部历史？", isPresented: $showClearAllAlert) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) { store.clearAllHistory() }
        } message: {
            Text("所有支持记录和日报将被永久删除，此操作不可撤销")
        }
    }

    private func exportData() {
        guard let json = store.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TicTrackerData.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportCSV() {
        let csv = store.exportCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "TicTrackerData.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            importResult = store.importJSON(from: content) ? "导入成功" : "导入失败：格式不正确"
        }
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

            Text("TicTracker")
                .font(.title2.bold())

            Text("版本 \(version) · Build \(build)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("轻量级菜单栏计数器\n快捷键记录，日报提醒，周报汇总")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Button("检查更新") {
                UpdateChecker.shared.checkNow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer()

            Text("Made with ☕ by Max Li")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
