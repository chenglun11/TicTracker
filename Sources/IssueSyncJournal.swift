import Foundation

enum IssueSyncOperationKind: String, Codable, Sendable {
    case upsert
    case delete
}

struct IssueSyncOperation: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var issueID: String
    var kind: IssueSyncOperationKind
    var baseRevision: Int64
    var issue: TrackedIssue?
    var createdAt: Date = Date()
    var attempts: Int = 0
}

struct IssueSyncConflict: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var issueID: String
    var base: TrackedIssue?
    var local: TrackedIssue?
    var remote: TrackedIssue
    var overlappingFields: [String]
    var createdAt: Date = Date()
}

struct IssueSyncJournalState: Codable, Sendable {
    var cursor: Int64 = 0
    var baseline: [String: TrackedIssue] = [:]
    var outbox: [IssueSyncOperation] = []
    var conflicts: [IssueSyncConflict] = []
    var bootstrapped = false
}

@MainActor
final class IssueSyncJournal {
    static let shared = IssueSyncJournal()

    private var states: [String: IssueSyncJournalState] = [:]
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("TicTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("issue-sync-journal.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: IssueSyncJournalState].self, from: data) {
            states = decoded
        }
    }

    func state(for serverKey: String) -> IssueSyncJournalState {
        states[serverKey] ?? IssueSyncJournalState()
    }

    func save(_ state: IssueSyncJournalState, for serverKey: String) {
        states[serverKey] = state
        persist()
    }

    func migrateStateIfNeeded(from legacyKey: String, to key: String) {
        guard legacyKey != key, states[key] == nil, let legacy = states.removeValue(forKey: legacyKey) else { return }
        states[key] = legacy
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    func discardPendingChanges(for serverKey: String) {
        var state = state(for: serverKey)
        state.outbox = []
        state.conflicts = []
        save(state, for: serverKey)
    }
}

func issueSyncJSON(_ issue: TrackedIssue) -> [String: Any]? {
    guard let data = try? JSONEncoder().encode(issue),
          var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    object.removeValue(forKey: "revision")
    object.removeValue(forKey: "updatedAt")
    object.removeValue(forKey: "updatedBy")
    return object
}

private func canonicalSyncValue(_ value: Any?) -> Data? {
    guard let value else { return nil }
    return try? JSONSerialization.data(withJSONObject: ["value": value], options: [.sortedKeys])
}

func issuesSyncEquivalent(_ lhs: TrackedIssue?, _ rhs: TrackedIssue?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (lhs?, rhs?):
        guard let left = issueSyncJSON(lhs), let right = issueSyncJSON(rhs) else { return false }
        return canonicalSyncValue(left) == canonicalSyncValue(right)
    default: return false
    }
}

func mergeDisjointIssueChanges(base: TrackedIssue?, local: TrackedIssue, remote: TrackedIssue) -> (TrackedIssue?, [String]) {
    guard let base,
          let baseJSON = issueSyncJSON(base),
          let localJSON = issueSyncJSON(local),
          let remoteJSON = issueSyncJSON(remote) else {
        return issuesSyncEquivalent(local, remote) ? (remote, []) : (nil, ["issue"])
    }
    let keys = Set(baseJSON.keys).union(localJSON.keys).union(remoteJSON.keys)
    let localChanged = Set(keys.filter { canonicalSyncValue(localJSON[$0]) != canonicalSyncValue(baseJSON[$0]) })
    let remoteChanged = Set(keys.filter { canonicalSyncValue(remoteJSON[$0]) != canonicalSyncValue(baseJSON[$0]) })
    let overlap = localChanged.intersection(remoteChanged).filter {
        canonicalSyncValue(localJSON[$0]) != canonicalSyncValue(remoteJSON[$0])
    }.sorted()
    guard overlap.isEmpty else { return (nil, overlap) }

    var mergedJSON = remoteJSON
    for key in localChanged {
        mergedJSON[key] = localJSON[key]
    }
    mergedJSON["revision"] = remote.revision
    mergedJSON["updatedBy"] = remote.updatedBy
    if let updatedAt = remote.updatedAt?.timeIntervalSinceReferenceDate {
        mergedJSON["updatedAt"] = updatedAt
    }
    guard let data = try? JSONSerialization.data(withJSONObject: mergedJSON),
          let merged = try? JSONDecoder().decode(TrackedIssue.self, from: data) else {
        return (nil, ["decode"])
    }
    return (merged, [])
}
