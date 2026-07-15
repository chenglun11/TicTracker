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
    @State private var sendingIssueMonthlyReport = false
    @State private var issueMonthlyReportResult: String?
    @State private var issueMonthlyReportSuccess = true
    @State private var didLoadSecrets = false
    @State private var appSecretInput = ""
    @State private var keychainMessage: String?
    @State private var keychainSuccess = true

    private let templateVariables: [(String, String)] = [
        ("{{日期}}", "当天日期，如 2026-04-07"),
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

            Section("日报出口") {
                SettingsStatusRow(
                    title: "主流程",
                    value: store.feishuBotConfig.enabled ? "定时日报" : "未启用",
                    systemImage: "clock.badge.checkmark",
                    tint: store.feishuBotConfig.enabled ? .green : .secondary
                )
                SettingsStatusRow(
                    title: "发送通道",
                    value: activeWebhookSummary,
                    systemImage: "paperplane.fill",
                    tint: activeWebhookCount > 0 ? .green : .orange
                )
                SettingsStatusRow(
                    title: "发送时间",
                    value: scheduleSummary,
                    systemImage: "calendar",
                    tint: store.feishuBotConfig.sendTimes.isEmpty ? .orange : .green
                )
                SettingsStatusRow(
                    title: "我的提交",
                    value: store.feishuBotConfig.showMyReported ? "进入日报" : "未展示",
                    systemImage: "person.crop.circle.badge.checkmark",
                    tint: store.feishuBotConfig.showMyReported ? .green : .secondary
                )
                SettingsStatusRow(
                    title: "重点分组",
                    value: store.feishuBotConfig.showFocusTag ? focusTagDisplay : "未展示",
                    systemImage: "tag.fill",
                    tint: store.feishuBotConfig.showFocusTag ? .green : .secondary
                )
                SettingsStatusRow(
                    title: "问题月报",
                    value: store.feishuBotConfig.issueMonthlyReportEnabled ? issueMonthlyScheduleSummary : "未启用",
                    systemImage: "calendar.badge.clock",
                    tint: store.feishuBotConfig.issueMonthlyReportEnabled ? .purple : .secondary
                )
                SettingsHint(text: "日报始终统计当天完整数据；重点 Tag 只额外生成一组，推送成功后不会自动移除标签。")
            }

            Section("Webhook") {
                Picker("消息格式", selection: Bindable(store).feishuBotConfig.messageFormat) {
                    ForEach(FeishuMessageFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: store.feishuBotConfig.messageFormat) { _, _ in saveState.triggerSave() }

                Toggle("附带可视化报表图", isOn: Bindable(store).feishuBotConfig.includeVisualReportImage)
                    .disabled(store.feishuBotConfig.messageFormat == .richText)
                    .onChange(of: store.feishuBotConfig.includeVisualReportImage) { _, _ in saveState.triggerSave() }

                if store.feishuBotConfig.messageFormat != .customTemplate {
                    TextField("卡片标题", text: Bindable(store).feishuBotConfig.cardTitle,
                              prompt: Text("每日工单报告"))
                        .textFieldStyle(UnderlineTextFieldStyle())
                        .onChange(of: store.feishuBotConfig.cardTitle) { _, _ in saveState.debouncedSave() }
                }

                ForEach(store.feishuBotConfig.webhooks) { webhook in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(webhook.url)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                FeishuBotService.deleteSecret(for: webhook.id)
                                secretInputs.removeValue(forKey: webhook.id)
                                store.feishuBotConfig.webhooks.removeAll { $0.id == webhook.id }
                                saveState.triggerSave()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack(spacing: 12) {
                            Toggle("发送", isOn: webhookBinding(id: webhook.id, keyPath: \.enabled))
                            .controlSize(.small)

                            Toggle("签名校验", isOn: webhookBinding(id: webhook.id, keyPath: \.signEnabled))
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
                                Button((secretInputs[webhook.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "清除" : "保存") {
                                    saveWebhookSecret(webhook.id)
                                }
                                    .controlSize(.small)
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
                ForEach(store.feishuBotConfig.sendTimes) { scheduleTime in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Picker("", selection: scheduleTimeBinding(id: scheduleTime.id, keyPath: \.hour)) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 60)
                            Text(":")
                                .foregroundStyle(.tertiary)
                            Picker("", selection: scheduleTimeBinding(id: scheduleTime.id, keyPath: \.minute)) {
                                ForEach(0..<60, id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 60)
                            Spacer()
                            Button {
                                store.feishuBotConfig.sendTimes.removeAll { $0.id == scheduleTime.id }
                                store.feishuBotConfig.lastSentTimes.removeValue(forKey: scheduleTime.key)
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
                                let isSelected = scheduleTime.weekdays.contains(wd)
                                Button {
                                    toggleScheduleWeekday(id: scheduleTime.id, weekday: wd)
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
                            Text(weekdaySummary(scheduleTime.weekdays))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("添加时间") {
                    store.feishuBotConfig.sendTimes.append(ScheduleTime(hour: 18, minute: 0))
                    FeishuBotService.shared.restartScheduler()
                    saveState.triggerSave()
                }
                .controlSize(.small)
            }

            Section {
                Toggle("启用问题追踪月报", isOn: Bindable(store).feishuBotConfig.issueMonthlyReportEnabled)
                    .onChange(of: store.feishuBotConfig.issueMonthlyReportEnabled) { _, _ in
                        FeishuBotService.shared.restartScheduler()
                        saveState.triggerSave()
                    }

                HStack(spacing: 8) {
                    Text("每月")
                    Picker("", selection: Bindable(store).feishuBotConfig.issueMonthlyReportDay) {
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day) 号").tag(day)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 82)
                    Text("日")
                        .foregroundStyle(.secondary)
                    Picker("", selection: Bindable(store).feishuBotConfig.issueMonthlyReportHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d", hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                    Text(":")
                        .foregroundStyle(.tertiary)
                    Picker("", selection: Bindable(store).feishuBotConfig.issueMonthlyReportMinute) {
                        ForEach(0..<60, id: \.self) { minute in
                            Text(String(format: "%02d", minute)).tag(minute)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                    Spacer()
                }
                .disabled(!store.feishuBotConfig.issueMonthlyReportEnabled)
                .onChange(of: store.feishuBotConfig.issueMonthlyReportDay) { _, _ in saveIssueMonthlyScheduleChange() }
                .onChange(of: store.feishuBotConfig.issueMonthlyReportHour) { _, _ in saveIssueMonthlyScheduleChange() }
                .onChange(of: store.feishuBotConfig.issueMonthlyReportMinute) { _, _ in saveIssueMonthlyScheduleChange() }

                Toggle("附带问题月报图", isOn: Bindable(store).feishuBotConfig.issueMonthlyReportIncludeImage)
                    .onChange(of: store.feishuBotConfig.issueMonthlyReportIncludeImage) { _, _ in saveState.triggerSave() }

                HStack {
                    Menu {
                        Button("推送本月问题月报") {
                            sendIssueMonthlyReport(.currentMonth)
                        }
                        Button("推送上月问题月报") {
                            sendIssueMonthlyReport(.previousMonth)
                        }
                    } label: {
                        Label(sendingIssueMonthlyReport ? "推送中…" : "立即推送", systemImage: sendingIssueMonthlyReport ? "hourglass" : "paperplane.fill")
                    }
                    .disabled(sendingIssueMonthlyReport || activeWebhookCount == 0)

                    if let issueMonthlyReportResult {
                        Text(issueMonthlyReportResult)
                            .font(.caption)
                            .foregroundStyle(issueMonthlyReportSuccess ? .green : .red)
                    }

                    Spacer()

                    if !store.feishuBotConfig.issueMonthlyReportLastSentMonth.isEmpty {
                        Text("上次月报：\(store.feishuBotConfig.issueMonthlyReportLastSentMonth)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("问题月报推送")
            } footer: {
                Text("定时任务会推送上月问题追踪月报；如果选择 29-31 号，小月会在当月最后一天触发。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                reportModuleSections
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
                    Button(appSecretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "清除" : "保存") {
                        saveAppSecret()
                    }
                        .controlSize(.small)
                }

                Text("配置后服务端可接收飞书消息和卡片交互回调")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let keychainMessage {
                    Text(keychainMessage)
                        .font(.caption)
                        .foregroundStyle(keychainSuccess ? .green : .red)
                }

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
        .tunedForResponsiveScroll()
        .autoSaveIndicator(saveState)
        .onChange(of: isActive) { _, active in
            if active { loadSecretsIfNeeded() }
        }
        .task {
            if isActive { loadSecretsIfNeeded() }
        }
        }
    }

    @ViewBuilder
    private var reportModuleSections: some View {
        Section("卡片模块") {
            Toggle("统计概览（新建/解决/待处理）", isOn: Bindable(store).feishuBotConfig.showOverview)
                .onChange(of: store.feishuBotConfig.showOverview) { _, _ in saveState.triggerSave() }
            Toggle("待处理问题列表", isOn: Bindable(store).feishuBotConfig.showPending)
                .onChange(of: store.feishuBotConfig.showPending) { _, _ in saveState.triggerSave() }
            Toggle("处理中问题列表", isOn: Bindable(store).feishuBotConfig.showInProgress)
                .onChange(of: store.feishuBotConfig.showInProgress) { _, _ in saveState.triggerSave() }
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
        }

        Section {
            Toggle("我今日提交", isOn: Bindable(store).feishuBotConfig.showMyReported)
                .onChange(of: store.feishuBotConfig.showMyReported) { _, _ in saveState.triggerSave() }
            Toggle("重点 Tag 分组", isOn: Bindable(store).feishuBotConfig.showFocusTag)
                .onChange(of: store.feishuBotConfig.showFocusTag) { _, _ in saveState.triggerSave() }
            TextField("重点 Tag", text: Bindable(store).feishuBotConfig.focusIssueTag,
                      prompt: Text("今日Bug"))
                .textFieldStyle(UnderlineTextFieldStyle())
                .disabled(!store.feishuBotConfig.showFocusTag)
                .onChange(of: store.feishuBotConfig.focusIssueTag) { _, _ in saveState.debouncedSave() }
        } header: {
            Text("日报分组")
        } footer: {
            Text("定时日报始终发送当天完整数据；重点 Tag 只额外高亮一组问题。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func webhookBinding(id: UUID, keyPath: WritableKeyPath<FeishuWebhook, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                store.feishuBotConfig.webhooks.first(where: { $0.id == id })?[keyPath: keyPath] ?? false
            },
            set: { value in
                guard let index = store.feishuBotConfig.webhooks.firstIndex(where: { $0.id == id }) else { return }
                store.feishuBotConfig.webhooks[index][keyPath: keyPath] = value
                saveState.triggerSave()
            }
        )
    }

    private func scheduleTimeBinding(id: UUID, keyPath: WritableKeyPath<ScheduleTime, Int>) -> Binding<Int> {
        Binding(
            get: {
                store.feishuBotConfig.sendTimes.first(where: { $0.id == id })?[keyPath: keyPath] ?? 0
            },
            set: { value in
                guard let index = store.feishuBotConfig.sendTimes.firstIndex(where: { $0.id == id }) else { return }
                let oldKey = store.feishuBotConfig.sendTimes[index].key
                store.feishuBotConfig.sendTimes[index][keyPath: keyPath] = value
                store.feishuBotConfig.lastSentTimes.removeValue(forKey: oldKey)
                FeishuBotService.shared.restartScheduler()
                saveState.triggerSave()
            }
        )
    }

    private func toggleScheduleWeekday(id: UUID, weekday: Int) {
        guard let index = store.feishuBotConfig.sendTimes.firstIndex(where: { $0.id == id }) else { return }
        if store.feishuBotConfig.sendTimes[index].weekdays.contains(weekday) {
            guard store.feishuBotConfig.sendTimes[index].weekdays.count > 1 else { return }
            store.feishuBotConfig.sendTimes[index].weekdays.remove(weekday)
        } else {
            store.feishuBotConfig.sendTimes[index].weekdays.insert(weekday)
        }
        FeishuBotService.shared.restartScheduler()
        saveState.triggerSave()
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

    private var activeWebhookCount: Int {
        store.feishuBotConfig.webhooks.filter {
            $0.enabled && !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private var activeWebhookSummary: String {
        if activeWebhookCount == 0 {
            return "缺 Webhook"
        }
        return "\(activeWebhookCount) 个可发送"
    }

    private var scheduleSummary: String {
        let times = store.feishuBotConfig.sendTimes
        guard !times.isEmpty else { return "未设置" }
        let sorted = times.sorted {
            if $0.hour == $1.hour { return $0.minute < $1.minute }
            return $0.hour < $1.hour
        }
        return sorted.prefix(3).map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: "、") +
            (sorted.count > 3 ? " 等 \(sorted.count) 个" : "")
    }

    private var issueMonthlyScheduleSummary: String {
        "每月 \(store.feishuBotConfig.issueMonthlyReportDay) 号 " +
            String(format: "%02d:%02d", store.feishuBotConfig.issueMonthlyReportHour, store.feishuBotConfig.issueMonthlyReportMinute)
    }

    private var focusTagDisplay: String {
        let tag = store.feishuBotConfig.focusIssueTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? "今日Bug" : tag
    }

    private func saveWebhookSecret(_ id: UUID) {
        let secret = secretInputs[id] ?? ""
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = FeishuBotService.saveSecret(for: id, secret: trimmed)
        keychainSuccess = ok
        keychainMessage = ok ? (trimmed.isEmpty ? "Webhook Secret 已从 Keychain 清除" : "Webhook Secret 已保存到 Keychain") : "Webhook Secret 保存失败"
        if ok, trimmed.isEmpty {
            secretInputs[id] = ""
        }
    }

    private func saveAppSecret() {
        let trimmed = appSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = FeishuBotService.saveAppSecret(trimmed)
        keychainSuccess = ok
        keychainMessage = ok ? (trimmed.isEmpty ? "App Secret 已从 Keychain 清除" : "App Secret 已保存到 Keychain") : "App Secret 保存失败"
        if ok {
            appSecretInput = trimmed
        }
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

    private func saveIssueMonthlyScheduleChange() {
        store.feishuBotConfig.issueMonthlyReportLastSentMonth = ""
        FeishuBotService.shared.restartScheduler()
        saveState.triggerSave()
    }

    private func sendIssueMonthlyReport(_ period: WeeklyReport.Period) {
        sendingIssueMonthlyReport = true
        issueMonthlyReportResult = nil
        Task {
            let result = await FeishuBotService.shared.sendIssueTrackingReportNow(store: store, period: period)
            issueMonthlyReportResult = result.message
            issueMonthlyReportSuccess = result.success
            if result.success {
                saveState.triggerSave()
            }
            sendingIssueMonthlyReport = false
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
