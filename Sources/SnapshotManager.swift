import Foundation

struct OperationLogEntry: Identifiable, Codable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var module: String
    var action: String
    var detail: String
}

struct SnapshotEntry: Identifiable, Codable {
    var id: UUID = UUID()
    var timestamp: Date
    var description: String
    var filename: String
}

@MainActor
final class SnapshotManager {
    static let shared = SnapshotManager()

    private let maxSnapshots = 50
    private let snapshotInterval: TimeInterval = 30 * 60 // 30 minutes

    private var snapshotDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TicTracker/snapshots", isDirectory: true)
    }

    private var indexFile: URL {
        snapshotDir.appendingPathComponent("index.json")
    }

    private(set) var entries: [SnapshotEntry] = []
    private(set) var lastSnapshotDate: Date?

    private init() {
        ensureDirectory()
        loadIndex()
        lastSnapshotDate = entries.first?.timestamp
    }

    // MARK: - Public

    func saveSnapshot(from store: DataStore, description: String = "自动快照") {
        guard let json = store.exportJSON() else { return }
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "snapshot_\(fmt.string(from: now)).json"
        let fileURL = snapshotDir.appendingPathComponent(filename)

        do {
            try json.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            DevLog.shared.error("Snapshot", "保存快照失败: \(error.localizedDescription)")
            return
        }

        let entry = SnapshotEntry(timestamp: now, description: description, filename: filename)
        entries.insert(entry, at: 0)
        lastSnapshotDate = now
        pruneOldSnapshots()
        saveIndex()
        DevLog.shared.info("Snapshot", "快照已保存: \(description)")
    }

    func restoreSnapshot(id: UUID, to store: DataStore) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        let fileURL = snapshotDir.appendingPathComponent(entry.filename)
        guard let json = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }

        // Save current state as backup before restoring
        saveSnapshot(from: store, description: "恢复前自动备份")

        let ok = store.importJSON(from: json)
        if ok {
            DevLog.shared.info("Snapshot", "已恢复到: \(entry.description) (\(entry.timestamp))")
        }
        return ok
    }

    func deleteSnapshot(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[idx]
        let fileURL = snapshotDir.appendingPathComponent(entry.filename)
        try? FileManager.default.removeItem(at: fileURL)
        entries.remove(at: idx)
        saveIndex()
    }

    func autoSnapshotIfNeeded(store: DataStore) {
        if let last = lastSnapshotDate {
            guard Date().timeIntervalSince(last) >= snapshotInterval else { return }
        }
        saveSnapshot(from: store)
    }

    // MARK: - Private

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile),
              let decoded = try? JSONDecoder().decode([SnapshotEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexFile)
    }

    private func pruneOldSnapshots() {
        while entries.count > maxSnapshots {
            let removed = entries.removeLast()
            let fileURL = snapshotDir.appendingPathComponent(removed.filename)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
