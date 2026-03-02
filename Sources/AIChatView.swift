import SwiftUI

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date

    enum MessageRole: String, Codable {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

@MainActor
final class AIChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let store: DataStore
    private let aiService = AIService.shared
    private let log = DevLog.shared

    init(store: DataStore) {
        self.store = store
        loadMessages()
    }

    func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, content: trimmed)
        messages.append(userMessage)
        inputText = ""
        errorMessage = nil

        Task {
            await generateResponse(for: trimmed)
        }
    }

    private func generateResponse(for userInput: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await aiService.chat(
                message: userInput,
                history: messages.dropLast().suffix(10).map { ($0.role.rawValue, $0.content) },
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
        if let data = try? JSONEncoder().encode(messages) {
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

                Button(action: { viewModel.clearHistory() }) {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.messages.isEmpty)
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

            // Input area
            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息...", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !viewModel.inputText.isEmpty {
                            viewModel.sendMessage()
                        }
                    }

                Button(action: { viewModel.sendMessage() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear {
            isInputFocused = true
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
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(backgroundColor)
                    .foregroundColor(textColor)
                    .cornerRadius(12)
                    .textSelection(.enabled)

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
