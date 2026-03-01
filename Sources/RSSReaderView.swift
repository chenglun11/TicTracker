import SwiftUI

enum RSSFilter: String, CaseIterable {
    case all = "全部"
    case unread = "未读"
    case favorite = "收藏"
}

struct RSSReaderView: View {
    @Bindable var store: DataStore
    @State private var selectedFeedID: UUID?
    @State private var searchText = ""
    @State private var filter: RSSFilter = .all

    private var feeds: [RSSFeed] {
        store.rssFeeds
    }

    private var selectedItems: [RSSItem] {
        guard let feedID = selectedFeedID else { return [] }
        var items = store.rssItems[feedID.uuidString] ?? []

        // Apply filter
        switch filter {
        case .all: break
        case .unread: items = items.filter { !$0.isRead }
        case .favorite: items = items.filter { $0.isFavorite }
        }

        // Apply search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            items = items.filter {
                $0.title.lowercased().contains(query) ||
                $0.summary.lowercased().contains(query)
            }
        }

        return items
    }

    private var unreadCount: Int {
        guard let feedID = selectedFeedID else { return 0 }
        return (store.rssItems[feedID.uuidString] ?? []).filter { !$0.isRead }.count
    }

    var body: some View {
        NavigationSplitView {
            feedList
        } detail: {
            VStack(spacing: 0) {
                // Filter toolbar
                HStack(spacing: 12) {
                    Picker("", selection: $filter) {
                        ForEach(RSSFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    if unreadCount > 0 {
                        Text("\(unreadCount) 未读")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let feedID = selectedFeedID, unreadCount > 0 {
                        Button("全部已读") {
                            store.markAllRSSItemsRead(feedID: feedID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                itemList
            }
        }
        .searchable(text: $searchText, prompt: "搜索条目")
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            if selectedFeedID == nil {
                selectedFeedID = feeds.first?.id
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Feed List (Sidebar)

    private var feedList: some View {
        List(feeds, selection: $selectedFeedID) { feed in
            HStack(spacing: 8) {
                Circle()
                    .fill(feed.enabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.name)
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        let totalCount = store.rssItems[feed.id.uuidString]?.count ?? 0
                        let unreadCount = (store.rssItems[feed.id.uuidString] ?? []).filter { !$0.isRead }.count
                        Text("\(totalCount) 条")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if unreadCount > 0 {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("\(unreadCount) 未读")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    // MARK: - Item List (Detail)

    private var itemList: some View {
        Group {
            if selectedFeedID == nil {
                ContentUnavailableView("选择一个订阅源", systemImage: "dot.radiowaves.up.forward")
            } else if selectedItems.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "暂无条目" : "无匹配结果",
                    systemImage: searchText.isEmpty ? "tray" : "magnifyingglass"
                )
            } else {
                List(selectedItems) { item in
                    RSSItemRow(item: item, store: store)
                }
            }
        }
    }
}

// MARK: - Item Row

private struct RSSItemRow: View {
    let item: RSSItem
    @Bindable var store: DataStore

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt
    }()

    var body: some View {
        HStack(spacing: 8) {
            // Read indicator
            Circle()
                .fill(item.isRead ? Color.clear : Color.blue)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundStyle(item.isRead ? .secondary : .primary)
                    Spacer()
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    if let date = item.pubDate {
                        Text(Self.dateFormatter.string(from: date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: item.link) {
                NSWorkspace.shared.open(url)
                if !item.isRead {
                    store.toggleRSSItemRead(feedID: item.feedID, itemID: item.id)
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.toggleRSSItemRead(feedID: item.feedID, itemID: item.id)
            } label: {
                Label(item.isRead ? "未读" : "已读", systemImage: item.isRead ? "envelope.badge" : "envelope.open")
            }
            .tint(item.isRead ? .blue : .gray)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                store.toggleRSSItemFavorite(feedID: item.feedID, itemID: item.id)
            } label: {
                Label(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button(item.isRead ? "标记为未读" : "标记为已读") {
                store.toggleRSSItemRead(feedID: item.feedID, itemID: item.id)
            }
            Button(item.isFavorite ? "取消收藏" : "收藏") {
                store.toggleRSSItemFavorite(feedID: item.feedID, itemID: item.id)
            }
            Divider()
            Button("在浏览器中打开") {
                if let url = URL(string: item.link) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.link, forType: .string)
            }
        }
    }
}
