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

// MARK: - Auto-Save SecureField

@MainActor
private func autoSaveSecureField(
    _ title: String,
    text: Binding<String>,
    saved: Binding<Bool>,
    focused: FocusState<Bool>.Binding,
    onSave: @escaping () -> Void
) -> some View {
    SecureField(title, text: text)
        .textFieldStyle(UnderlineTextFieldStyle())
        .focused(focused)
        .onChange(of: focused.wrappedValue) { _, isFocused in
            if !isFocused && !text.wrappedValue.isEmpty {
                onSave()
                saved.wrappedValue = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.8))
                    saved.wrappedValue = false
                }
            }
        }
        .overlay(alignment: .trailing) {
            if saved.wrappedValue {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(.trailing, 8)
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
            IssueTrackerTab(store: store)
                .tabItem { Label("问题追踪", systemImage: "ladybug.fill") }
            JiraTab(store: store)
                .tabItem { Label("Jira", systemImage: "server.rack") }
            FeishuBotTab(store: store)
                .tabItem { Label("飞书 Bot", systemImage: "paperplane.fill") }
            AITab(store: store)
                .tabItem { Label("AI", systemImage: "sparkles") }
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
    @State private var saveState = AutoSaveState()

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
        .onChange(of: store.departments) { _, _ in saveState.triggerSave() }
        .autoSaveIndicator(saveState)
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
    @State private var summaryEnabled: Bool = UserDefaults.standard.object(forKey: "summaryEnabled") as? Bool ?? true
    @State private var saveState = AutoSaveState()

    var body: some View {
        Form {
            Section("显示名称") {
                TextField("主标题", text: Bindable(store).popoverTitle)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: store.popoverTitle) { _, _ in saveState.debouncedSave() }
                TextField("小记标题", text: Bindable(store).noteTitle)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: store.noteTitle) { _, _ in saveState.debouncedSave() }
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

            Section("功能模块") {
                Toggle(isOn: Bindable(store).dailyNoteEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("日记记录")
                        Text("关闭后隐藏菜单栏中的日记编辑区和查看日记入口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.dailyNoteEnabled) { _, _ in saveState.triggerSave() }
                Toggle(isOn: Bindable(store).todoEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待办任务")
                        Text("关闭后隐藏菜单栏中的待办任务入口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.todoEnabled) { _, _ in saveState.triggerSave() }
                Toggle(isOn: Bindable(store).trendChartEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本周趋势图")
                        Text("关闭后隐藏菜单栏中的 7 日趋势图")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.trendChartEnabled) { _, _ in saveState.triggerSave() }
                Toggle(isOn: Bindable(store).timestampEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("时间戳记录")
                        Text("关闭后点击计数时不再记录具体时间")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.timestampEnabled) { _, _ in saveState.triggerSave() }
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
                        saveState.triggerSave()
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
                        .onChange(of: reminderHour) { _, _ in
                            applyReminder()
                            saveState.triggerSave()
                        }
                        Text(":")
                        Picker("分", selection: $reminderMinute) {
                            ForEach(0..<60, id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 70)
                        .onChange(of: reminderMinute) { _, _ in
                            applyReminder()
                            saveState.triggerSave()
                        }
                    }
                }
                if reminderEnabled {
                    Toggle(isOn: $summaryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("下班工作摘要")
                            Text("在日报提醒 30 分钟后推送今日工作统计")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: summaryEnabled) { _, on in
                        UserDefaults.standard.set(on, forKey: "summaryEnabled")
                        if on {
                            applyReminder()
                        } else {
                            NotificationManager.shared.cancelSummary()
                        }
                        saveState.triggerSave()
                    }
                }
            }

            Section("快捷键") {
                Toggle(isOn: Bindable(store).hotkeyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用全局快捷键")
                        Text("关闭后所有全局快捷键将被注销")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.hotkeyEnabled) { _, _ in saveState.triggerSave() }
                if store.hotkeyEnabled {
                    ForEach(Array(store.departments.enumerated()), id: \.element) { i, dept in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(departmentColors[i % departmentColors.count].gradient)
                                .frame(width: 8, height: 8)
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
                    HStack {
                        Circle()
                            .fill(.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        Text("快速日报")
                        Spacer()
                        Text("首个修饰键+0")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .autoSaveIndicator(saveState)
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

// MARK: - Issue Tracker Tab

private struct IssueTrackerTab: View {
    @Bindable var store: DataStore
    @State private var newMember = ""
    @State private var saveState = AutoSaveState()

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
                    Picker("Jira 工单来源", selection: Bindable(store).jiraSourceMode) {
                        Text("指派给我").tag(0)
                        Text("我提交的").tag(1)
                        Text("全部").tag(2)
                    }
                    .onChange(of: store.jiraSourceMode) { _, _ in saveState.triggerSave() }
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
                            .onSubmit { addMember() }
                        Button("添加") { addMember() }
                            .disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("统计") {
                    let total = store.trackedIssues.count
                    let unresolved = store.trackedIssues.filter { !$0.status.isResolved && $0.status != .observing }.count
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
                        let count = store.trackedIssues.filter { $0.type == type }.count
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

private struct RSSTab: View {
    @Bindable var store: DataStore
    @State private var newFeedName = ""
    @State private var newFeedURL = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var deletingFeed: RSSFeed?
    @State private var expandedFeeds: Set<UUID> = []
    @State private var saveState = AutoSaveState()

    var body: some View {
        Form {
            Section("RSS 订阅") {
                Toggle(isOn: Bindable(store).rssEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 RSS 订阅")
                        Text("关闭后停止轮询和推送通知，菜单栏中隐藏 RSS 入口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.rssEnabled) { _, _ in saveState.triggerSave() }
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
                            VStack(alignment: .leading, spacing: 0) {
                                // Main row
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { feed.enabled },
                                        set: {
                                            store.rssFeeds[i].enabled = $0
                                            saveState.triggerSave()
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)

                                    Text(feed.name)
                                        .font(.body)

                                    Spacer()

                                    Text("\(store.rssItems[feed.id.uuidString]?.count ?? 0) 条")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()

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

                                    Button {
                                        withAnimation {
                                            if expandedFeeds.contains(feed.id) {
                                                expandedFeeds.remove(feed.id)
                                            } else {
                                                expandedFeeds.insert(feed.id)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: expandedFeeds.contains(feed.id) ? "chevron.up" : "chevron.down")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(expandedFeeds.contains(feed.id) ? "收起详情" : "展开详情")
                                }

                                // Expanded details
                                if expandedFeeds.contains(feed.id) {
                                    HStack(spacing: 8) {
                                        Text(feed.url)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("轮询间隔")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Picker("", selection: Binding(
                                            get: { feed.pollingInterval },
                                            set: {
                                                store.rssFeeds[i].pollingInterval = $0
                                                RSSFeedManager.shared.restartPolling(for: feed.id)
                                                saveState.triggerSave()
                                            }
                                        )) {
                                            Text("5m").tag(5)
                                            Text("10m").tag(10)
                                            Text("15m").tag(15)
                                            Text("30m").tag(30)
                                            Text("60m").tag(60)
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .frame(width: 60)
                                    }
                                    .padding(.top, 6)
                                    .padding(.leading, 32)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Button(checking ? "检查中…" : "立即检查全部") {
                            checkAll()
                        }
                        .controlSize(.small)
                        .disabled(checking || store.rssFeeds.isEmpty)
                        if checking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let result = checkResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("失败") || result.contains("无效") ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .autoSaveIndicator(saveState)
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
    @State private var tokenSaved = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @FocusState private var isTokenFocused: Bool
    @State private var saveState = AutoSaveState()

    private let jqlPresets: [(label: String, jql: String)] = [
        ("待处理", "assignee=currentUser() AND resolution=Unresolved ORDER BY updated DESC"),
        ("本周完成", "assignee=currentUser() AND resolved >= startOfWeek() ORDER BY resolved DESC"),
        ("近7天完成", "assignee=currentUser() AND resolved >= -7d ORDER BY resolved DESC"),
        ("全部", "assignee=currentUser() ORDER BY updated DESC"),
    ]

    var body: some View {
        Form {
            Section("Jira 集成") {
                Toggle(isOn: Bindable(store).jiraConfig.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 Jira 工单轮询")
                        Text("开启后自动轮询并推送工单变更通知")
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
                        Text("在菜单栏显示")
                        Text("关闭后隐藏菜单栏中的工单列表和底部入口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.jiraConfig.showInMenuBar) { _, _ in saveState.triggerSave() }
            }

            Section("连接 🔒") {
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
        }
        .formStyle(.grouped)
        .autoSaveIndicator(saveState)
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

// MARK: - Feishu Bot Tab

private struct FeishuBotTab: View {
    @Bindable var store: DataStore
    @State private var secretInput = ""
    @State private var secretSaved = false
    @FocusState private var isSecretFocused: Bool
    @State private var saveState = AutoSaveState()
    @State private var sending = false
    @State private var sendResult: String?
    @State private var sendSuccess = false

    var body: some View {
        Form {
            Section("飞书 Bot") {
                Toggle(isOn: Bindable(store).feishuBotConfig.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用飞书 Bot 日报推送")
                        Text("开启后在指定时间自动将每日工单报告发送到飞书群")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.feishuBotConfig.enabled) { _, enabled in
                    if enabled {
                        FeishuBotService.shared.startScheduler()
                    } else {
                        FeishuBotService.shared.stopScheduler()
                    }
                    saveState.triggerSave()
                }
            }

            Section("Webhook") {
                Picker("消息格式", selection: Bindable(store).feishuBotConfig.messageFormat) {
                    ForEach(FeishuMessageFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: store.feishuBotConfig.messageFormat) { _, _ in saveState.triggerSave() }

                TextField("Webhook URL", text: Bindable(store).feishuBotConfig.webhookURL,
                          prompt: Text("https://open.feishu.cn/open-apis/bot/v2/hook/..."))
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: store.feishuBotConfig.webhookURL) { _, _ in saveState.debouncedSave() }

                Toggle("签名校验", isOn: Bindable(store).feishuBotConfig.signEnabled)
                    .onChange(of: store.feishuBotConfig.signEnabled) { _, _ in saveState.triggerSave() }

                if store.feishuBotConfig.signEnabled {
                    autoSaveSecureField("Secret", text: $secretInput, saved: $secretSaved,
                                        focused: $isSecretFocused, onSave: saveSecret)
                }

                HStack {
                    Button(sending ? "发送中…" : "测试发送") {
                        testSend()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(sending || store.feishuBotConfig.webhookURL.isEmpty)

                    if let result = sendResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(sendSuccess ? .green : .red)
                    }

                    Spacer()

                    if !store.feishuBotConfig.lastSentDateTime.isEmpty {
                        Text("上次发送：\(store.feishuBotConfig.lastSentDateTime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("定时发送") {
                ForEach(Array(store.feishuBotConfig.sendTimes.enumerated()), id: \.element.id) { i, scheduleTime in
                    HStack {
                        Picker("", selection: Bindable(store).feishuBotConfig.sendTimes[i].hour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d", h)).tag(h)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 60)
                        Text(":")
                            .foregroundStyle(.tertiary)
                        Picker("", selection: Bindable(store).feishuBotConfig.sendTimes[i].minute) {
                            ForEach(0..<60, id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 60)
                        Spacer()
                        Button {
                            let key = store.feishuBotConfig.sendTimes[i].key
                            store.feishuBotConfig.sendTimes.remove(at: i)
                            store.feishuBotConfig.lastSentTimes.removeValue(forKey: key)
                            FeishuBotService.shared.restartScheduler()
                            saveState.triggerSave()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                    .onChange(of: store.feishuBotConfig.sendTimes[i].hour) { _, _ in
                        store.feishuBotConfig.lastSentTimes.removeValue(forKey: scheduleTime.key)
                        FeishuBotService.shared.restartScheduler()
                        saveState.triggerSave()
                    }
                    .onChange(of: store.feishuBotConfig.sendTimes[i].minute) { _, _ in
                        store.feishuBotConfig.lastSentTimes.removeValue(forKey: scheduleTime.key)
                        FeishuBotService.shared.restartScheduler()
                        saveState.triggerSave()
                    }
                }
                Button("添加时间") {
                    store.feishuBotConfig.sendTimes.append(ScheduleTime(hour: 18, minute: 0))
                    FeishuBotService.shared.restartScheduler()
                    saveState.triggerSave()
                }
                .controlSize(.small)
            }

            Section("卡片模块") {
                Toggle("项目支持统计", isOn: Bindable(store).feishuBotConfig.showSupportStats)
                    .onChange(of: store.feishuBotConfig.showSupportStats) { _, _ in saveState.triggerSave() }
                Toggle("统计概览（新建/解决/待处理）", isOn: Bindable(store).feishuBotConfig.showOverview)
                    .onChange(of: store.feishuBotConfig.showOverview) { _, _ in saveState.triggerSave() }
                Toggle("待处理问题列表", isOn: Bindable(store).feishuBotConfig.showPending)
                    .onChange(of: store.feishuBotConfig.showPending) { _, _ in saveState.triggerSave() }
                Toggle("观测中问题列表", isOn: Bindable(store).feishuBotConfig.showObserving)
                    .onChange(of: store.feishuBotConfig.showObserving) { _, _ in saveState.triggerSave() }
                Toggle("今日已解决列表", isOn: Bindable(store).feishuBotConfig.showResolved)
                    .onChange(of: store.feishuBotConfig.showResolved) { _, _ in saveState.triggerSave() }
                Toggle("日报文字", isOn: Bindable(store).feishuBotConfig.showDailyNote)
                    .onChange(of: store.feishuBotConfig.showDailyNote) { _, _ in saveState.triggerSave() }
                Toggle("问题评论（最近2条）", isOn: Bindable(store).feishuBotConfig.showComments)
                    .onChange(of: store.feishuBotConfig.showComments) { _, _ in saveState.triggerSave() }
            }

            Section("问题显示字段") {
                Toggle("类型", isOn: Bindable(store).feishuBotConfig.fieldType)
                    .onChange(of: store.feishuBotConfig.fieldType) { _, _ in saveState.triggerSave() }
                Toggle("部门", isOn: Bindable(store).feishuBotConfig.fieldDepartment)
                    .onChange(of: store.feishuBotConfig.fieldDepartment) { _, _ in saveState.triggerSave() }
                Toggle("Jira Key", isOn: Bindable(store).feishuBotConfig.fieldJiraKey)
                    .onChange(of: store.feishuBotConfig.fieldJiraKey) { _, _ in saveState.triggerSave() }
                Toggle("状态", isOn: Bindable(store).feishuBotConfig.fieldStatus)
                    .onChange(of: store.feishuBotConfig.fieldStatus) { _, _ in saveState.triggerSave() }
                Toggle("负责人", isOn: Bindable(store).feishuBotConfig.fieldAssignee)
                    .onChange(of: store.feishuBotConfig.fieldAssignee) { _, _ in saveState.triggerSave() }
            }

            Section("发送历史") {
                Picker("失败自动重试", selection: Bindable(store).feishuBotConfig.maxRetries) {
                    Text("不重试").tag(0)
                    Text("1 次").tag(1)
                    Text("2 次").tag(2)
                    Text("3 次").tag(3)
                }
                .onChange(of: store.feishuBotConfig.maxRetries) { _, _ in saveState.triggerSave() }

                if store.feishuBotConfig.sendHistory.isEmpty {
                    Text("暂无发送记录")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(Array(store.feishuBotConfig.sendHistory.prefix(10))) { history in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: history.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(history.success ? .green : .red)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(history.message)
                                    .font(.caption)
                                HStack {
                                    Text(formatTimestamp(history.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if history.retryCount > 0 {
                                        Text("· 重试 \(history.retryCount) 次")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button("清空历史") {
                        store.feishuBotConfig.sendHistory.removeAll()
                        saveState.triggerSave()
                    }
                    .controlSize(.small)
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .autoSaveIndicator(saveState)
        .onAppear {
            if let secret = FeishuBotService.loadSecret() {
                secretInput = secret
            }
        }
    }

    private func saveSecret() {
        FeishuBotService.saveSecret(secretInput)
    }

    private func testSend() {
        if store.feishuBotConfig.signEnabled && !secretInput.isEmpty {
            saveSecret()
        }
        sending = true
        sendResult = nil
        Task {
            let result = await FeishuBotService.shared.sendNow(store: store)
            sendResult = result.message
            sendSuccess = result.success
            if result.success {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                store.feishuBotConfig.lastSentDateTime = fmt.string(from: Date())
                saveState.triggerSave()
            }
            sending = false
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}

// MARK: - AI Tab

private struct AITab: View {
    @Bindable var store: DataStore
    @State private var apiKeyInput = ""
    @State private var baseURLInput = ""
    @State private var modelInput = ""
    @State private var apiKeySaved = false
    @State private var showClearAlert = false
    @FocusState private var isAPIKeyFocused: Bool
    @FocusState private var isBaseURLFocused: Bool
    @FocusState private var isModelFocused: Bool
    @State private var saveState = AutoSaveState()

    // 周报 Prompt 编辑状态
    @State private var customPromptDraft = ""
    @State private var customPromptSaved = false

    // 对话 System Prompt 编辑状态
    @State private var chatSystemPromptDraft = ""
    @State private var chatSystemPromptSaved = false

    var body: some View {
        Form {
            Section("服务商") {
                Picker("AI 服务", selection: Bindable(store).aiConfig.provider) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: store.aiConfig.provider) { _, _ in saveState.triggerSave() }
            }

            Section("连接 🔒") {
                autoSaveSecureField("API Key", text: $apiKeyInput, saved: $apiKeySaved, focused: $isAPIKeyFocused) {
                    AIService.shared.saveAPIKey(apiKeyInput)
                }

                TextField("Base URL（留空使用默认）", text: $baseURLInput)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .font(.callout.monospaced())
                    .focused($isBaseURLFocused)
                    .onChange(of: isBaseURLFocused) { _, focused in
                        if !focused {
                            store.aiConfig.baseURL = baseURLInput
                            AIService.shared.saveBaseURL(baseURLInput)
                            saveState.triggerSave()
                        }
                    }
                Text("默认: \(store.aiConfig.effectiveBaseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("模型（留空使用默认）", text: $modelInput)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .font(.callout.monospaced())
                    .focused($isModelFocused)
                    .onChange(of: isModelFocused) { _, focused in
                        if !focused {
                            store.aiConfig.model = modelInput
                            AIService.shared.saveModel(modelInput)
                            saveState.triggerSave()
                        }
                    }
                Text("默认: \(store.aiConfig.effectiveModel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI 功能") {
                Toggle(isOn: Bindable(store).aiEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 AI 功能")
                        Text("关闭后隐藏 AI 对话入口和周报生成功能")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.aiEnabled) { _, _ in saveState.triggerSave() }
            }

            Section("周报 Prompt") {
                TextEditor(text: $customPromptDraft)
                    .font(.callout)
                    .frame(height: 120)
                    .overlay(alignment: .topLeading) {
                        if customPromptDraft.isEmpty {
                            Text("留空使用默认 Prompt")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    if customPromptDraft.isEmpty {
                        Text("默认: 生成简洁周报摘要，按项目总结，提炼日报要点，不写展望")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("恢复默认") {
                            customPromptDraft = ""
                        }
                        .controlSize(.small)
                    }

                    Spacer()

                    if customPromptSaved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("已保存")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }

                    Button("保存") {
                        store.aiConfig.customPrompt = customPromptDraft
                        customPromptSaved = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            customPromptSaved = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(customPromptDraft == store.aiConfig.customPrompt)
                }
            }

            if store.aiEnabled {
                Section("AI 对话设置") {
                    HStack {
                        Text("最大上下文轮数")
                        Spacer()
                        TextField("", value: Bindable(store).aiConfig.chatMaxHistory, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: store.aiConfig.chatMaxHistory) { _, newValue in
                                if newValue < 1 {
                                    store.aiConfig.chatMaxHistory = 1
                                } else if newValue > 50 {
                                    store.aiConfig.chatMaxHistory = 50
                                }
                                saveState.triggerSave()
                            }
                    }
                    Text("保留最近 \(store.aiConfig.chatMaxHistory) 轮对话作为上下文（1-50）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("对话模型（留空使用周报模型）", text: Bindable(store).aiConfig.chatModel)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .font(.callout.monospaced())
                        .onChange(of: store.aiConfig.chatModel) { _, _ in saveState.debouncedSave() }
                    Text("默认: \(store.aiConfig.effectiveChatModel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("对话 System Prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $chatSystemPromptDraft)
                            .font(.callout)
                            .frame(height: 80)
                            .overlay(alignment: .topLeading) {
                                if chatSystemPromptDraft.isEmpty {
                                    Text("留空使用默认")
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 5)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    HStack {
                        if chatSystemPromptDraft.isEmpty {
                            Text("默认: 友好的 AI 助手")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("恢复默认") {
                                chatSystemPromptDraft = ""
                            }
                            .controlSize(.small)
                        }

                        Spacer()

                        if chatSystemPromptSaved {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("已保存")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }

                        Button("保存") {
                            store.aiConfig.chatSystemPrompt = chatSystemPromptDraft
                            chatSystemPromptSaved = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                chatSystemPromptSaved = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(chatSystemPromptDraft == store.aiConfig.chatSystemPrompt)
                    }
                }

                Section {
                    Button("清空所有 AI 配置", role: .destructive) {
                        showClearAlert = true
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .autoSaveIndicator(saveState)
        .onAppear {
            let stored = AIService.shared.loadAll()
            apiKeyInput = stored.apiKey
            baseURLInput = stored.baseURL.isEmpty ? store.aiConfig.baseURL : stored.baseURL
            modelInput = stored.model.isEmpty ? store.aiConfig.model : stored.model

            // 初始化 draft 状态
            customPromptDraft = store.aiConfig.customPrompt
            chatSystemPromptDraft = store.aiConfig.chatSystemPrompt
        }
        .alert("确认清空所有 AI 配置？", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearAll() }
        } message: {
            Text("将清除 API Key、Base URL、模型和自定义 Prompt")
        }
    }

    private func clearAll() {
        AIService.shared.clearAll()
        apiKeyInput = ""
        baseURLInput = ""
        modelInput = ""
        store.aiConfig = AIConfig()
    }
}

// MARK: - Data Tab

private struct DataTab: View {
    @Bindable var store: DataStore
    @State private var showClearTodayAlert = false
    @State private var showClearAllAlert = false
    @State private var importResult: String?
    @State private var showOperationLog = false
    @State private var showSnapshot = false

    var body: some View {
        Form {
            Section("统计") {
                LabeledContent("已记录天数", value: "\(store.totalDaysTracked) 天")
                LabeledContent("累计点击次数", value: "\(store.totalSupportCount) 次")
            }

            Section("操作记录") {
                HStack {
                    Button("操作日志") {
                        showOperationLog = true
                    }
                    Button("数据快照") {
                        showSnapshot = true
                    }
                }
                HStack {
                    Button("打开数据文件") {
                        openPreferencesInFinder()
                    }
                    Button("打开快照目录") {
                        openSnapshotDirectory()
                    }
                }
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
        .sheet(isPresented: $showOperationLog) {
            OperationLogView()
                .environment(store)
                .frame(minWidth: 600, minHeight: 400)
        }
        .sheet(isPresented: $showSnapshot) {
            SnapshotView()
                .environment(store)
                .frame(minWidth: 600, minHeight: 400)
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

    private func openPreferencesInFinder() {
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        let plistPath = prefsDir.appendingPathComponent("com.maxli.TicTracker.plist").path
        NSWorkspace.shared.selectFile(plistPath, inFileViewerRootedAtPath: prefsDir.path)
    }

    private func openSnapshotDirectory() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let snapshotDir = appSupport.appendingPathComponent("TicTracker/snapshots")
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: snapshotDir.path)
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

            Button("GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/chenglun11/TicTracker")!)
            }
            .buttonStyle(.bordered)
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
