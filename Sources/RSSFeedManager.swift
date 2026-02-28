import Foundation
import CryptoKit

@MainActor
final class RSSFeedManager {
    static let shared = RSSFeedManager()

    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private weak var store: DataStore?

    private let log = DevLog.shared
    private let mod = "RSS"

    func setup(store: DataStore) {
        self.store = store
        log.info(mod, "初始化，\(store.rssFeeds.count) 个订阅源")
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        guard let store else { return }
        for feed in store.rssFeeds where feed.enabled {
            startPolling(for: feed)
        }
    }

    func stopPolling() {
        pollingTasks.values.forEach { $0.cancel() }
        pollingTasks.removeAll()
    }

    func restartPolling() {
        startPolling()
    }

    func restartPolling(for feedID: UUID) {
        pollingTasks[feedID]?.cancel()
        pollingTasks.removeValue(forKey: feedID)
        guard let feed = store?.rssFeeds.first(where: { $0.id == feedID }), feed.enabled else { return }
        startPolling(for: feed)
    }

    private func startPolling(for feed: RSSFeed) {
        let minutes = max(feed.pollingInterval, 1)
        log.info(mod, "轮询启动 [\(feed.name)]，间隔 \(minutes) 分钟")
        pollingTasks[feed.id] = Task { [weak self] in
            while !Task.isCancelled {
                if let feed = self?.store?.rssFeeds.first(where: { $0.id == feed.id }), feed.enabled {
                    await self?.checkFeed(feed)
                }
                let interval = self?.store?.rssFeeds.first(where: { $0.id == feed.id })?.pollingInterval ?? minutes
                self?.log.info(self?.mod ?? "RSS", "[\(feed.name)] 下次检查: \(interval) 分钟后")
                try? await Task.sleep(for: .seconds(max(interval, 1) * 60))
            }
        }
    }

    // MARK: - Feed Checking

    func checkAllFeeds() async {
        guard let store else { return }
        for feed in store.rssFeeds where feed.enabled {
            await checkFeed(feed)
        }
    }

    enum CheckResult {
        case success(newCount: Int, totalCount: Int)
        case empty          // feed parsed OK but has no items
        case fetchError
        case invalidURL
    }

    @discardableResult
    func checkFeed(_ feed: RSSFeed) async -> CheckResult {
        log.info(mod, "检查 [\(feed.name)] \(feed.url)")
        guard let url = URL(string: feed.url) else {
            log.error(mod, "URL 无效")
            return .invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("TicTracker/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log.error(mod, "网络错误: \(error.localizedDescription)")
            return .fetchError
        }

        if let http = response as? HTTPURLResponse {
            log.info(mod, "HTTP \(http.statusCode), \(data.count) bytes")
            if http.statusCode != 200 {
                log.error(mod, "非 200 状态码")
                return .fetchError
            }
        }

        let newItems = parseFeed(data: data, feedID: feed.id)
        log.info(mod, "解析到 \(newItems.count) 条目")
        guard let store else {
            log.error(mod, "store 已释放")
            return .fetchError
        }
        guard !newItems.isEmpty else {
            log.warn(mod, "feed 为空（无 item/entry）")
            return .empty
        }

        let existingIDs = Set((store.rssItems[feed.id.uuidString] ?? []).map(\.id))
        let freshItems = newItems.filter { !existingIDs.contains($0.id) }
        log.info(mod, "已有 \(existingIDs.count) 条，新增 \(freshItems.count) 条")

        if !freshItems.isEmpty {
            var current = store.rssItems[feed.id.uuidString] ?? []
            current.insert(contentsOf: freshItems, at: 0)
            // Keep max 100 per feed
            if current.count > 100 {
                current = Array(current.prefix(100))
            }
            store.rssItems[feed.id.uuidString] = current

            // Notify only if we had existing items (skip first fetch flood)
            if !existingIDs.isEmpty {
                for item in freshItems.prefix(3) {
                    NotificationManager.shared.notifyRSSItem(
                        feedName: feed.name,
                        title: item.title,
                        link: item.link
                    )
                }
            }
        }
        let total = store.rssItems[feed.id.uuidString]?.count ?? 0
        return .success(newCount: freshItems.count, totalCount: total)
    }

    // MARK: - XML Parsing (off main thread)

    nonisolated func parseFeed(data: Data, feedID: UUID) -> [RSSItem] {
        let delegate = RSSXMLParserDelegate(feedID: feedID)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }
}

// MARK: - XMLParser Delegate

private final class RSSXMLParserDelegate: NSObject, XMLParserDelegate {
    let feedID: UUID
    var items: [RSSItem] = []

    private enum FeedFormat { case unknown, rss, atom }
    private var format: FeedFormat = .unknown

    // Current parsing state
    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var currentSummary = ""
    private var currentGUID = ""
    private var currentPubDate = ""
    private var insideItem = false

    init(feedID: UUID) {
        self.feedID = feedID
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName

        switch elementName {
        case "rss":
            format = .rss
        case "feed":
            if format == .unknown { format = .atom }
        case "item":
            insideItem = true
            resetCurrent()
        case "entry":
            insideItem = true
            resetCurrent()
        case "link":
            if insideItem && format == .atom {
                // Atom: <link href="..." /> — prefer rel="alternate" or no rel
                let rel = attributeDict["rel"] ?? "alternate"
                if rel == "alternate", let href = attributeDict["href"] {
                    currentLink = href
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title":
            currentTitle += string
        case "link":
            if format == .rss { currentLink += string }
        case "description":
            currentSummary += string
        case "summary", "content":
            if format == .atom { currentSummary += string }
        case "guid", "id":
            currentGUID += string
        case "pubDate", "updated", "published":
            currentPubDate += string
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        currentElement = ""  // Reset to prevent stale element capturing whitespace

        guard elementName == "item" || elementName == "entry" else { return }
        insideItem = false

        let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = stripHTML(currentSummary.trimmingCharacters(in: .whitespacesAndNewlines))
        let guid = currentGUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateStr = currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dedup ID: prefer guid/id, fallback to link hash
        let itemID: String
        if !guid.isEmpty {
            itemID = guid
        } else if !link.isEmpty {
            let hash = Insecure.MD5.hash(data: Data(link.utf8))
            itemID = hash.map { String(format: "%02x", $0) }.joined()
        } else {
            let hash = Insecure.MD5.hash(data: Data(title.utf8))
            itemID = hash.map { String(format: "%02x", $0) }.joined()
        }

        let pubDate = Self.parseDate(dateStr)

        let item = RSSItem(
            id: itemID,
            feedID: feedID,
            title: title,
            link: link,
            summary: String(summary.prefix(500)),
            pubDate: pubDate
        )
        items.append(item)
    }

    private func resetCurrent() {
        currentTitle = ""
        currentLink = ""
        currentSummary = ""
        currentGUID = ""
        currentPubDate = ""
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // Date parsing for RSS (RFC 822) and Atom (ISO 8601)
    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",     // RFC 822
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC 822 variant
            "yyyy-MM-dd'T'HH:mm:ssZ",           // ISO 8601
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",       // ISO 8601 with ms
            "yyyy-MM-dd'T'HH:mm:ssxxxxx",       // ISO 8601 with colon tz
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.dateFormat = fmt
            df.locale = Locale(identifier: "en_US_POSIX")
            return df
        }
    }()

    private static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        // Try ISO8601DateFormatter as last resort
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: string)
    }
}
