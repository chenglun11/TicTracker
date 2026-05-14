import SwiftUI

struct RSSTab: View {
    @Bindable var store: DataStore
    @State private var newFeedName = ""
    @State private var newFeedURL = ""
    @State private var checking = false
    @State private var checkResult: String?
    @State private var deletingFeed: RSSFeed?
    @State private var expandedFeeds: Set<UUID> = []
    @State private var saveState = AutoSaveState()

    var body: some View {
        Form {
            Section("RSS 订阅") {
                Toggle(isOn: Bindable(store).rssEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用 RSS 订阅")
                        Text("关闭后停止轮询和推送通知，菜单栏中隐藏 RSS 入口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: store.rssEnabled) { _, _ in saveState.triggerSave() }
            }

            if store.rssEnabled {
                Section("添加订阅源") {
                    TextField("名称", text: $newFeedName)
                        .textFieldStyle(UnderlineTextFieldStyle())
                    TextField("URL", text: $newFeedURL)
                        .textFieldStyle(UnderlineTextFieldStyle())
                    HStack {
                        Button("添加") { addFeed() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newFeedName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      newFeedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("订阅列表") {
                    if store.rssFeeds.isEmpty {
                        Text("暂无订阅源")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(store.rssFeeds.enumerated()), id: \.element.id) { i, feed in
                            VStack(alignment: .leading, spacing: 0) {
                                // Main row
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { feed.enabled },
                                        set: {
                                            store.rssFeeds[i].enabled = $0
                                            saveState.triggerSave()
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)

                                    Text(feed.name)
                                        .font(.body)

                                    Spacer()

                                    Text("\(store.rssItems[feed.id.uuidString]?.count ?? 0) 条")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()

                                    Button {
                                        testFeed(feed)
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(checking)
                                    .help("立即检查")

                                    Button {
                                        deletingFeed = feed
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.red.opacity(0.7))
                                    }
                                    .buttonStyle(.borderless)

                                    Button {
                                        withAnimation {
                                            if expandedFeeds.contains(feed.id) {
                                                expandedFeeds.remove(feed.id)
                                            } else {
                                                expandedFeeds.insert(feed.id)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: expandedFeeds.contains(feed.id) ? "chevron.up" : "chevron.down")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(expandedFeeds.contains(feed.id) ? "收起详情" : "展开详情")
                                }

                                // Expanded details
                                if expandedFeeds.contains(feed.id) {
                                    HStack(spacing: 8) {
                                        Text(feed.url)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("轮询间隔")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Picker("", selection: Binding(
                                            get: { feed.pollingInterval },
                                            set: {
                                                store.rssFeeds[i].pollingInterval = $0
                                                saveState.triggerSave()
                                            }
                                        )) {
                                            Text("5m").tag(5)
                                            Text("10m").tag(10)
                                            Text("15m").tag(15)
                                            Text("30m").tag(30)
                                            Text("60m").tag(60)
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .frame(width: 60)
                                    }
                                    .padding(.top, 6)
                                    .padding(.leading, 32)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    HStack(spacing: 8) {
                        Button(checking ? "检查中…" : "立即检查全部") {
                            checkAll()
                        }
                        .controlSize(.small)
                        .disabled(checking || store.rssFeeds.isEmpty)
                        if checking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                if let result = checkResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("失败") || result.contains("无效") ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .autoSaveIndicator(saveState)
        .alert("确认删除「\(deletingFeed?.name ?? "")」？", isPresented: Binding(
            get: { deletingFeed != nil },
            set: { if !$0 { deletingFeed = nil } }
        )) {
            Button("取消", role: .cancel) { deletingFeed = nil }
            Button("删除", role: .destructive) {
                if let feed = deletingFeed {
                    store.rssFeeds.removeAll { $0.id == feed.id }
                    store.rssItems.removeValue(forKey: feed.id.uuidString)
                }
                deletingFeed = nil
            }
        }
    }

    private func addFeed() {
        let name = newFeedName.trimmingCharacters(in: .whitespaces)
        let url = newFeedURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty, URL(string: url)?.scheme != nil else { return }
        let feed = RSSFeed(name: name, url: url)
        store.rssFeeds.append(feed)
        newFeedName = ""
        newFeedURL = ""
    }

    private func testFeed(_ feed: RSSFeed) {
        checking = true
        checkResult = nil
        Task {
            let result = await RSSFeedManager.shared.checkFeed(feed)
            switch result {
            case .success(let newCount, let totalCount):
                checkResult = newCount > 0
                    ? "获取到 \(newCount) 条新条目（共 \(totalCount) 条）"
                    : "已是最新（共 \(totalCount) 条）"
            case .empty:
                checkResult = "连接成功，但该 feed 暂无条目"
            case .fetchError:
                checkResult = "获取失败，请检查网络或 URL"
            case .invalidURL:
                checkResult = "URL 格式无效"
            }
            checking = false
        }
    }

    private func checkAll() {
        checking = true
        checkResult = nil
        Task {
            await RSSFeedManager.shared.checkAllFeeds()
            let total = store.rssFeeds.reduce(0) { $0 + (store.rssItems[$1.id.uuidString]?.count ?? 0) }
            checkResult = "检查完成，共 \(total) 条"
            checking = false
        }
    }
}

// MARK: - Jira Tab
