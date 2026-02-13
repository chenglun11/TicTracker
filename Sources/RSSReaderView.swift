import SwiftUI

struct RSSReaderView: View {
    @Bindable var store: DataStore
    @State private var selectedFeedID: UUID?
    @State private var searchText = ""

    private var feeds: [RSSFeed] {
        store.rssFeeds
    }

    private var selectedItems: [RSSItem] {
        guard let feedID = selectedFeedID else { return [] }
        let items = store.rssItems[feedID.uuidString] ?? []
        if searchText.isEmpty { return items }
        let query = searchText.lowercased()
        return items.filter {
            $0.title.lowercased().contains(query) ||
            $0.summary.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            feedList
        } detail: {
            itemList
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
            HStack {
                Circle()
                    .fill(feed.enabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.name)
                        .font(.body)
                    Text("\(store.rssItems[feed.id.uuidString]?.count ?? 0) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
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
                    RSSItemRow(item: item)
                }
            }
        }
    }
}

// MARK: - Item Row

private struct RSSItemRow: View {
    let item: RSSItem

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: item.link) {
                NSWorkspace.shared.open(url)
            }
        }
        .contextMenu {
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
