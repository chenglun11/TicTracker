import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: DataStore

    var body: some View {
        TabView {
            departmentsTab
                .tabItem { Text("项目") }

            aiTab
                .tabItem { Text("AI 周报") }

            reminderTab
                .tabItem { Text("提醒") }

            dataTab
                .tabItem { Text("数据") }
        }
        .frame(width: 560, height: 420)
        .padding()
    }

    // MARK: - Departments Tab

    @State private var newDeptName = ""
    @State private var editingDept: String?
    @State private var editingName = ""

    private var departmentsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("项目管理")
                .font(.headline)

            HStack {
                TextField("项目名称（如：研发部）", text: $newDeptName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("添加") {
                    store.addDepartment(newDeptName)
                    newDeptName = ""
                }
                .disabled(newDeptName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            List {
                ForEach(store.departments, id: \.self) { dept in
                    HStack {
                        if editingDept == dept {
                            TextField("新名称", text: $editingName, onCommit: {
                                store.renameDepartment(from: dept, to: editingName)
                                editingDept = nil
                            })
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        } else {
                            Text(dept)
                            Spacer()
                            Text("累计 \(store.totalCountForDepartment(dept))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button(action: {
                            if editingDept == dept {
                                store.renameDepartment(from: dept, to: editingName)
                                editingDept = nil
                            } else {
                                editingDept = dept
                                editingName = dept
                            }
                        }) {
                            Text("✏️")
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
                .onDelete { offsets in
                    store.departments.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    store.departments.move(fromOffsets: from, toOffset: to)
                }
            }

            HStack {
                Text("显示标题")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("标题", text: $store.popoverTitle)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 150)
                Text("笔记标题")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("标题", text: $store.noteTitle)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 150)
            }

            HStack {
                Toggle("显示日记", isOn: $store.dailyNoteEnabled)
                Spacer()
                Toggle("显示趋势图", isOn: $store.trendChartEnabled)
            }
            .font(.caption)
        }
        .padding()
    }

    // MARK: - AI Tab

    @State private var apiKey = ""
    @State private var apiKeySaved = false

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用 AI 周报", isOn: $store.aiEnabled)
                .font(.headline)

            if store.aiEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("服务商")
                            .frame(width: 70, alignment: .trailing)
                        Picker("", selection: $store.aiConfig.provider) {
                            ForEach(AIProvider.allCases, id: \.self) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 200)
                    }

                    HStack {
                        Text("API Key")
                            .frame(width: 70, alignment: .trailing)
                        SecureField("输入 API Key", text: $apiKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Button(apiKeySaved ? "已保存" : "保存") {
                            AIService.shared.saveAPIKey(apiKey)
                            apiKeySaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                apiKeySaved = false
                            }
                        }
                        .disabled(apiKey.isEmpty)
                    }

                    HStack {
                        Text("Base URL")
                            .frame(width: 70, alignment: .trailing)
                        TextField("留空使用默认", text: $store.aiConfig.baseURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    HStack {
                        Text("模型")
                            .frame(width: 70, alignment: .trailing)
                        TextField("留空使用默认 (\(store.aiConfig.effectiveModel))", text: $store.aiConfig.model)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("自定义 Prompt（留空使用默认）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Use a plain TextField for the prompt since TextEditor requires macOS 11
                        TextField("自定义周报生成 Prompt", text: $store.aiConfig.customPrompt)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            apiKey = AIService.shared.loadAPIKey() ?? ""
        }
    }

    // MARK: - Reminder Tab

    @State private var reminderEnabled = UserDefaults.standard.bool(forKey: "reminderEnabled")
    @State private var reminderHour = UserDefaults.standard.object(forKey: "reminderHour") as? Int ?? 17
    @State private var reminderMinute = UserDefaults.standard.object(forKey: "reminderMinute") as? Int ?? 30
    @State private var summaryEnabled: Bool = UserDefaults.standard.object(forKey: "summaryEnabled") as? Bool ?? true

    private var reminderTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("日报提醒")
                .font(.headline)

            Toggle("启用每日提醒", isOn: $reminderEnabled)

            if reminderEnabled {
                HStack {
                    Text("提醒时间")
                    Picker("时", selection: $reminderHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .frame(width: 70)
                    Text(":")
                    Picker("分", selection: $reminderMinute) {
                        ForEach(0..<60, id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .frame(width: 70)
                    Button("保存") {
                        saveReminder()
                    }
                }

                Toggle("提醒后30分钟发送每日摘要", isOn: $summaryEnabled)
                    .font(.caption)
            }

            Spacer()

            Text("通知需要系统授权，请在系统偏好设置中确认已允许 TicTracker 发送通知。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private func saveReminder() {
        UserDefaults.standard.set(reminderEnabled, forKey: "reminderEnabled")
        UserDefaults.standard.set(reminderHour, forKey: "reminderHour")
        UserDefaults.standard.set(reminderMinute, forKey: "reminderMinute")
        UserDefaults.standard.set(summaryEnabled, forKey: "summaryEnabled")
        if reminderEnabled {
            NotificationManager.shared.requestPermission()
            NotificationManager.shared.scheduleReminder(hour: reminderHour, minute: reminderMinute)
        } else {
            NotificationManager.shared.cancelReminder()
            NotificationManager.shared.cancelSummary()
        }
    }

    // MARK: - Data Tab

    @State private var importResult: String?

    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("数据管理")
                .font(.headline)

            HStack {
                Text("已记录 \(store.totalDaysTracked) 天，共 \(store.totalSupportCount) 次")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("导出 JSON") {
                    exportFile(type: "json")
                }
                Button("导出 CSV") {
                    exportFile(type: "csv")
                }
                Button("导入 JSON") {
                    importFile()
                }
            }

            if let result = importResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("成功") ? .green : .red)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("危险操作")
                    .font(.caption)
                    .foregroundColor(.red)

                HStack(spacing: 12) {
                    Button("清除今日数据") {
                        store.clearToday()
                    }
                    Button("清除所有历史") {
                        store.clearAllHistory()
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Text("TicTracker v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
    }

    private func exportFile(type: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TicTracker.\(type)"
        panel.allowedFileTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content: String
        if type == "csv" {
            content = store.exportCSV()
        } else {
            content = store.exportJSON() ?? "{}"
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            if store.importJSON(from: content) {
                importResult = "导入成功！"
            } else {
                importResult = "导入失败：格式不正确"
            }
        } else {
            importResult = "导入失败：无法读取文件"
        }
    }
}
