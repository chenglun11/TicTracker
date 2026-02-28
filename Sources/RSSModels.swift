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
}
