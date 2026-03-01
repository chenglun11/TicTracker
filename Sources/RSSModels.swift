import Foundation

struct RSSFeed: Codable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var enabled: Bool
    var pollingInterval: Int  // minutes

    init(id: UUID = UUID(), name: String, url: String, enabled: Bool = true, pollingInterval: Int = 10) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.pollingInterval = pollingInterval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        pollingInterval = try c.decodeIfPresent(Int.self, forKey: .pollingInterval) ?? 10
    }
}

struct RSSItem: Codable, Identifiable {
    let id: String          // guid or link hash for dedup
    let feedID: UUID
    let title: String
    let link: String
    let summary: String
    let pubDate: Date?
    var isRead: Bool
    var isFavorite: Bool

    init(id: String, feedID: UUID, title: String, link: String, summary: String, pubDate: Date?, isRead: Bool = false, isFavorite: Bool = false) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.link = link
        self.summary = summary
        self.pubDate = pubDate
        self.isRead = isRead
        self.isFavorite = isFavorite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        feedID = try c.decode(UUID.self, forKey: .feedID)
        title = try c.decode(String.self, forKey: .title)
        link = try c.decode(String.self, forKey: .link)
        summary = try c.decode(String.self, forKey: .summary)
        pubDate = try c.decodeIfPresent(Date.self, forKey: .pubDate)
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}
