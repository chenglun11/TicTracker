import SwiftUI

struct AITab: View {
    @Bindable var store: DataStore
    let isActive: Bool
    @State private var apiKeyInput = ""
    @State private var baseURLInput = ""
    @State private var modelInput = ""
    @State private var apiKeySaved = false
    @State private var showClearAlert = false
    @FocusState private var isAPIKeyFocused: Bool
    @FocusState private var isBaseURLFocused: Bool
    @FocusState private var isModelFocused: Bool
    @State private var saveState = AutoSaveState()
    @State private var didLoadAIConfig = false

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
        .onChange(of: isActive) { _, active in
            if active { loadAIConfigIfNeeded() }
        }
        .task {
            if isActive { loadAIConfigIfNeeded() }
        }
        .alert("确认清空所有 AI 配置？", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearAll() }
        } message: {
            Text("将清除 API Key、Base URL、模型和自定义 Prompt")
        }
    }

    private func loadAIConfigIfNeeded() {
        guard !didLoadAIConfig else { return }
        didLoadAIConfig = true
        let stored = AIService.shared.loadAll()
        apiKeyInput = stored.apiKey
        baseURLInput = stored.baseURL.isEmpty ? store.aiConfig.baseURL : stored.baseURL
        modelInput = stored.model.isEmpty ? store.aiConfig.model : stored.model
        customPromptDraft = store.aiConfig.customPrompt
        chatSystemPromptDraft = store.aiConfig.chatSystemPrompt
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

