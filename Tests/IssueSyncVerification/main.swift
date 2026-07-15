import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("IssueSyncVerification failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct IssueSyncVerification {
    static func main() throws {
        let legacyJSON = Data(#"{"revision":3,"id":"legacy-web-42","issueNumber":42,"type":"Bug","title":"Legacy ID","dateKey":"2026-07-13","createdAt":"2026-07-13 09:00:00","status":"待处理","source":"Web","comments":[]}"#.utf8)
        let legacy = try JSONDecoder().decode(TrackedIssue.self, from: legacyJSON)
        require(legacy.syncID == "legacy-web-42", "non-UUID remote ID was not preserved")
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        require(reencoded?["id"] as? String == "legacy-web-42", "non-UUID remote ID did not round-trip")

        var base = TrackedIssue(title: "Base title")
        base.revision = 1
        base.assignee = "Alice"

        var local = base
        local.assignee = "Bob"

        var remote = base
        remote.revision = 2
        remote.title = "Remote title"
        remote.updatedAt = Date()

        let disjoint = mergeDisjointIssueChanges(base: base, local: local, remote: remote)
        require(disjoint.1.isEmpty, "disjoint edits were reported as overlapping")
        require(disjoint.0?.title == "Remote title", "remote field was lost during merge")
        require(disjoint.0?.assignee == "Bob", "local field was lost during merge")
        require(disjoint.0?.revision == 2, "remote revision was not retained")

        local.title = "Local title"
        let overlapping = mergeDisjointIssueChanges(base: base, local: local, remote: remote)
        require(overlapping.0 == nil, "overlapping edits were merged silently")
        require(overlapping.1.contains("title"), "overlapping title field was not identified")

        require(SyncPayloadPolicy.supportedSchemaVersion(in: [:]), "legacy sync payload was rejected")
        require(
            !SyncPayloadPolicy.supportedSchemaVersion(in: ["schemaVersion": SyncPayloadPolicy.currentSchemaVersion + 1]),
            "future sync payload was accepted"
        )
        require(
            SyncPayloadPolicy.blocksLargeReduction(
                localRecordBuckets: 415,
                remoteRecordBuckets: 415,
                localSupportTotal: 875,
                remoteSupportTotal: 0,
                localIssues: 225,
                remoteIssues: 0
            ),
            "zeroed support totals with unchanged buckets were not blocked"
        )
        require(
            SyncPayloadPolicy.blocksLargeReduction(
                localRecordBuckets: 0,
                remoteRecordBuckets: 0,
                localSupportTotal: 0,
                remoteSupportTotal: 0,
                localIssues: 0,
                remoteIssues: 0,
                localDepartments: 4,
                remoteDepartments: 0,
                localMembers: 6,
                remoteMembers: 0
            ),
            "zeroed departments and members were not blocked"
        )
        require(
            SyncPayloadPolicy.deviceConfigurationKeys.contains("linearConfig") &&
                !SyncPayloadPolicy.deviceConfigurationKeys.contains("trackedIssues"),
            "device configuration boundary is incorrect"
        )

        print("IssueSyncVerification passed")
    }
}
