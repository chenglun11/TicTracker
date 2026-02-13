import Foundation

struct RSSFeed: Codable, Identifiable {
    let id: UUID
    var name: String
    var url: String
    var enabled: Bool

    init(id: UUID = UUID(), name: String, url: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
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
