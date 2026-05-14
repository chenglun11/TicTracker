import SwiftUI
import ServiceManagement

struct GeneralTab: View {
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

