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
            DataTab(store: store)
                .tabItem { Label("数据", systemImage: "externaldrive") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(minWidth: 460, minHeight: 420)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("新项目名称", text: $newDept)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加", action: add)
                    .disabled(newDept.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            List {
                ForEach(store.departments, id: \.self) { dept in
                    HStack {
                        if editingDept == dept {
                            TextField("项目名称", text: $editText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { commitRename(dept) }
                            Button("确定") { commitRename(dept) }
                                .buttonStyle(.borderless)
                            Button("取消") { editingDept = nil }
                                .buttonStyle(.borderless)
                        } else {
                            Text(dept)
                            Spacer()
                            Text("\(store.totalCountForDepartment(dept))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                editingDept = dept
                                editText = dept
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                deletingDept = dept
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
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
        panel.nameFieldStringValue = "TechSupportData.json"
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

            Text("版本 \(version)（\(build)）")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("轻量级菜单栏计数器\n快捷键记录，日报提醒，周报汇总")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            Spacer()

            Text("Made with ☕ by Max Li")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
