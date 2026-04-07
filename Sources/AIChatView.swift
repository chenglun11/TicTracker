import SwiftUI
import UniformTypeIdentifiers

// MARK: - Constants
private enum ChatConstants {
    static let maxSessions = 20
    static let maxMessagesPerSession = 100
    static let maxAttachments = 5
    static let maxImageSize = 5_000_000
    static let maxTextFileSize = 50_000

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()
}

struct ChatSession: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "新对话", messages: [ChatMessage] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ChatAttachment: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let fileType: String
    let content: String
    let mimeType: String

    init(id: UUID = UUID(), fileName: String, fileType: String, content: String, mimeType: String) {
        self.id = id
        self.fileName = fileName
        self.fileType = fileType
        self.content = content
        self.mimeType = mimeType
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var iconName: String { isImage ? "photo" : "doc.text" }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    let attachments: [ChatAttachment]

    enum MessageRole: String, Codable {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date(), attachments: [ChatAttachment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.attachments = attachments
    }
}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var currentSessionId: UUID?
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var attachments: [ChatAttachment] = []
    @Published var scrollTrigger = UUID()
    @Published var streamingMessageId: UUID?

    private let store: DataStore
    private let aiService = AIService.shared
    private let log = DevLog.shared
    private var saveTask: Task<Void, Never>?

    var currentSession: ChatSession? {
        sessions.first { $0.id == currentSessionId }
    }

    var messages: [ChatMessage] {
        currentSession?.messages ?? []
    }

    init(store: DataStore) {
        self.store = store
        loadSessions()
        if sessions.isEmpty {
            createNewSession()
        } else {
            currentSessionId = sessions.first?.id
        }
    }

    deinit {
        saveTask?.cancel()
    }

    func createNewSession() {
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        debouncedSave()
    }

    func switchSession(_ sessionId: UUID) {
        currentSessionId = sessionId
        attachments = []
        errorMessage = nil
    }

    func deleteSession(_ session: ChatSession) {
        sessions.removeAll { $0.id == session.id }
        if currentSessionId == session.id {
            currentSessionId = sessions.first?.id
        }
        if sessions.isEmpty {
            createNewSession()
        }
        saveSessions()
    }

    func updateSessionTitle(_ session: ChatSession, title: String) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].title = title
            debouncedSave()
        }
    }

    private func debouncedSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            saveSessions()
        }
    }

    func sendMessage() {
        guard let sessionId = currentSessionId else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let userMessage = ChatMessage(role: .user, content: trimmed, attachments: attachments)
        sessions[sessionIndex].messages.append(userMessage)
        sessions[sessionIndex].updatedAt = Date()

        if sessions[sessionIndex].messages.count == 1 {
            sessions[sessionIndex].title = String(trimmed.prefix(30))
        }

        inputText = ""
        let currentAttachments = attachments
        attachments = []
        errorMessage = nil
        scrollTrigger = UUID()

        Task {
            await generateResponse(for: trimmed, attachments: currentAttachments, sessionId: sessionId)
        }
    }

    func addAttachment(from url: URL) {
        guard attachments.count < ChatConstants.maxAttachments else {
            errorMessage = "最多只能添加 \(ChatConstants.maxAttachments) 个附件"
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "无法访问文件"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let fileType = url.pathExtension.lowercased()
            let fileName = url.lastPathComponent

            let supportedImageTypes = ["png", "jpg", "jpeg", "gif", "webp"]
            let supportedTextTypes = ["txt", "md", "json", "xml", "csv", "log", "swift", "py", "js", "ts", "html", "css"]

            if supportedImageTypes.contains(fileType) {
                let data = try Data(contentsOf: url)
                guard data.count <= ChatConstants.maxImageSize else {
                    errorMessage = "图片过大（最大 \(ChatConstants.maxImageSize / 1_000_000)MB）"
                    return
                }

                let base64 = data.base64EncodedString()
                let mimeType = "image/\(fileType == "jpg" ? "jpeg" : fileType)"

                let attachment = ChatAttachment(
                    fileName: fileName,
                    fileType: fileType,
                    content: base64,
                    mimeType: mimeType
                )
                attachments.append(attachment)
                log.info("AIChat", "添加图片附件: \(fileName), 大小: \(data.count) bytes")

            } else if supportedTextTypes.contains(fileType) {
                let content = try String(contentsOf: url, encoding: .utf8)
                let byteCount = content.utf8.count
                guard byteCount <= ChatConstants.maxTextFileSize else {
                    errorMessage = "文件过大（最大 \(ChatConstants.maxTextFileSize / 1000)KB）"
                    return
                }

                let attachment = ChatAttachment(
                    fileName: fileName,
                    fileType: fileType,
                    content: content,
                    mimeType: "text/plain"
                )
                attachments.append(attachment)
                log.info("AIChat", "添加文本附件: \(fileName), 大小: \(byteCount) bytes")

            } else {
                errorMessage = "不支持的文件类型: .\(fileType)"
            }

        } catch {
            log.error("AIChat", "读取文件失败: \(error.localizedDescription)")
            errorMessage = "读取文件失败: \(error.localizedDescription)"
        }
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func copyMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    func deleteMessage(_ message: ChatMessage) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        sessions[sessionIndex].messages.removeAll { $0.id == message.id }
        saveSessions()
    }

    func regenerateResponse(for message: ChatMessage) {
        guard let sessionId = currentSessionId,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard message.role == .assistant,
              let index = sessions[sessionIndex].messages.firstIndex(where: { $0.id == message.id }),
              index > 0 else { return }

        let userMessage = sessions[sessionIndex].messages[index - 1]
        sessions[sessionIndex].messages.removeLast(sessions[sessionIndex].messages.count - index)

        Task {
            await generateResponse(for: userMessage.content, attachments: userMessage.attachments, sessionId: sessionId)
        }
    }

    var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !attachments.isEmpty
        return (hasText || hasAttachments) && !isLoading
    }

    private func generateResponse(for userInput: String, attachments: [ChatAttachment], sessionId: UUID) async {
        isLoading = true
        defer {
            isLoading = false
            streamingMessageId = nil
        }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        let maxHistory = max(1, store.aiConfig.chatMaxHistory)
        let historyMessages = sessions[sessionIndex].messages.dropLast().suffix(maxHistory).map { msg -> (String, String) in
            var content = msg.content
            if !msg.attachments.isEmpty {
                content += "\n[附件: \(msg.attachments.map { $0.fileName }.joined(separator: ", "))]"
            }
            return (msg.role.rawValue, content)
        }

        let attachmentTuples = attachments.map { (fileName: $0.fileName, content: $0.content, mimeType: $0.mimeType) }

        // 先插入空的 assistant 消息，后续流式追加
        let assistantMessage = ChatMessage(role: .assistant, content: "")
        let messageId = assistantMessage.id
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].messages.append(assistantMessage)
        sessions[idx].updatedAt = Date()
        streamingMessageId = messageId
        scrollTrigger = UUID()

        do {
            let stream = try aiService.chatStream(
                message: userInput,
                attachments: attachmentTuples,
                history: historyMessages,
                config: store.aiConfig
            )

            var buffer = ""
            var lastFlush = Date()

            for try await chunk in stream {
                buffer += chunk
                let now = Date()
                // 每 100ms 或 buffer 超过 200 字符时刷新一次
                if now.timeIntervalSince(lastFlush) >= 0.1 || buffer.count >= 200 {
                    guard let si = sessions.firstIndex(where: { $0.id == sessionId }),
                          let mi = sessions[si].messages.firstIndex(where: { $0.id == messageId }) else { break }
                    let current = sessions[si].messages[mi].content
                    sessions[si].messages[mi] = ChatMessage(
                        id: messageId,
                        role: .assistant,
                        content: current + buffer,
                        timestamp: sessions[si].messages[mi].timestamp
                    )
                    buffer = ""
                    lastFlush = now
                    scrollTrigger = UUID()
                }
            }

            // 刷新剩余 buffer
            if !buffer.isEmpty,
               let si = sessions.firstIndex(where: { $0.id == sessionId }),
               let mi = sessions[si].messages.firstIndex(where: { $0.id == messageId }) {
                let current = sessions[si].messages[mi].content
                sessions[si].messages[mi] = ChatMessage(
                    id: messageId,
                    role: .assistant,
                    content: current + buffer,
                    timestamp: sessions[si].messages[mi].timestamp
                )
            }

            scrollTrigger = UUID()

            if let si = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[si].updatedAt = Date()
            }
            saveSessions()

        } catch {
            log.error("AIChat", "对话失败: \(error.localizedDescription)")
            if let si = sessions.firstIndex(where: { $0.id == sessionId }),
               let mi = sessions[si].messages.firstIndex(where: { $0.id == messageId }),
               sessions[si].messages[mi].content.isEmpty {
                sessions[si].messages.remove(at: mi)
            }
            errorMessage = error.localizedDescription
        }
    }

    func clearHistory() {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        sessions[sessionIndex].messages.removeAll()
        saveSessions()
        errorMessage = nil
    }

    func generateWeeklyReport() {
        guard let sessionId = currentSessionId,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard !isLoading else { return }

        let rawReport = WeeklyReport.generate(from: store)
        let userMessage = ChatMessage(role: .user, content: "请根据以下数据生成周报：\n\n\(rawReport)", attachments: [])
        sessions[sessionIndex].messages.append(userMessage)
        sessions[sessionIndex].updatedAt = Date()
        errorMessage = nil
        scrollTrigger = UUID()

        isLoading = true
        Task {
            defer { isLoading = false }

            do {
                let response = try await aiService.generateWeeklyReport(rawReport: rawReport, config: store.aiConfig)
                guard let finalIndex = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
                let assistantMessage = ChatMessage(role: .assistant, content: response)
                sessions[finalIndex].messages.append(assistantMessage)
                sessions[finalIndex].updatedAt = Date()
                scrollTrigger = UUID()
                saveSessions()
            } catch {
                log.error("AIChat", "周报生成失败: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveSessions() {
        let sessionsToSave = sessions.prefix(ChatConstants.maxSessions).map { session -> ChatSession in
            let lightMessages = session.messages.suffix(ChatConstants.maxMessagesPerSession).map { msg -> ChatMessage in
                let lightAttachments = msg.attachments.map {
                    ChatAttachment(id: $0.id, fileName: $0.fileName, fileType: $0.fileType, content: "", mimeType: $0.mimeType)
                }
                return ChatMessage(id: msg.id, role: msg.role, content: msg.content, timestamp: msg.timestamp, attachments: lightAttachments)
            }
            return ChatSession(id: session.id, title: session.title, messages: lightMessages, createdAt: session.createdAt, updatedAt: session.updatedAt)
        }
        if let data = try? JSONEncoder().encode(sessionsToSave) {
            UserDefaults.standard.set(data, forKey: "ai_chat_sessions")
        }
    }

    private func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: "ai_chat_sessions"),
              let loaded = try? JSONDecoder().decode([ChatSession].self, from: data) else {
            return
        }
        sessions = loaded
    }
}

struct AIChatView: View {
    @StateObject private var viewModel: AIChatViewModel
    @FocusState private var isInputFocused: Bool
    @FocusState private var isTitleEditFocused: Bool
    @State private var showClearConfirmation = false
    @State private var showFilePicker = false
    @State private var editingSessionId: UUID?
    @State private var editingTitle: String = ""

    init(store: DataStore) {
        _viewModel = StateObject(wrappedValue: AIChatViewModel(store: store))
    }

    var body: some View {
        NavigationSplitView {
            sessionSidebar
        } detail: {
            chatDetailView
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { isInputFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .generateWeeklyReport)) { _ in
            if !viewModel.isLoading { viewModel.generateWeeklyReport() }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [
                .image, .text, .plainText, .json, .xml,
            ] + [
                UTType(filenameExtension: "md"),
                UTType(filenameExtension: "swift"),
                UTType(filenameExtension: "py"),
                UTType(filenameExtension: "js"),
                UTType(filenameExtension: "ts"),
            ].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { viewModel.addAttachment(from: url) }
            case .failure(let error):
                viewModel.errorMessage = "选择文件失败: \(error.localizedDescription)"
            }
        }
    }

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("对话列表")
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.createNewSession() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建对话")
            }
            .padding()

            Divider()

            List(viewModel.sessions, selection: $viewModel.currentSessionId) { session in
                HStack {
                    if editingSessionId == session.id {
                        TextField("", text: $editingTitle)
                            .textFieldStyle(.plain)
                            .focused($isTitleEditFocused)
                            .onSubmit {
                                viewModel.updateSessionTitle(session, title: editingTitle)
                                editingSessionId = nil
                            }
                            .onAppear {
                                isTitleEditFocused = true
                            }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .lineLimit(1)
                            Text(formatDate(session.updatedAt))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .onTapGesture(count: 2) {
                            editingSessionId = session.id
                            editingTitle = session.title
                        }
                        .onTapGesture {
                            viewModel.switchSession(session.id)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("重命名") {
                        editingSessionId = session.id
                        editingTitle = session.title
                    }
                    Button("删除", role: .destructive) {
                        viewModel.deleteSession(session)
                    }
                }
            }
        }
        .frame(minWidth: 200)
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return ChatConstants.timeFormatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) {
            return ChatConstants.weekdayFormatter.string(from: date)
        } else {
            return ChatConstants.dateFormatter.string(from: date)
        }
    }

    private var chatDetailView: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            messagesView
            if viewModel.errorMessage != nil { errorBanner }
            Divider()
            if !viewModel.attachments.isEmpty { attachmentsPreview }
            inputArea
        }
    }

    private var headerView: some View {
        HStack {
            if let session = viewModel.currentSession {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("AI 对话")
                    .font(.headline)
            }
            Spacer()
            Button(action: { viewModel.generateWeeklyReport() }) {
                Label("生成周报", systemImage: "doc.text")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
            .help("生成本周技术支持周报并由 AI 优化")

            Button(action: { showClearConfirmation = true }) {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.messages.isEmpty)
            .confirmationDialog("确定要清空当前对话的所有消息吗？", isPresented: $showClearConfirmation) {
                Button("清空消息", role: .destructive) { viewModel.clearHistory() }
                if viewModel.sessions.count > 1, let session = viewModel.currentSession {
                    Button("删除整个对话", role: .destructive) { viewModel.deleteSession(session) }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            isStreaming: viewModel.streamingMessageId == message.id,
                            onCopy: { viewModel.copyMessage(message) },
                            onDelete: { viewModel.deleteMessage(message) },
                            onRegenerate: { viewModel.regenerateResponse(for: message) }
                        )
                        .id(message.id)
                    }

                    if viewModel.isLoading && viewModel.streamingMessageId == nil {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("思考中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 52)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .overlay {
                if viewModel.messages.isEmpty { emptyStateView }
            }
            .onChange(of: viewModel.scrollTrigger) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.currentSessionId) { _, newId in
                guard newId != nil else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var errorBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(viewModel.errorMessage ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("关闭") { viewModel.errorMessage = nil }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private var attachmentsPreview: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.attachments) { attachment in
                        AttachmentPreview(attachment: attachment) {
                            viewModel.removeAttachment(attachment)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
        }
    }

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: { showFilePicker = true }) {
                Image(systemName: "paperclip")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
            .help("添加文件")

            TextField("输入消息...", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .disabled(viewModel.isLoading)
                .onSubmit {
                    if viewModel.canSend { viewModel.sendMessage() }
                }

            Button(action: { viewModel.sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(viewModel.canSend ? .accentColor : .gray)
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canSend)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("开始对话")
                .font(.title2)
                .fontWeight(.medium)
            Text("输入消息与 AI 助手交流")
                .font(.caption)
                .foregroundColor(.secondary)
            Button(action: { viewModel.generateWeeklyReport() }) {
                Label("生成周报", systemImage: "doc.text.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRegenerate: () -> Void

    @State private var isHovered = false
    @State private var showRegenerateConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatarView
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(message.role == .user ? "你" : "AI 助手")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(message.timestamp, style: .time)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if isHovered { actionButtons }
                }

                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { attachment in
                        AttachmentDisplay(attachment: attachment)
                    }
                }

                if !message.content.isEmpty {
                    if isStreaming {
                        Text(message.content).font(.body).textSelection(.enabled)
                    } else {
                        MarkdownText(content: message.content)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
        .cornerRadius(8)
        .onHover { isHovered = $0 }
        .confirmationDialog("重新生成将删除此消息之后的所有对话", isPresented: $showRegenerateConfirm) {
            Button("重新生成", role: .destructive) { onRegenerate() }
            Button("取消", role: .cancel) {}
        }
    }

    private var avatarView: some View {
        Image(systemName: message.role == .user ? "person.circle.fill" : "sparkles")
            .font(.title2)
            .foregroundColor(message.role == .user ? .blue : .purple)
            .frame(width: 32, height: 32)
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("复制")

            if message.role == .assistant {
                Button(action: { showRegenerateConfirm = true }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("重新生成")
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
    }
}

struct MarkdownText: View {
    let content: String
    @State private var parsedBlocks: [ContentBlock] = []
    @State private var groupedBlocks: [GroupedBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groupedBlocks) { group in
                switch group.kind {
                case .code(let language):
                    CodeBlock(code: group.text, language: language)
                case .text:
                    Text(group.attributed).font(.body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: content) {
            parsedBlocks = parseContent()
            groupedBlocks = buildGroupedBlocks()
        }
    }

    private func buildGroupedBlocks() -> [GroupedBlock] {
        var result: [GroupedBlock] = []
        var pendingParagraphs: [ContentBlock] = []

        func flushParagraphs() {
            guard !pendingParagraphs.isEmpty else { return }
            var combined = AttributedString()
            for (i, block) in pendingParagraphs.enumerated() {
                if block.kind == .blank {
                    combined.append(AttributedString("\n"))
                } else {
                    if let attr = try? AttributedString(markdown: block.text) {
                        combined.append(attr)
                    } else {
                        combined.append(AttributedString(block.text))
                    }
                }
                if i < pendingParagraphs.count - 1 && pendingParagraphs[i].kind != .blank {
                    combined.append(AttributedString("\n"))
                }
            }
            result.append(GroupedBlock(kind: .text, text: "", attributed: combined))
            pendingParagraphs = []
        }

        for block in parsedBlocks {
            switch block.kind {
            case .code(let language):
                flushParagraphs()
                result.append(GroupedBlock(kind: .code(language: language), text: block.text, attributed: AttributedString()))
            case .paragraph, .blank:
                pendingParagraphs.append(block)
            }
        }
        flushParagraphs()
        return result
    }

    private func parseContent() -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let pattern = "```(\\w*)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return splitParagraphs(content)
        }

        let nsString = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsString.length))

        var lastIndex = 0
        for match in matches {
            if match.range.location > lastIndex {
                let textRange = NSRange(location: lastIndex, length: match.range.location - lastIndex)
                let text = nsString.substring(with: textRange)
                blocks.append(contentsOf: splitParagraphs(text))
            }

            let languageRange = match.range(at: 1)
            let codeRange = match.range(at: 2)
            let language = languageRange.location != NSNotFound ? nsString.substring(with: languageRange) : ""
            let code = nsString.substring(with: codeRange)
            blocks.append(ContentBlock(text: code, kind: .code(language: language)))

            lastIndex = match.range.location + match.range.length
        }

        if lastIndex < nsString.length {
            let text = nsString.substring(from: lastIndex)
            blocks.append(contentsOf: splitParagraphs(text))
        }

        return blocks.isEmpty ? splitParagraphs(content) : blocks
    }

    private func splitParagraphs(_ text: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blocks.append(ContentBlock(text: "", kind: .blank))
            } else {
                blocks.append(ContentBlock(text: trimmed, kind: .paragraph))
            }
        }
        return blocks
    }

    enum BlockKind: Hashable {
        case paragraph
        case code(language: String)
        case blank
    }

    struct ContentBlock: Identifiable {
        let id = UUID()
        let text: String
        let kind: BlockKind
    }

    enum GroupedBlockKind {
        case text
        case code(language: String)
    }

    struct GroupedBlock: Identifiable {
        let id = UUID()
        let kind: GroupedBlockKind
        let text: String
        let attributed: AttributedString
    }
}

struct CodeBlock: View {
    let code: String
    let language: String
    @State private var copied = false
    @State private var highlightedText: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: copyCode) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("复制代码")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlightedText ?? AttributedString(code))
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        .task(id: code) {
            highlightedText = highlightCode()
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }

    private func highlightCode() -> AttributedString {
        var attributed = AttributedString(code)

        let keywords = ["func", "let", "var", "if", "else", "for", "while", "return", "class", "struct", "enum", "import", "const", "async", "await", "def", "public", "private"]
        let keywordColor = Color.purple
        let stringColor = Color.red
        let commentColor = Color.green.opacity(0.8)

        for keyword in keywords {
            let pattern = "\\b\(keyword)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsString = code as NSString
                let matches = regex.matches(in: code, range: NSRange(location: 0, length: nsString.length))
                for match in matches {
                    if let stringRange = Range(match.range, in: code),
                       let attrRange = Range(stringRange, in: attributed) {
                        attributed[attrRange].foregroundColor = keywordColor
                    }
                }
            }
        }

        if let stringRegex = try? NSRegularExpression(pattern: "\"[^\"]*\"|'[^']*'") {
            let nsString = code as NSString
            let matches = stringRegex.matches(in: code, range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if let stringRange = Range(match.range, in: code),
                   let attrRange = Range(stringRange, in: attributed) {
                    attributed[attrRange].foregroundColor = stringColor
                }
            }
        }

        if let commentRegex = try? NSRegularExpression(pattern: "//.*|/\\*[\\s\\S]*?\\*/|#.*") {
            let nsString = code as NSString
            let matches = commentRegex.matches(in: code, range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if let stringRange = Range(match.range, in: code),
                   let attrRange = Range(stringRange, in: attributed) {
                    attributed[attrRange].foregroundColor = commentColor
                }
            }
        }

        return attributed
    }
}

struct AttachmentDisplay: View {
    let attachment: ChatAttachment

    var body: some View {
        if attachment.isImage, !attachment.content.isEmpty,
           let data = Data(base64Encoded: attachment.content),
           let nsImage = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 300)
                    .cornerRadius(8)
                Text(attachment.fileName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: attachment.iconName)
                    .foregroundColor(.secondary)
                Text(attachment.fileName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

struct AttachmentPreview: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.iconName)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(attachment.fileName)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
}
