import SwiftUI

struct SyncTab: View {
    @Bindable var store: DataStore
    let isActive: Bool
    @State private var syncManager = SyncManager.shared
    @State private var credentialInput = ""
    @State private var webPortalTokenInput = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSuccess = false
    @State private var syncing = false
    @State private var didLoadSyncSecrets = false

    var body: some View {
        Form {
            let webPortalURL = syncManager.makeWebPortalURL(token: webPortalTokenInput)
            Section("云端同步") {
                Toggle(isOn: $syncManager.config.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用数据同步")
                        Text("自动同步数据到云端，支持多设备")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: syncManager.config.enabled) { _, enabled in
                    if enabled {
                        syncManager.startPeriodicSync(store: store)
                    } else {
                        syncManager.stopPeriodicSync()
                    }
                }
            }

            Section("同步后端") {
                Picker("存储方式", selection: $syncManager.config.backend) {
                    ForEach(SyncConfig.Backend.allCases, id: \.self) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: syncManager.config.backend) { _, _ in
                    credentialInput = syncManager.loadCredential()
                }

                switch syncManager.config.backend {
                case .iCloud:
                    Text("通过 iCloud Drive 文件同步，无需额外配置，登录 Apple ID 即可")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .webDAV:
                    TextField("WebDAV URL", text: $syncManager.config.serverURL,
                              prompt: Text("https://dav.example.com/sync"))
                        .textFieldStyle(UnderlineTextFieldStyle())
                    TextField("用户名", text: $syncManager.config.username)
                        .textFieldStyle(UnderlineTextFieldStyle())
                    SecureField("密码", text: $credentialInput)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: credentialInput) { _, _ in saveCredential() }
                case .httpAPI:
                    TextField("同步服务器 URL", text: $syncManager.config.serverURL,
                              prompt: Text("https://sync.example.com"))
                        .textFieldStyle(UnderlineTextFieldStyle())
                    SecureField("同步 Token", text: $credentialInput)
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: credentialInput) { _, _ in saveCredential() }
                    Text("这里只用于 /sync 数据同步，不再承担网页后台登录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(testing ? "测试中…" : "测试连接") {
                        testConnection()
                    }
                    .controlSize(.small)
                    .disabled(testing)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(testSuccess ? .green : .red)
                    }
                }
            }

            Section("网页面板") {
                TextField("网页地址", text: $syncManager.config.webPortalURL,
                          prompt: Text("留空则默认使用同步服务器地址"))
                    .textFieldStyle(UnderlineTextFieldStyle())
                SecureField("网页访问 Token", text: $webPortalTokenInput)
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: webPortalTokenInput) { _, _ in
                        syncManager.saveWebPortalToken(webPortalTokenInput)
                    }
                Text("用于访问 /api 管理页面，可与同步 Token 分开配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("在浏览器中打开") {
                        if let url = webPortalURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .disabled(webPortalURL == nil)

                    Spacer()
                }
            }

            Section("同步设置") {
                Picker("自动同步间隔", selection: $syncManager.config.intervalMinutes) {
                    Text("10 分钟").tag(10)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                    Text("2 小时").tag(120)
                    Text("仅手动").tag(0)
                }
                .onChange(of: syncManager.config.intervalMinutes) { _, _ in
                    syncManager.startPeriodicSync(store: store)
                }

                HStack {
                    Button(syncing ? "同步中…" : "立即同步") {
                        manualSync()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(syncing)

                    Spacer()

                    if let lastSync = syncManager.config.lastSyncDate {
                        Text("上次同步：\(formatDate(lastSync))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                syncStatusView
            }

            Section("同步范围") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("核心数据：项目、支持记录、日报、问题追踪、团队成员")
                    Text("配置数据：Jira 入口、飞书 Bot、AI、RSS 订阅")
                    Text("任务数据：Todo 任务")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: isActive) { _, active in
            if active { loadSyncSecretsIfNeeded() }
        }
        .task {
            if isActive { loadSyncSecretsIfNeeded() }
        }
    }

    private func loadSyncSecretsIfNeeded() {
        guard !didLoadSyncSecrets else { return }
        didLoadSyncSecrets = true
        credentialInput = syncManager.loadCredential()
        webPortalTokenInput = syncManager.loadWebPortalToken()
    }

    @ViewBuilder
    private var syncStatusView: some View {
        switch syncManager.status {
        case .idle:
            EmptyView()
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在同步…").font(.caption).foregroundStyle(.secondary)
            }
        case .success(let date):
            Text("同步成功 \(formatDate(date))")
                .font(.caption)
                .foregroundStyle(.green)
        case .error(let msg):
            Text("同步失败：\(msg)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func saveCredential() {
        syncManager.saveCredential(credentialInput)
    }

    private func testConnection() {
        if !credentialInput.isEmpty { saveCredential() }
        testing = true
        testResult = nil
        Task {
            let result = await syncManager.testConnection()
            switch result {
            case .success:
                testResult = "连接成功"
                testSuccess = true
            case .failure(let error):
                testResult = error.localizedDescription
                testSuccess = false
            }
            testing = false
        }
    }

    private func manualSync() {
        if !credentialInput.isEmpty { saveCredential() }
        syncing = true
        Task {
            await syncManager.sync(store: store)
            syncing = false
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}
