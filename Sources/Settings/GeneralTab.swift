import SwiftUI
import ServiceManagement
import AppKit

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
    @State private var localMCPEnabled = UserDefaults.standard.bool(forKey: LocalMCPServer.enabledKey)
    @State private var localMCPPortText: String = {
        let value = UserDefaults.standard.integer(forKey: LocalMCPServer.portKey)
        return value == 0 ? "8765" : "\(value)"
    }()
    @State private var localMCPReadAK = UserDefaults.standard.string(forKey: LocalMCPServer.readAccessKeyKey) ?? ""
    @State private var localMCPWriteAK = UserDefaults.standard.string(forKey: LocalMCPServer.writeAccessKeyKey) ?? ""
    @State private var mcpServer = LocalMCPServer.shared
    @State private var pluginInstallMessage: String?
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

            Section("本地 MCP") {
                Toggle(isOn: $localMCPEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用本地 MCP 服务")
                        Text("仅监听 127.0.0.1，供本机 MCP Client 读取计数、问题追踪和创建 Linear 问题")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: localMCPEnabled) { _, _ in applyLocalMCPSettings() }

                HStack {
                    Text("端口")
                    TextField("", text: $localMCPPortText, prompt: Text("8765"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { applyLocalMCPSettings() }
                        .onChange(of: localMCPPortText) { _, _ in applyLocalMCPSettings() }
                    Spacer()
                    Text(mcpServer.statusText)
                        .font(.caption)
                        .foregroundStyle(localMCPStatusColor)
                }
                if !mcpServer.statusDetail.isEmpty {
                    Text(mcpServer.statusDetail)
                        .font(.caption)
                        .foregroundStyle(localMCPStatusColor)
                        .textSelection(.enabled)
                }

                SecureField("只读 AK", text: $localMCPReadAK)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyLocalMCPSettings() }
                    .onChange(of: localMCPReadAK) { _, _ in applyLocalMCPSettings() }
                SecureField("可写 AK", text: $localMCPWriteAK)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyLocalMCPSettings() }
                    .onChange(of: localMCPWriteAK) { _, _ in applyLocalMCPSettings() }

                HStack {
                    Button("生成只读 AK") {
                        localMCPReadAK = generateAccessKey()
                        applyLocalMCPSettings()
                    }
                    Button("生成可写 AK") {
                        localMCPWriteAK = generateAccessKey()
                        applyLocalMCPSettings()
                    }
                    Button("应用") {
                        applyLocalMCPSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)

                Divider()

                HStack {
                    Button("安装到 Codex") {
                        openCodexPluginInstaller()
                    }
                    Button("安装到 Claude Code") {
                        prepareClaudeCodePluginInstall()
                    }
                }
                .controlSize(.small)

                if let pluginInstallMessage {
                    Text(pluginInstallMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
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

    private var localMCPStatusColor: Color {
        switch mcpServer.statusText {
        case "运行中":
            return .green
        case "启动失败":
            return .red
        case "启动中":
            return .orange
        default:
            return .secondary
        }
    }

    private func applyReminder() {
        UserDefaults.standard.set(reminderHour, forKey: "reminderHour")
        UserDefaults.standard.set(reminderMinute, forKey: "reminderMinute")
        NotificationManager.shared.scheduleReminder(hour: reminderHour, minute: reminderMinute)
    }

    private func applyLocalMCPSettings() {
        let port = Int(localMCPPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8765
        UserDefaults.standard.set(localMCPEnabled, forKey: LocalMCPServer.enabledKey)
        UserDefaults.standard.set(max(1, min(port, 65535)), forKey: LocalMCPServer.portKey)
        UserDefaults.standard.set(localMCPReadAK.trimmingCharacters(in: .whitespacesAndNewlines), forKey: LocalMCPServer.readAccessKeyKey)
        UserDefaults.standard.set(localMCPWriteAK.trimmingCharacters(in: .whitespacesAndNewlines), forKey: LocalMCPServer.writeAccessKeyKey)
        LocalMCPServer.shared.restart()
        saveState.triggerSave()
    }

    private func generateAccessKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private func openCodexPluginInstaller() {
        let marketplacePath = "/Users/maxli/.agents/plugins/marketplace.json"
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "plugins"
        components.path = "/tictacker-mcp"
        components.queryItems = [URLQueryItem(name: "marketplacePath", value: marketplacePath)]
        guard let url = components.url else {
            pluginInstallMessage = "无法生成 Codex 插件链接"
            return
        }
        NSWorkspace.shared.open(url)
        pluginInstallMessage = "已打开 Codex 插件安装页"
    }

    private func prepareClaudeCodePluginInstall() {
        do {
            let marketplace = try ensureClaudeCodeMarketplace()
            let command = """
            claude plugin marketplace add \(shellQuoted(marketplace.path))
            claude plugin install tictacker-mcp@tictacker-local
            """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            if let docs = URL(string: "https://code.claude.com/docs/en/plugin-marketplaces") {
                NSWorkspace.shared.open(docs)
            }
            pluginInstallMessage = "Claude Code 安装命令已复制到剪贴板；已打开插件安装文档。"
        } catch {
            pluginInstallMessage = "Claude Code 插件准备失败：\(error.localizedDescription)"
        }
    }

    private func ensureClaudeCodeMarketplace() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("plugins")
            .appendingPathComponent("tictacker-mcp-claude-marketplace")
        let pluginRoot = root
            .appendingPathComponent("plugins")
            .appendingPathComponent("tictacker-mcp")
        let skillRoot = pluginRoot
            .appendingPathComponent("skills")
            .appendingPathComponent("tictacker-mcp")
        let scriptsRoot = pluginRoot.appendingPathComponent("scripts")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: pluginRoot.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try manager.createDirectory(at: skillRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: scriptsRoot, withIntermediateDirectories: true)

        let marketplace: [String: Any] = [
            "name": "tictacker-local",
            "owner": ["name": "Local developer"],
            "plugins": [[
                "name": "tictacker-mcp",
                "source": "./plugins/tictacker-mcp",
                "description": "TicTracker local MCP helpers"
            ]]
        ]
        let plugin: [String: Any] = [
            "name": "tictacker-mcp",
            "description": "TicTracker local MCP helpers",
            "version": "0.1.0",
            "displayName": "TicTracker MCP"
        ]
        try writeJSONObject(marketplace, to: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        try writeJSONObject(plugin, to: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))

        let skill = """
        ---
        name: tictacker-mcp
        description: Use TicTracker local MCP tools for status, issue tracking, and Linear issue creation.
        ---

        Use the local TicTracker MCP server exposed by the macOS app. Prefer the read-only AK for status/list operations and the write AK only when creating or modifying issues.

        Default local endpoint: http://127.0.0.1:8765/mcp
        """
        try skill.write(to: skillRoot.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "Scripts for TicTracker MCP helpers can live here.\n".write(to: scriptsRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return root
    }

    private func writeJSONObject(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

// MARK: - Issue Tracker Tab
