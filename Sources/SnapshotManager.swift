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
@Observable
final class SnapshotManager {
    static let shared = SnapshotManager()

    private let maxSnapshots = 50
    private let maxSnapshotBytes: Int64 = 16 * 1024 * 1024
    private let minSnapshots = 12
    private let snapshotInterval: TimeInterval = 30 * 60 // 30 minutes
    private let snapshotFilenamePrefix = "snapshot_"
    private let snapshotFileExtension = "json"
    private let snapshotDateTokenLength = 15
    private let snapshotFilenameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt
    }()

    private var snapshotDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TicTracker/snapshots", isDirectory: true)
    }

    private var indexFile: URL {
        snapshotDir.appendingPathComponent("index.json")
    }

    var entries: [SnapshotEntry] = []
    private(set) var lastSnapshotDate: Date?

    private init() {
        ensureDirectory()
        loadIndex()
        reconcileSnapshotFiles()
        pruneOldSnapshots()
        saveIndex()
        lastSnapshotDate = entries.first?.timestamp
    }

    // MARK: - Public

    @discardableResult
    func saveSnapshot(from store: DataStore, description: String = "自动快照") -> Bool {
        guard let json = store.exportJSON() else { return false }
        ensureDirectory()
        reconcileSnapshotFiles()

        let now = Date()
        let filename = nextSnapshotFilename(for: now)
        let fileURL = snapshotDir.appendingPathComponent(filename)

        do {
            try json.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            DevLog.shared.error("Snapshot", "保存快照失败: \(error.localizedDescription)")
            return false
        }

        let entry = SnapshotEntry(timestamp: now, description: description, filename: filename)
        entries.insert(entry, at: 0)
        lastSnapshotDate = now
        pruneOldSnapshots()
        saveIndex()
        DevLog.shared.info("Snapshot", "快照已保存: \(description)")
        return true
    }

    func restoreSnapshot(id: UUID, to store: DataStore) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        let fileURL = snapshotDir.appendingPathComponent(entry.filename)
        guard let json = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }

        // Save current state as backup before restoring
        guard saveSnapshot(from: store, description: "恢复前自动备份") else { return false }

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
            entries = discoveredSnapshotEntries()
            return
        }
        entries = decoded.sorted { $0.timestamp > $1.timestamp }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexFile)
    }

    private func pruneOldSnapshots() {
        entries.sort { $0.timestamp > $1.timestamp }
        while entries.count > maxSnapshots {
            removeSnapshotFile(entries.removeLast().filename)
        }
        while totalSnapshotBytes() > maxSnapshotBytes, entries.count > minSnapshots {
            removeSnapshotFile(entries.removeLast().filename)
        }
        removeOrphanSnapshotFiles()
    }

    private func reconcileSnapshotFiles() {
        let files = snapshotFiles()
        let fileNames = Set(files.map(\.lastPathComponent))
        var seen: Set<String> = []
        entries = entries.filter { entry in
            fileNames.contains(entry.filename) && seen.insert(entry.filename).inserted
        }

        let indexed = Set(entries.map(\.filename))
        for file in files where !indexed.contains(file.lastPathComponent) {
            entries.append(SnapshotEntry(
                timestamp: timestamp(forSnapshot: file),
                description: "历史快照",
                filename: file.lastPathComponent
            ))
        }
        entries.sort { $0.timestamp > $1.timestamp }
    }

    private func discoveredSnapshotEntries() -> [SnapshotEntry] {
        snapshotFiles()
            .map {
                SnapshotEntry(
                    timestamp: timestamp(forSnapshot: $0),
                    description: "历史快照",
                    filename: $0.lastPathComponent
                )
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func snapshotFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter {
            $0.pathExtension == snapshotFileExtension
                && $0.lastPathComponent.hasPrefix(snapshotFilenamePrefix)
        }
    }

    private func nextSnapshotFilename(for date: Date) -> String {
        let base = "\(snapshotFilenamePrefix)\(snapshotFilenameFormatter.string(from: date))"
        var filename = "\(base).\(snapshotFileExtension)"
        var suffix = 2
        while FileManager.default.fileExists(atPath: snapshotDir.appendingPathComponent(filename).path) {
            filename = "\(base)_\(suffix).\(snapshotFileExtension)"
            suffix += 1
        }
        return filename
    }

    private func timestamp(forSnapshot url: URL) -> Date {
        let name = url.deletingPathExtension().lastPathComponent
        let rawToken = name.dropFirst(snapshotFilenamePrefix.count).prefix(snapshotDateTokenLength)
        if let parsed = snapshotFilenameFormatter.date(from: String(rawToken)) {
            return parsed
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func totalSnapshotBytes() -> Int64 {
        entries.reduce(Int64(0)) { total, entry in
            total + fileSize(snapshotDir.appendingPathComponent(entry.filename))
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func removeSnapshotFile(_ filename: String) {
        try? FileManager.default.removeItem(at: snapshotDir.appendingPathComponent(filename))
    }

    private func removeOrphanSnapshotFiles() {
        let indexed = Set(entries.map(\.filename))
        for file in snapshotFiles() where !indexed.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
