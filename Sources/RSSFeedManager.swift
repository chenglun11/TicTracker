import AppKit
import Foundation
import CryptoKit
import Network

@MainActor
final class RSSFeedManager {
    static let shared = RSSFeedManager()

    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private weak var store: DataStore?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.tictracker.rss.path-monitor")
    private var lastNetworkStatus: NWPath.Status?
    private var lastRecoveryRestartAt: Date?

    private let log = DevLog.shared
    private let mod = "RSS"
    private let recoveryRestartDebounce: TimeInterval = 10

    func setup(store: DataStore) {
        self.store = store
        observeSystemWake()
        startNetworkMonitor()
        log.info(mod, "初始化，\(store.rssFeeds.count) 个订阅源")
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        guard let store else {
            log.warn(mod, "轮询未启动：store 未就绪")
            return
        }
        guard store.rssEnabled else {
            log.info(mod, "RSS 已关闭，跳过轮询启动")
            return
        }

        let enabledFeeds = store.rssFeeds.filter(\.enabled)
        guard !enabledFeeds.isEmpty else {
            log.info(mod, "没有启用的订阅源，轮询未启动")
            return
        }

        for feed in enabledFeeds {
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

    func syncPollingState() {
        guard store?.rssEnabled == true else {
            stopPolling()
            return
        }
        startPolling()
    }

    func restartPolling(for feedID: UUID) {
        pollingTasks[feedID]?.cancel()
        pollingTasks.removeValue(forKey: feedID)
        guard let feed = store?.rssFeeds.first(where: { $0.id == feedID }), feed.enabled else { return }
        startPolling(for: feed)
    }

    private func startPolling(for feed: RSSFeed) {
        pollingTasks[feed.id]?.cancel()
        let minutes = max(feed.pollingInterval, 1)
        log.info(mod, "轮询启动 [\(feed.name)]，间隔 \(minutes) 分钟")
        pollingTasks[feed.id] = Task { [weak self, feedID = feed.id] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let store = self.store, store.rssEnabled else {
                    self.log.info(self.mod, "轮询结束：RSS 已关闭 [\(feed.name)]")
                    return
                }
                guard let currentFeed = store.rssFeeds.first(where: { $0.id == feedID }) else {
                    self.log.info(self.mod, "轮询结束：订阅源已删除 [\(feed.name)]")
                    return
                }
                guard currentFeed.enabled else {
                    self.log.info(self.mod, "轮询结束：订阅源已停用 [\(currentFeed.name)]")
                    return
                }

                await self.checkFeed(currentFeed)

                let interval = max(currentFeed.pollingInterval, 1)
                self.log.info(self.mod, "[\(currentFeed.name)] 下次检查: \(interval) 分钟后")
                do {
                    try await Task.sleep(for: .seconds(interval * 60))
                } catch {
                    break
                }
            }
            self?.log.info(self?.mod ?? "RSS", "轮询任务已取消 [\(feed.name)]")
        }
    }

    // MARK: - Recovery

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverPolling(reason: "系统唤醒")
            }
        }
    }

    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.lastNetworkStatus
                self.lastNetworkStatus = path.status
                if path.status == .satisfied, previous != nil, previous != .satisfied {
                    self.recoverPolling(reason: "网络恢复")
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func recoverPolling(reason: String) {
        guard store?.rssEnabled == true else { return }
        let now = Date()
        if let lastRecoveryRestartAt,
           now.timeIntervalSince(lastRecoveryRestartAt) < recoveryRestartDebounce {
            log.info(mod, "\(reason)：距离上次恢复检查太近，跳过")
            return
        }
        lastRecoveryRestartAt = now
        log.info(mod, "\(reason)：重启 RSS 轮询并立即检查")
        startPolling()
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
            pubDate: pubDate,
            isRead: false,
            isFavorite: false
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
