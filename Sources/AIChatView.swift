import SwiftUI
import UniformTypeIdentifiers

struct ChatAttachment: Identifiable, Codable {
    let id: UUID
    let fileName: String
    let fileType: String
    let content: String // Base64 for images, plain text for text files
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
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var attachments: [ChatAttachment] = []

    private let store: DataStore
    private let aiService = AIService.shared
    private let log = DevLog.shared

    init(store: DataStore) {
        self.store = store
        loadMessages()
    }

    func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: trimmed, attachments: attachments)
        messages.append(userMessage)
        inputText = ""
        let currentAttachments = attachments
        attachments = []
        errorMessage = nil

        Task {
            await generateResponse(for: trimmed, attachments: currentAttachments)
        }
    }

    func addAttachment(from url: URL) {
        // 限制最多 5 个附件
        guard attachments.count < 5 else {
            errorMessage = "最多只能添加 5 个附件"
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

            // 支持的文件类型
            let supportedImageTypes = ["png", "jpg", "jpeg", "gif", "webp"]
            let supportedTextTypes = ["txt", "md", "json", "xml", "csv", "log", "swift", "py", "js", "ts", "html", "css"]

            if supportedImageTypes.contains(fileType) {
                // 图片文件
                let data = try Data(contentsOf: url)

                // 限制图片大小为 5MB
                guard data.count <= 5_000_000 else {
                    errorMessage = "图片过大（最大 5MB）"
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
                // 文本文件
                let content = try String(contentsOf: url, encoding: .utf8)
                let byteCount = content.utf8.count
                guard byteCount <= 50_000 else {
                    errorMessage = "文件过大（最大 50KB）"
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

    var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !attachments.isEmpty
        return (hasText || hasAttachments) && !isLoading
    }

    private func generateResponse(for userInput: String, attachments: [ChatAttachment]) async {
        isLoading = true
        defer { isLoading = false }

        do {
            // 获取历史记录（排除刚添加的用户消息，因为它会作为 message 参数传递）
            let maxHistory = max(1, store.aiConfig.chatMaxHistory)
            let historyMessages = messages.dropLast().suffix(maxHistory).map { msg -> (String, String) in
                var content = msg.content
                // 如果历史消息有附件，添加附件信息到内容中
                if !msg.attachments.isEmpty {
                    content += "\n[附件: \(msg.attachments.map { $0.fileName }.joined(separator: ", "))]"
                }
                return (msg.role.rawValue, content)
            }

            // 转换附件格式
            let attachmentTuples = attachments.map { (fileName: $0.fileName, content: $0.content, mimeType: $0.mimeType) }

            let response = try await aiService.chat(
                message: userInput,
                attachments: attachmentTuples,
                history: historyMessages,
                config: store.aiConfig
            )

            let assistantMessage = ChatMessage(role: .assistant, content: response)
            messages.append(assistantMessage)
            saveMessages()

        } catch {
            log.error("AIChat", "对话失败: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func clearHistory() {
        messages.removeAll()
        saveMessages()
        errorMessage = nil
    }

    private func saveMessages() {
        // 只保存最近 100 条消息，避免 UserDefaults 过大
        // 保存时清除附件的 content，只保留文件名元信息
        let messagesToSave = messages.suffix(100).map { msg -> ChatMessage in
            let lightAttachments = msg.attachments.map {
                ChatAttachment(
                    id: $0.id,
                    fileName: $0.fileName,
                    fileType: $0.fileType,
                    content: "", // 不持久化附件内容
                    mimeType: $0.mimeType
                )
            }
            return ChatMessage(
                id: msg.id,
                role: msg.role,
                content: msg.content,
                timestamp: msg.timestamp,
                attachments: lightAttachments
            )
        }
        if let data = try? JSONEncoder().encode(messagesToSave) {
            UserDefaults.standard.set(data, forKey: "ai_chat_messages")
        }
    }

    private func loadMessages() {
        guard let data = UserDefaults.standard.data(forKey: "ai_chat_messages"),
              let loaded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return
        }
        messages = loaded
    }
}

struct AIChatView: View {
    @StateObject private var viewModel: AIChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var showClearConfirmation = false
    @State private var showFilePicker = false

    init(store: DataStore) {
        _viewModel = StateObject(wrappedValue: AIChatViewModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI 对话")
                    .font(.headline)

                Spacer()

                Button(action: { showClearConfirmation = true }) {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.messages.isEmpty)
                .confirmationDialog("确定要清空所有对话记录吗？", isPresented: $showClearConfirmation) {
                    Button("清空", role: .destructive) {
                        viewModel.clearHistory()
                    }
                    Button("取消", role: .cancel) {}
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if viewModel.messages.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        if viewModel.isLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("思考中...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 12)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Error message
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("关闭") {
                        viewModel.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
            }

            Divider()

            // Attachments preview
            if !viewModel.attachments.isEmpty {
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

            // Input area
            VStack(spacing: 0) {
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
                            if viewModel.canSend {
                                viewModel.sendMessage()
                            }
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
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear {
            isInputFocused = true
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
                if let url = urls.first {
                    viewModel.addAttachment(from: url)
                }
            case .failure(let error):
                viewModel.errorMessage = "选择文件失败: \(error.localizedDescription)"
            }
        }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Attachments
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { attachment in
                        AttachmentBubble(attachment: attachment)
                    }
                }

                // Text content
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(backgroundColor)
                        .foregroundColor(textColor)
                        .cornerRadius(12)
                        .textSelection(.enabled)
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: 500, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .assistant {
                Spacer()
            }
        }
    }

    private var backgroundColor: Color {
        message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor)
    }

    private var textColor: Color {
        message.role == .user ? .white : .primary
    }
}

struct AttachmentBubble: View {
    let attachment: ChatAttachment

    var body: some View {
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
