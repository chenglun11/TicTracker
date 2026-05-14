import SwiftUI

struct FeishuBotTab: View {
    @Bindable var store: DataStore
    let isActive: Bool
    @State private var saveState = AutoSaveState()
    @State private var newWebhookURL = ""
    @State private var secretInputs: [UUID: String] = [:]
    @State private var sending = false
    @State private var sendResult: String?
    @State private var sendSuccess = false
    @State private var didLoadSecrets = false
    @State private var appSecretInput = ""

    private let templateVariables: [(String, String)] = [
        ("{{日期}}", "当天日期，如 2026-04-07"),
        ("{{今日总数}}", "项目支持总次数"),
        ("{{项目统计}}", "各项目支持次数"),
        ("{{新建数量}}", "今日新建问题数"),
        ("{{解决数量}}", "今日解决问题数"),
        ("{{待处理数量}}", "当前待处理问题数"),
        ("{{观测中数量}}", "当前观测中问题数"),
        ("{{已排期数量}}", "当前已排期问题数"),
        ("{{测试中数量}}", "当前测试中问题数"),
        ("{{待处理列表}}", "待处理问题列表"),
        ("{{已解决列表}}", "今日已解决问题列表"),
        ("{{观测中列表}}", "观测中问题列表"),
        ("{{已排期列表}}", "已排期问题列表"),
        ("{{测试中列表}}", "测试中问题列表"),
        ("{{日报内容}}", "日报文字内容"),
        ("{{当前时间}}", "发送时的时间戳"),
    ]

    var body: some View {
        NavigationStack {
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

                if store.feishuBotConfig.messageFormat != .customTemplate {
                    TextField("卡片标题", text: Bindable(store).feishuBotConfig.cardTitle,
                              prompt: Text("每日工单报告"))
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: store.feishuBotConfig.cardTitle) { _, _ in saveState.debouncedSave() }
                }

                ForEach(Array(store.feishuBotConfig.webhooks.enumerated()), id: \.element.id) { index, webhook in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(webhook.url)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                FeishuBotService.deleteSecret(for: webhook.id)
                                store.feishuBotConfig.webhooks.remove(at: index)
                                saveState.triggerSave()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack(spacing: 12) {
                            Toggle("发送", isOn: Binding(
                                get: { store.feishuBotConfig.webhooks[index].enabled },
                                set: { store.feishuBotConfig.webhooks[index].enabled = $0; saveState.triggerSave() }
                            ))
                            .controlSize(.small)

                            Toggle("签名校验", isOn: Binding(
                                get: { store.feishuBotConfig.webhooks[index].signEnabled },
                                set: { store.feishuBotConfig.webhooks[index].signEnabled = $0; saveState.triggerSave() }
                            ))
                            .controlSize(.small)
                        }
                        if webhook.signEnabled {
                            HStack(spacing: 6) {
                                SecureField("Secret", text: Binding(
                                    get: { secretInputs[webhook.id] ?? "" },
                                    set: { secretInputs[webhook.id] = $0 }
                                ))
                                .textFieldStyle(UnderlineTextFieldStyle())
                                .onSubmit { saveWebhookSecret(webhook.id) }
                                Button("保存") { saveWebhookSecret(webhook.id) }
                                    .controlSize(.small)
                                    .disabled((secretInputs[webhook.id] ?? "").isEmpty)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack(spacing: 8) {
                    TextField("Webhook URL", text: $newWebhookURL,
                              prompt: Text("https://open.feishu.cn/open-apis/bot/v2/hook/..."))
                        .textFieldStyle(UnderlineTextFieldStyle())
                    Button("添加") {
                        let url = newWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !url.isEmpty, !store.feishuBotConfig.webhooks.contains(where: { $0.url == url }) else { return }
                        store.feishuBotConfig.webhooks.append(FeishuWebhook(url: url))
                        newWebhookURL = ""
                        saveState.triggerSave()
                    }
                    .controlSize(.small)
                    .disabled(newWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack {
                    Button(sending ? "发送中…" : "测试发送") {
                        testSend()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(sending || !store.feishuBotConfig.webhooks.contains { webhook in
                        webhook.enabled && !webhook.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })

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
                    VStack(alignment: .leading, spacing: 6) {
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
                        HStack(spacing: 4) {
                            let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]
                            ForEach(1...7, id: \.self) { wd in
                                let isSelected = store.feishuBotConfig.sendTimes[i].weekdays.contains(wd)
                                Button {
                                    if isSelected {
                                        // 至少保留一天
                                        guard store.feishuBotConfig.sendTimes[i].weekdays.count > 1 else { return }
                                        store.feishuBotConfig.sendTimes[i].weekdays.remove(wd)
                                    } else {
                                        store.feishuBotConfig.sendTimes[i].weekdays.insert(wd)
                                    }
                                    FeishuBotService.shared.restartScheduler()
                                    saveState.triggerSave()
                                } label: {
                                    Text(weekdayLabels[wd - 1])
                                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                        .frame(width: 22, height: 18)
                                        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                                        .cornerRadius(4)
                                        .foregroundStyle(isSelected ? .primary : .secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            Spacer()
                            Text(weekdaySummary(store.feishuBotConfig.sendTimes[i].weekdays))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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

            if store.feishuBotConfig.messageFormat == .customTemplate {
                Section("自定义模板") {
                    TextField("卡片标题", text: Bindable(store).feishuBotConfig.customTemplateTitle,
                              prompt: Text("每日工单报告"))
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: store.feishuBotConfig.customTemplateTitle) { _, _ in saveState.debouncedSave() }

                    DisclosureGroup("可用变量") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(templateVariables, id: \.0) { variable, description in
                                HStack(spacing: 8) {
                                    Text(variable)
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(.fill.tertiary)
                                        .cornerRadius(4)
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Text("支持 **加粗**、[链接](url) 等 Markdown 语法，用 --- 分段")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: Bindable(store).feishuBotConfig.customTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200, maxHeight: 400)
                        .onChange(of: store.feishuBotConfig.customTemplate) { _, _ in
                            saveState.debouncedSave()
                        }

                    HStack {
                        Button("恢复默认模板") {
                            store.feishuBotConfig.customTemplate = FeishuBotConfig.defaultTemplate
                            saveState.triggerSave()
                        }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                        Spacer()
                        Text("\(store.feishuBotConfig.customTemplate.count) 字符")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if store.feishuBotConfig.messageFormat != .customTemplate {
                Section("卡片模块") {
                Toggle("项目支持统计", isOn: Bindable(store).feishuBotConfig.showSupportStats)
                    .onChange(of: store.feishuBotConfig.showSupportStats) { _, _ in saveState.triggerSave() }
                Toggle("统计概览（新建/解决/待处理）", isOn: Bindable(store).feishuBotConfig.showOverview)
                    .onChange(of: store.feishuBotConfig.showOverview) { _, _ in saveState.triggerSave() }
                Toggle("待处理问题列表", isOn: Bindable(store).feishuBotConfig.showPending)
                    .onChange(of: store.feishuBotConfig.showPending) { _, _ in saveState.triggerSave() }
                Toggle("观测中问题列表", isOn: Bindable(store).feishuBotConfig.showObserving)
                    .onChange(of: store.feishuBotConfig.showObserving) { _, _ in saveState.triggerSave() }
                Toggle("已排期问题列表", isOn: Bindable(store).feishuBotConfig.showScheduled)
                    .onChange(of: store.feishuBotConfig.showScheduled) { _, _ in saveState.triggerSave() }
                Toggle("测试中问题列表", isOn: Bindable(store).feishuBotConfig.showTesting)
                    .onChange(of: store.feishuBotConfig.showTesting) { _, _ in saveState.triggerSave() }
                Toggle("今日已解决列表", isOn: Bindable(store).feishuBotConfig.showResolved)
                    .onChange(of: store.feishuBotConfig.showResolved) { _, _ in saveState.triggerSave() }
                Toggle("日报文字", isOn: Bindable(store).feishuBotConfig.showDailyNote)
                    .onChange(of: store.feishuBotConfig.showDailyNote) { _, _ in saveState.triggerSave() }
                Toggle("问题评论（最近2条）", isOn: Bindable(store).feishuBotConfig.showComments)
                    .onChange(of: store.feishuBotConfig.showComments) { _, _ in saveState.triggerSave() }
            }
            }

            Section("问题显示字段") {
                Toggle("类型", isOn: Bindable(store).feishuBotConfig.fieldType)
                    .onChange(of: store.feishuBotConfig.fieldType) { _, _ in saveState.triggerSave() }
                Toggle("部门", isOn: Bindable(store).feishuBotConfig.fieldDepartment)
                    .onChange(of: store.feishuBotConfig.fieldDepartment) { _, _ in saveState.triggerSave() }
                Toggle("工单链接", isOn: Bindable(store).feishuBotConfig.fieldJiraKey)
                    .onChange(of: store.feishuBotConfig.fieldJiraKey) { _, _ in saveState.triggerSave() }
                Toggle("状态", isOn: Bindable(store).feishuBotConfig.fieldStatus)
                    .onChange(of: store.feishuBotConfig.fieldStatus) { _, _ in saveState.triggerSave() }
                Toggle("负责人", isOn: Bindable(store).feishuBotConfig.fieldAssignee)
                    .onChange(of: store.feishuBotConfig.fieldAssignee) { _, _ in saveState.triggerSave() }
            }

            Section("飞书应用（双向交互）") {
                TextField("App ID", text: Bindable(store).feishuBotConfig.appID,
                          prompt: Text("cli_xxxx"))
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onChange(of: store.feishuBotConfig.appID) { _, _ in saveState.debouncedSave() }

                HStack(spacing: 6) {
                    SecureField("App Secret", text: Binding(
                        get: { appSecretInput },
                        set: { appSecretInput = $0 }
                    ))
                    .textFieldStyle(UnderlineTextFieldStyle())
                    .onSubmit { saveAppSecret() }
                    Button("保存") { saveAppSecret() }
                        .controlSize(.small)
                        .disabled(appSecretInput.isEmpty)
                }

                Text("配置后服务端可接收飞书消息和卡片交互回调")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    FeishuTaskSyncSettingsView(store: store)
                } label: {
                    HStack {
                        Text("飞书任务同步")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .onChange(of: isActive) { _, active in
            if active { loadSecretsIfNeeded() }
        }
        .task {
            if isActive { loadSecretsIfNeeded() }
        }
        }
    }

    private func loadSecretsIfNeeded() {
        guard !didLoadSecrets else { return }
        didLoadSecrets = true
        FeishuBotService.migrateLegacySecretIfNeeded(for: store.feishuBotConfig.webhooks)
        let ids = store.feishuBotConfig.webhooks.map(\.id)
        let loaded = FeishuBotService.loadSecrets(for: ids)
        DevLog.shared.info("FeishuBot", "设置页已加载 \(loaded.count)/\(ids.count) 个 Webhook Secret")
        for (id, secret) in loaded where secretInputs[id] == nil {
            secretInputs[id] = secret
        }
        if let secret = FeishuBotService.loadAppSecret() {
            appSecretInput = secret
        }
    }

    private func saveWebhookSecret(_ id: UUID) {
        guard let secret = secretInputs[id], !secret.isEmpty else { return }
        FeishuBotService.saveSecret(for: id, secret: secret)
    }

    private func saveAppSecret() {
        guard !appSecretInput.isEmpty else { return }
        FeishuBotService.saveAppSecret(appSecretInput)
    }

    private func testSend() {
        // 保存所有有输入的 secret
        for webhook in store.feishuBotConfig.webhooks where webhook.signEnabled {
            saveWebhookSecret(webhook.id)
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

    private func weekdaySummary(_ weekdays: Set<Int>) -> String {
        if weekdays.count == 7 { return "每天" }
        if weekdays == [1, 2, 3, 4, 5] { return "工作日" }
        if weekdays == [6, 7] { return "周末" }
        let labels = ["一", "二", "三", "四", "五", "六", "日"]
        return "周" + weekdays.sorted().map { labels[$0 - 1] }.joined(separator: "、")
    }
}

// MARK: - AI Tab

