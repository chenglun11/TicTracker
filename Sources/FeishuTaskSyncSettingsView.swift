import SwiftUI

struct FeishuTaskSyncSettingsView: View {
    @Bindable var store: DataStore
    @State private var appSecretInput = ""
    @State private var oauthInProgress = false
    @State private var oauthMessage: String?
    @State private var oauthSuccess = false
    @State private var oauthAuthorizedTick = 0
    @State private var testingTasks = false
    @State private var taskTestResult: String?
    @State private var taskTestSuccess = false
    @State private var botTasklists: [FeishuVisibleTasklist] = []
    @State private var loadingBotTasklists = false
    @State private var botTasklistMessage: String?
    @State private var botTasklistSuccess = false
    @State private var deletingTasklistGUID: String?
    @State private var pendingDeleteTasklist: FeishuVisibleTasklist?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("飞书应用凭据") {
                TextField("App ID", text: Bindable(store).feishuBotConfig.appID,
                          prompt: Text("cli_xxxx"))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 6) {
                    SecureField("App Secret", text: Binding(
                        get: { appSecretInput },
                        set: { appSecretInput = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveAppSecret() }
                    Button("保存") { saveAppSecret() }
                        .controlSize(.small)
                        .disabled(appSecretInput.isEmpty)
                }
            }

            Section("OAuth 授权") {
                let _ = oauthAuthorizedTick
                let isAuthorized = FeishuOAuthService.shared.isAuthorized
                HStack(spacing: 8) {
                    Button {
                        startFeishuOAuth()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isAuthorized ? "arrow.clockwise" : "person.badge.shield.checkmark")
                            Text(oauthInProgress ? "授权中…" : (isAuthorized ? "重新授权" : "授权飞书任务"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(oauthInProgress || store.feishuBotConfig.appID.isEmpty || appSecretInput.isEmpty)

                    if isAuthorized {
                        Button("解除授权") {
                            FeishuOAuthService.shared.clear()
                            oauthMessage = "已清除授权"
                            oauthSuccess = false
                            oauthAuthorizedTick += 1
                        }
                        .controlSize(.small)
                    }

                    if let msg = oauthMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(oauthSuccess ? .green : .red)
                    } else if isAuthorized {
                        Text("已授权")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text("未授权")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("授权一次后 30 天内自动续期；需要在飞书开放平台为该应用添加重定向地址 \(FeishuOAuthService.redirectURI)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("任务清单") {
                TextField("外部任务清单 GUID", text: Bindable(store).feishuBotConfig.tasklistGUID,
                          prompt: Text("可选：用于读取已有清单"))
                    .textFieldStyle(.roundedBorder)

                TextField("Bot 清单名称", text: Bindable(store).feishuBotConfig.botTasklistName,
                          prompt: Text("TicTracker Issues"))
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Button(loadingBotTasklists ? "加载中…" : "加载 Bot 清单") {
                        loadBotTasklists()
                    }
                    .controlSize(.small)
                    .disabled(loadingBotTasklists || store.feishuBotConfig.appID.isEmpty || appSecretInput.isEmpty)

                    Button("清空 Bot 清单") {
                        store.feishuBotConfig.botTasklistGUID = ""
                        botTasklistMessage = "已清空 Bot 清单 GUID，下次创建任务会新建清单"
                        botTasklistSuccess = true
                    }
                    .controlSize(.small)
                    .disabled(store.feishuBotConfig.botTasklistGUID.isEmpty)

                    if let botTasklistMessage {
                        Text(botTasklistMessage)
                            .font(.caption)
                            .foregroundStyle(botTasklistSuccess ? .green : .red)
                    }
                }

                if !store.feishuBotConfig.botTasklistGUID.isEmpty {
                    HStack {
                        Text("当前 Bot 清单")
                        Spacer()
                        Text(store.feishuBotConfig.botTasklistGUID)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }

                if !botTasklists.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bot 可见清单")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(botTasklists, id: \.guid) { tasklist in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tasklist.name)
                                    Text(tasklist.guid)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                if store.feishuBotConfig.botTasklistGUID == tasklist.guid {
                                    Text("当前")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else {
                                    Button("设为 Bot 清单") {
                                        store.feishuBotConfig.botTasklistGUID = tasklist.guid
                                        store.feishuBotConfig.botTasklistName = tasklist.name
                                        botTasklistMessage = "已设置 Bot 清单：\(tasklist.name)"
                                        botTasklistSuccess = true
                                    }
                                    .controlSize(.small)
                                }
                                Button(deletingTasklistGUID == tasklist.guid ? "删除中…" : "删除") {
                                    pendingDeleteTasklist = tasklist
                                }
                                .controlSize(.small)
                                .foregroundStyle(.red)
                                .disabled(deletingTasklistGUID != nil)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                TextField("默认清单成员 / 执行者 Open ID", text: Bindable(store).feishuBotConfig.taskDefaultCollaboratorOpenID,
                          prompt: Text("ou_xxxx，用于让你看到 Bot 创建的清单和任务"))
                    .textFieldStyle(.roundedBorder)

                Picker("同步身份", selection: Bindable(store).feishuBotConfig.taskAuthMode) {
                    ForEach(FeishuTaskAuthMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(store.feishuBotConfig.taskAuthMode == .botTenant
                     ? "Bot 模式使用 tenant_access_token。由 Bot 创建的任务会天然可读；读取外部清单仍需要 Bot 拥有清单/任务权限。"
                     : "用户 OAuth 模式读取当前授权用户可见的任务，但会受 refresh_token 有效期影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: Bindable(store).feishuBotConfig.taskPollingInterval, in: 1...120, step: 1) {
                    HStack {
                        Text("同步间隔")
                        Spacer()
                        Text("每 \(store.feishuBotConfig.taskPollingInterval) 分钟")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("问题详情里的「创建飞书任务」会优先创建/复用 Bot 专用清单，并绑定返回的任务 GUID；轮询同步按上方身份读取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("仅在 TicTracker 窗口可见时轮询已绑定任务状态；设置为较短间隔会更频繁调用飞书 API。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(testingTasks ? "测试中…" : "拉取任务测试") {
                        testFetchTasks()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(testingTasks)

                    if let result = taskTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(taskTestSuccess ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("飞书任务同步")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }
            }
        }
        .confirmationDialog(
            "确认删除这个清单？",
            isPresented: Binding(
                get: { pendingDeleteTasklist != nil },
                set: { if !$0 { pendingDeleteTasklist = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeleteTasklist {
                Button("删除 \(pendingDeleteTasklist.name)", role: .destructive) {
                    deleteTasklist(pendingDeleteTasklist)
                }
            }
            Button("取消", role: .cancel) { pendingDeleteTasklist = nil }
        } message: {
            if let pendingDeleteTasklist {
                Text("只会删除这个飞书清单：\(pendingDeleteTasklist.guid)。此操作不可撤销。")
            }
        }
        .onAppear {
            if let secret = FeishuBotService.loadAppSecret() {
                appSecretInput = secret
            }
        }
    }

    private func deleteTasklist(_ tasklist: FeishuVisibleTasklist) {
        deletingTasklistGUID = tasklist.guid
        pendingDeleteTasklist = nil
        botTasklistMessage = nil
        saveAppSecret()
        Task {
            do {
                try await FeishuTaskService.shared.deleteVisibleTasklist(store: store, guid: tasklist.guid)
                botTasklists.removeAll { $0.guid == tasklist.guid }
                botTasklistMessage = "已删除清单：\(tasklist.name)"
                botTasklistSuccess = true
            } catch {
                botTasklistMessage = error.localizedDescription
                botTasklistSuccess = false
            }
            deletingTasklistGUID = nil
        }
    }

    private func loadBotTasklists() {
        loadingBotTasklists = true
        botTasklistMessage = nil
        saveAppSecret()
        Task {
            do {
                let lists = try await FeishuTaskService.shared.listBotVisibleTasklists(store: store)
                botTasklists = lists
                botTasklistMessage = lists.isEmpty ? "Bot 暂无可见清单" : "已加载 \(lists.count) 个清单"
                botTasklistSuccess = true
            } catch {
                botTasklists = []
                botTasklistMessage = error.localizedDescription
                botTasklistSuccess = false
            }
            loadingBotTasklists = false
        }
    }

    private func saveAppSecret() {
        guard !appSecretInput.isEmpty else { return }
        FeishuBotService.saveAppSecret(appSecretInput)
    }

    private func startFeishuOAuth() {
        let appID = store.feishuBotConfig.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = appSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, !appSecret.isEmpty else {
            oauthMessage = "请先填写 App ID 和 App Secret 并保存"
            oauthSuccess = false
            return
        }
        if !appSecret.isEmpty {
            FeishuBotService.saveAppSecret(appSecret)
        }
        oauthInProgress = true
        oauthMessage = nil
        Task {
            do {
                try await FeishuOAuthService.shared.authorize(appID: appID, appSecret: appSecret)
                oauthMessage = "授权成功"
                oauthSuccess = true
            } catch {
                oauthMessage = error.localizedDescription
                oauthSuccess = false
            }
            oauthInProgress = false
            oauthAuthorizedTick += 1
        }
    }

    private func testFetchTasks() {
        testingTasks = true
        taskTestResult = nil
        Task {
            do {
                let result = try await FeishuTaskService.shared.testTasks(store: store)
                taskTestResult = "成功拉取 \(result.count) 条任务"
                taskTestSuccess = true
            } catch {
                taskTestResult = error.localizedDescription
                taskTestSuccess = false
            }
            testingTasks = false
        }
    }
}
