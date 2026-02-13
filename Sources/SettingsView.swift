import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var store: DataStore

    var body: some View {
        TabView {
            DepartmentTab(store: store)
                .tabItem { Label("项目", systemImage: "building.2") }
            GeneralTab(store: store)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RSSTab(store: store)
                .tabItem { Label("RSS", systemImage: "dot.radiowaves.up.forward") }
            DataTab(store: store)
                .tabItem { Label("数据", systemImage: "externaldrive") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 560, minHeight: 420)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
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

    private let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan, .indigo, .mint, .teal]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                TextField("新项目名称", text: $newDept)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加", action: add)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newDept.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

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
                        HStack(spacing: 10) {
                            Circle()
                                .fill(colors[i % colors.count].gradient)
                                .frame(width: 8, height: 8)
                            Text(dept)
                                .font(.body)
                            if i < 9 {
                                Text("\(store.currentModifierLabel)\(i + 1)")
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
                        .padding(.vertical, 2)
                    }
                }
                .onMove { from, to in
                    store.departments.move(fromOffsets: from, toOffset: to)
                }
            }
        }
        .alert("确认删除「\(deletingDept ?? "")」？", isPresented: Binding(
            get: { deletingDept != nil },
            set: { if !$0 { deletingDept = nil } }
        )) {
            Button("取消", role: .cancel) { deletingDept = nil }
            Button("删除", role: .destructive) {
                if let dept = deletingDept {
                    store.departments.removeAll { $0 == dept }
                }
                deletingDept = nil
            }
        } message: {
            let count = store.totalCountForDepartment(deletingDept ?? "")
            Text(count > 0 ? "该项目已有 \(count) 条历史记录，删除后项目名将从列表移除" : "确定要删除这个项目吗？")
        }
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

    var body: some View {
        Form {
            Section("显示名称") {
                TextField("主标题", text: Bindable(store).popoverTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("小记标题", text: Bindable(store).noteTitle)
                    .textFieldStyle(.roundedBorder)
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
            }

            Section("全局快捷键") {
                HStack {
                    Text("修饰键")
                    Spacer()
                    Picker("", selection: Bindable(store).hotkeyModifier) {
                        ForEach(DataStore.modifierOptions, id: \.id) { opt in
                            Text(opt.label).tag(opt.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
                ForEach(Array(store.departments.prefix(9).enumerated()), id: \.offset) { i, dept in
                    LabeledContent("\(store.currentModifierLabel)\(i + 1)", value: "\(dept) +1")
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
            Section("添加订阅源") {
                TextField("名称", text: $newFeedName)
                    .textFieldStyle(.roundedBorder)
                TextField("URL", text: $newFeedURL)
                    .textFieldStyle(.roundedBorder)
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
                LabeledContent("累计支持次数", value: "\(store.totalSupportCount) 次")
            }

            Section("导出 / 导入") {
                HStack {
                    Button("导出 JSON") {
                        exportData()
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
