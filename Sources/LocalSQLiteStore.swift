import Foundation
import SQLite3

@MainActor
final class LocalSQLiteStore {
    private var db: OpaquePointer?
    private(set) var isReady = false

    init() {
        do {
            let url = try Self.databaseURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard sqlite3_open(url.path, &db) == SQLITE_OK else {
                throw SQLiteStoreError.open(message: lastError)
            }
            execute("PRAGMA journal_mode=WAL;")
            execute("PRAGMA synchronous=NORMAL;")
            createSchema()
            isReady = true
        } catch {
            DevLog.shared.error("SQLite", "初始化失败: \(error.localizedDescription)")
        }
    }

    private static func databaseURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TicTracker/TicTracker.sqlite3")
    }

    private var lastError: String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }

    private func createSchema() {
        execute("""
        CREATE TABLE IF NOT EXISTS support_records(
            date_key TEXT NOT NULL,
            department TEXT NOT NULL,
            count INTEGER NOT NULL,
            PRIMARY KEY(date_key, department)
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS daily_notes(
            date_key TEXT PRIMARY KEY,
            note TEXT NOT NULL
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS tap_timestamps(
            date_key TEXT NOT NULL,
            department TEXT NOT NULL,
            position INTEGER NOT NULL,
            timestamp TEXT NOT NULL,
            PRIMARY KEY(date_key, department, position)
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS tracked_issues(
            id TEXT PRIMARY KEY,
            issue_number INTEGER NOT NULL,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            date_key TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL,
            diary_badge TEXT NOT NULL,
            status TEXT NOT NULL,
            source TEXT NOT NULL,
            assignee TEXT,
            jira_key TEXT,
            ticket_url TEXT,
            department TEXT,
            resolved_at REAL,
            has_dev_activity INTEGER NOT NULL,
            is_escalated INTEGER NOT NULL,
            feishu_task_guid TEXT,
            feishu_task_summary TEXT,
            feishu_task_completed_at TEXT,
            linear_issue_id TEXT,
            linear_key TEXT,
            linear_url TEXT,
            linear_project_id TEXT,
            linear_project_name TEXT,
            linear_assignee TEXT,
            reporter_id TEXT,
            reporter_name TEXT,
            reported_at REAL,
            revision INTEGER NOT NULL DEFAULT 1,
            updated_by TEXT,
            deleted_at TEXT
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS issue_comments(
            issue_id TEXT NOT NULL,
            id TEXT NOT NULL,
            position INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            jira_comment_id TEXT,
            PRIMARY KEY(issue_id, id)
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS issue_values(
            issue_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            position INTEGER NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY(issue_id, kind, position)
        );
        """)
        execute("""
        CREATE TABLE IF NOT EXISTS operation_log(
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            module TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT NOT NULL
        );
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_tracked_issues_date ON tracked_issues(date_key);")
        execute("CREATE INDEX IF NOT EXISTS idx_tracked_issues_status ON tracked_issues(status);")
        execute("CREATE INDEX IF NOT EXISTS idx_issue_comments_lookup ON issue_comments(issue_id, position);")
        execute("CREATE INDEX IF NOT EXISTS idx_issue_values_lookup ON issue_values(issue_id, kind);")
        ensureColumn(table: "tracked_issues", column: "revision", definition: "INTEGER NOT NULL DEFAULT 1")
        ensureColumn(table: "tracked_issues", column: "updated_by", definition: "TEXT")
        ensureColumn(table: "tracked_issues", column: "deleted_at", definition: "TEXT")
    }

    func loadRecords() -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        query("SELECT date_key, department, count FROM support_records") { stmt in
            let key = columnText(stmt, 0)
            let dept = columnText(stmt, 1)
            let count = Int(sqlite3_column_int64(stmt, 2))
            result[key, default: [:]][dept] = count
        }
        return result
    }

    func saveRecords(_ records: [String: [String: Int]]) {
        transaction {
            replaceRecords(records)
        }
    }

    func loadDailyNotes() -> [String: String] {
        var result: [String: String] = [:]
        query("SELECT date_key, note FROM daily_notes") { stmt in
            result[columnText(stmt, 0)] = columnText(stmt, 1)
        }
        return result
    }

    func saveDailyNotes(_ notes: [String: String]) {
        transaction {
            replaceDailyNotes(notes)
        }
    }

    func loadTapTimestamps() -> [String: [String: [String]]] {
        var result: [String: [String: [String]]] = [:]
        query("SELECT date_key, department, timestamp FROM tap_timestamps ORDER BY date_key, department, position") { stmt in
            let key = columnText(stmt, 0)
            let dept = columnText(stmt, 1)
            result[key, default: [:]][dept, default: []].append(columnText(stmt, 2))
        }
        return result
    }

    func saveTapTimestamps(_ timestamps: [String: [String: [String]]]) {
        transaction {
            replaceTapTimestamps(timestamps)
        }
    }

    func loadTrackedIssues() -> [TrackedIssue] {
        var issues: [TrackedIssue] = []
        let commentsByIssue = loadCommentsByIssue()
        let valuesByIssue = loadValuesByIssue()
        query("""
        SELECT id, issue_number, type, title, date_key, created_at, updated_at, diary_badge, status, source,
               assignee, jira_key, ticket_url, department, resolved_at, has_dev_activity, is_escalated,
               feishu_task_guid, feishu_task_summary, feishu_task_completed_at,
               linear_issue_id, linear_key, linear_url, linear_project_id, linear_project_name, linear_assignee,
               reporter_id, reporter_name, reported_at, revision, updated_by, deleted_at
        FROM tracked_issues ORDER BY created_at ASC;
        """) { stmt in
            guard var issue = issue(from: stmt) else { return }
            let issueID = issue.syncID
            let values = valuesByIssue[issueID] ?? [:]
            issue.comments = commentsByIssue[issueID] ?? []
            issue.feishuTasklistGuids = values["feishu_tasklist_guid"] ?? []
            issue.feishuTaskAssigneeIds = values["feishu_task_assignee_id"] ?? []
            issue.followers = values["follower"] ?? []
            issue.issueTags = values["tag"] ?? []
            issue.linearCreator = values["linear_creator"]?.first
            issue.linearCreatedAt = values["linear_created_at"]?.first
            issue.linearUpdatedAt = values["linear_updated_at"]?.first
            issues.append(issue)
        }
        return issues
    }

    func saveTrackedIssues(_ issues: [TrackedIssue]) {
        transaction {
            replaceTrackedIssues(issues)
        }
    }

    /// Move every legacy UserDefaults-backed collection in one transaction.
    /// Callers must not discard the legacy payload unless this returns true.
    @discardableResult
    func saveMigrationSnapshot(
        records: [String: [String: Int]],
        dailyNotes: [String: String],
        tapTimestamps: [String: [String: [String]]],
        trackedIssues: [TrackedIssue],
        operationLog: [OperationLogEntry]
    ) -> Bool {
        let committed = transaction {
            replaceRecords(records)
            replaceDailyNotes(dailyNotes)
            replaceTapTimestamps(tapTimestamps)
            replaceTrackedIssues(trackedIssues)
            replaceOperationLog(operationLog)
        }
        guard committed else { return false }

        // A successful COMMIT is not enough to delete the only legacy copy.
        // Read the durable rows back and verify the complete collection keys.
        let storedIssues = loadTrackedIssues()
        let storedIssueIDs = Set(storedIssues.map(\.syncID))
        let expectedIssueIDs = Set(trackedIssues.map(\.syncID))
        let storedOperations = loadOperationLog()
        let storedOperationIDs = Set(storedOperations.map(\.id))
        let expectedOperationIDs = Set(operationLog.prefix(200).map(\.id))
        return loadRecords() == records
            && loadDailyNotes() == dailyNotes
            && loadTapTimestamps() == tapTimestamps
            && storedIssues.count == trackedIssues.count
            && storedIssueIDs == expectedIssueIDs
            && storedOperations.count == expectedOperationIDs.count
            && storedOperationIDs == expectedOperationIDs
    }

    /// Persist every SQLite-backed workspace collection in one transaction so
    /// a sync import cannot survive a crash as a mixture of old and new data.
    @discardableResult
    func saveSyncSnapshot(
        records: [String: [String: Int]],
        dailyNotes: [String: String],
        tapTimestamps: [String: [String: [String]]],
        trackedIssues: [TrackedIssue]
    ) -> Bool {
        transaction {
            replaceRecords(records)
            replaceDailyNotes(dailyNotes)
            replaceTapTimestamps(tapTimestamps)
            replaceTrackedIssues(trackedIssues)
        }
    }

    func upsertIssue(_ issue: TrackedIssue) {
        transaction {
            saveIssue(issue)
        }
    }

    func deleteIssue(syncID: String) {
        transaction {
            withStatement("DELETE FROM issue_comments WHERE issue_id = ?;") { stmt in
                bindText(stmt, 1, syncID)
                step(stmt)
            }
            withStatement("DELETE FROM issue_values WHERE issue_id = ?;") { stmt in
                bindText(stmt, 1, syncID)
                step(stmt)
            }
            withStatement("DELETE FROM tracked_issues WHERE id = ?;") { stmt in
                bindText(stmt, 1, syncID)
                step(stmt)
            }
        }
    }

    func loadOperationLog() -> [OperationLogEntry] {
        var result: [OperationLogEntry] = []
        query("SELECT id, timestamp, module, action, detail FROM operation_log ORDER BY timestamp DESC LIMIT 200;") { stmt in
            guard let id = UUID(uuidString: columnText(stmt, 0)) else { return }
            result.append(OperationLogEntry(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                module: columnText(stmt, 2),
                action: columnText(stmt, 3),
                detail: columnText(stmt, 4)
            ))
        }
        return result
    }

    func saveOperationLog(_ entries: [OperationLogEntry]) {
        transaction {
            replaceOperationLog(entries)
        }
    }

    private func replaceOperationLog(_ entries: [OperationLogEntry]) {
        execute("DELETE FROM operation_log;")
        withStatement("INSERT OR REPLACE INTO operation_log(id, timestamp, module, action, detail) VALUES(?, ?, ?, ?, ?);") { stmt in
            for entry in entries.prefix(200) {
                sqlite3_reset(stmt)
                bindText(stmt, 1, entry.id.uuidString)
                sqlite3_bind_double(stmt, 2, entry.timestamp.timeIntervalSince1970)
                bindText(stmt, 3, entry.module)
                bindText(stmt, 4, entry.action)
                bindText(stmt, 5, entry.detail)
                step(stmt)
            }
        }
    }

    private func saveIssue(_ issue: TrackedIssue) {
        withStatement("""
        INSERT OR REPLACE INTO tracked_issues(
            id, issue_number, type, title, date_key, created_at, updated_at, diary_badge, status, source,
            assignee, jira_key, ticket_url, department, resolved_at, has_dev_activity, is_escalated,
            feishu_task_guid, feishu_task_summary, feishu_task_completed_at,
            linear_issue_id, linear_key, linear_url, linear_project_id, linear_project_name, linear_assignee,
            reporter_id, reporter_name, reported_at, revision, updated_by, deleted_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { stmt in
            bindText(stmt, 1, issue.syncID)
            sqlite3_bind_int64(stmt, 2, Int64(issue.issueNumber))
            bindText(stmt, 3, issue.type.rawValue)
            bindText(stmt, 4, issue.title)
            bindText(stmt, 5, issue.dateKey)
            sqlite3_bind_double(stmt, 6, issue.createdAt.timeIntervalSince1970)
            bindDate(stmt, 7, issue.updatedAt)
            bindText(stmt, 8, issue.diaryBadge.rawValue)
            bindText(stmt, 9, issue.status.rawValue)
            bindText(stmt, 10, issue.source.rawValue)
            bindOptionalText(stmt, 11, issue.assignee)
            bindOptionalText(stmt, 12, issue.jiraKey)
            bindOptionalText(stmt, 13, issue.ticketURL)
            bindOptionalText(stmt, 14, issue.department)
            bindDate(stmt, 15, issue.resolvedAt)
            sqlite3_bind_int(stmt, 16, issue.hasDevActivity ? 1 : 0)
            sqlite3_bind_int(stmt, 17, issue.isEscalated ? 1 : 0)
            bindOptionalText(stmt, 18, issue.feishuTaskGuid)
            bindOptionalText(stmt, 19, issue.feishuTaskSummary)
            bindOptionalText(stmt, 20, issue.feishuTaskCompletedAt)
            bindOptionalText(stmt, 21, issue.linearIssueId)
            bindOptionalText(stmt, 22, issue.linearKey)
            bindOptionalText(stmt, 23, issue.linearUrl)
            bindOptionalText(stmt, 24, issue.linearProjectId)
            bindOptionalText(stmt, 25, issue.linearProjectName)
            bindOptionalText(stmt, 26, issue.linearAssignee)
            bindOptionalText(stmt, 27, issue.reporterId)
            bindOptionalText(stmt, 28, issue.reporterName)
            bindDate(stmt, 29, issue.reportedAt)
            sqlite3_bind_int64(stmt, 30, max(issue.revision, 1))
            bindOptionalText(stmt, 31, issue.updatedBy)
            bindOptionalText(stmt, 32, issue.deletedAt)
            step(stmt)
        }

        withStatement("DELETE FROM issue_comments WHERE issue_id = ?;") { stmt in
            bindText(stmt, 1, issue.syncID)
            step(stmt)
        }
        withStatement("DELETE FROM issue_values WHERE issue_id = ?;") { stmt in
            bindText(stmt, 1, issue.syncID)
            step(stmt)
        }
        saveComments(issueID: issue.syncID, comments: issue.comments)
        saveValues(issueID: issue.syncID, kind: "feishu_tasklist_guid", values: issue.feishuTasklistGuids)
        saveValues(issueID: issue.syncID, kind: "feishu_task_assignee_id", values: issue.feishuTaskAssigneeIds)
        saveValues(issueID: issue.syncID, kind: "follower", values: issue.followers)
        saveValues(issueID: issue.syncID, kind: "tag", values: issue.issueTags)
        saveValues(issueID: issue.syncID, kind: "linear_creator", values: issue.linearCreator.map { [$0] } ?? [])
        saveValues(issueID: issue.syncID, kind: "linear_created_at", values: issue.linearCreatedAt.map { [$0] } ?? [])
        saveValues(issueID: issue.syncID, kind: "linear_updated_at", values: issue.linearUpdatedAt.map { [$0] } ?? [])
    }

    private func replaceRecords(_ records: [String: [String: Int]]) {
        execute("DELETE FROM support_records;")
        withStatement("INSERT OR REPLACE INTO support_records(date_key, department, count) VALUES(?, ?, ?);") { stmt in
            for (key, day) in records {
                for (dept, count) in day where count != 0 {
                    sqlite3_reset(stmt)
                    bindText(stmt, 1, key)
                    bindText(stmt, 2, dept)
                    sqlite3_bind_int64(stmt, 3, Int64(count))
                    step(stmt)
                }
            }
        }
    }

    private func replaceDailyNotes(_ notes: [String: String]) {
        execute("DELETE FROM daily_notes;")
        withStatement("INSERT OR REPLACE INTO daily_notes(date_key, note) VALUES(?, ?);") { stmt in
            for (key, note) in notes where !note.isEmpty {
                sqlite3_reset(stmt)
                bindText(stmt, 1, key)
                bindText(stmt, 2, note)
                step(stmt)
            }
        }
    }

    private func replaceTapTimestamps(_ timestamps: [String: [String: [String]]]) {
        execute("DELETE FROM tap_timestamps;")
        withStatement("INSERT OR REPLACE INTO tap_timestamps(date_key, department, position, timestamp) VALUES(?, ?, ?, ?);") { stmt in
            for (key, day) in timestamps {
                for (dept, values) in day {
                    for (index, value) in values.enumerated() {
                        sqlite3_reset(stmt)
                        bindText(stmt, 1, key)
                        bindText(stmt, 2, dept)
                        sqlite3_bind_int64(stmt, 3, Int64(index))
                        bindText(stmt, 4, value)
                        step(stmt)
                    }
                }
            }
        }
    }

    private func replaceTrackedIssues(_ issues: [TrackedIssue]) {
        execute("DELETE FROM issue_comments;")
        execute("DELETE FROM issue_values;")
        execute("DELETE FROM tracked_issues;")
        for issue in issues {
            saveIssue(issue)
        }
    }

    private func issue(from stmt: OpaquePointer?) -> TrackedIssue? {
        let storedID = columnText(stmt, 0)
        let id = UUID(uuidString: storedID) ?? stableLocalUUID(for: storedID)
        var issue = TrackedIssue(title: columnText(stmt, 3), type: IssueType(rawValue: columnText(stmt, 2)) ?? .bug)
        issue.id = id
        issue.remoteID = UUID(uuidString: storedID) == nil ? storedID : nil
        issue.issueNumber = Int(sqlite3_column_int64(stmt, 1))
        issue.dateKey = columnText(stmt, 4)
        issue.createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        issue.updatedAt = columnDate(stmt, 6)
        issue.diaryBadge = DiaryBadge(rawValue: columnText(stmt, 7)) ?? .auto
        issue.status = IssueStatus(rawValue: columnText(stmt, 8)) ?? .pending
        issue.source = IssueSource(rawValue: columnText(stmt, 9)) ?? .manual
        issue.assignee = columnOptionalText(stmt, 10)
        issue.jiraKey = columnOptionalText(stmt, 11)
        issue.ticketURL = columnOptionalText(stmt, 12)
        issue.department = columnOptionalText(stmt, 13)
        issue.resolvedAt = columnDate(stmt, 14)
        issue.hasDevActivity = sqlite3_column_int(stmt, 15) != 0
        issue.isEscalated = sqlite3_column_int(stmt, 16) != 0
        issue.feishuTaskGuid = columnOptionalText(stmt, 17)
        issue.feishuTaskSummary = columnOptionalText(stmt, 18)
        issue.feishuTaskCompletedAt = columnOptionalText(stmt, 19)
        issue.linearIssueId = columnOptionalText(stmt, 20)
        issue.linearKey = columnOptionalText(stmt, 21)
        issue.linearUrl = columnOptionalText(stmt, 22)
        issue.linearProjectId = columnOptionalText(stmt, 23)
        issue.linearProjectName = columnOptionalText(stmt, 24)
        issue.linearAssignee = columnOptionalText(stmt, 25)
        issue.reporterId = columnOptionalText(stmt, 26)
        issue.reporterName = columnOptionalText(stmt, 27)
        issue.reportedAt = columnDate(stmt, 28)
        issue.revision = max(sqlite3_column_int64(stmt, 29), 1)
        issue.updatedBy = columnOptionalText(stmt, 30)
        issue.deletedAt = columnOptionalText(stmt, 31)
        return issue
    }

    private func loadCommentsByIssue() -> [String: [IssueComment]] {
        var result: [String: [IssueComment]] = [:]
        query("SELECT issue_id, id, text, created_at, jira_comment_id FROM issue_comments ORDER BY issue_id, position ASC;") { stmt in
            let issueID = columnText(stmt, 0)
            let storedID = columnText(stmt, 1)
            let id = UUID(uuidString: storedID) ?? stableLocalUUID(for: storedID)
            result[issueID, default: []].append(IssueComment(
                id: id,
                remoteID: UUID(uuidString: storedID) == nil ? storedID : nil,
                text: columnText(stmt, 2),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                jiraCommentId: columnOptionalText(stmt, 4)
            ))
        }
        return result
    }

    private func saveComments(issueID: String, comments: [IssueComment]) {
        withStatement("INSERT OR REPLACE INTO issue_comments(issue_id, id, position, text, created_at, jira_comment_id) VALUES(?, ?, ?, ?, ?, ?);") { stmt in
            for (index, comment) in comments.enumerated() {
                sqlite3_reset(stmt)
                bindText(stmt, 1, issueID)
                bindText(stmt, 2, comment.syncID)
                sqlite3_bind_int64(stmt, 3, Int64(index))
                bindText(stmt, 4, comment.text)
                sqlite3_bind_double(stmt, 5, comment.createdAt.timeIntervalSince1970)
                bindOptionalText(stmt, 6, comment.jiraCommentId)
                step(stmt)
            }
        }
    }

    private func loadValuesByIssue() -> [String: [String: [String]]] {
        var result: [String: [String: [String]]] = [:]
        query("SELECT issue_id, kind, value FROM issue_values ORDER BY issue_id, kind, position ASC;") { stmt in
            let issueID = columnText(stmt, 0)
            let kind = columnText(stmt, 1)
            result[issueID, default: [:]][kind, default: []].append(columnText(stmt, 2))
        }
        return result
    }

    private func saveValues(issueID: String, kind: String, values: [String]) {
        withStatement("INSERT OR REPLACE INTO issue_values(issue_id, kind, position, value) VALUES(?, ?, ?, ?);") { stmt in
            for (index, value) in values.enumerated() {
                sqlite3_reset(stmt)
                bindText(stmt, 1, issueID)
                bindText(stmt, 2, kind)
                sqlite3_bind_int64(stmt, 3, Int64(index))
                bindText(stmt, 4, value)
                step(stmt)
            }
        }
    }

    @discardableResult
    private func transaction(_ block: () -> Void) -> Bool {
        guard db != nil, executeChecked("BEGIN IMMEDIATE TRANSACTION;") else { return false }
        transactionFailed = false
        transactionActive = true
        block()
        transactionActive = false
        guard !transactionFailed else {
            _ = executeChecked("ROLLBACK;")
            return false
        }
        if executeChecked("COMMIT;") {
            return true
        }
        _ = executeChecked("ROLLBACK;")
        return false
    }

    private func ensureColumn(table: String, column: String, definition: String) {
        var exists = false
        query("PRAGMA table_info(\(table));") { stmt in
            if columnText(stmt, 1) == column { exists = true }
        }
        if !exists {
            execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
        }
    }

    private func query(_ sql: String, row: (OpaquePointer?) -> Void) {
        withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                row(stmt)
            }
        }
    }

    private var transactionActive = false
    private var transactionFailed = false

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            DevLog.shared.error("SQLite", "prepare failed: \(lastError)")
            if transactionActive { transactionFailed = true }
            return
        }
        defer { sqlite3_finalize(stmt) }
        body(stmt)
    }

    private func execute(_ sql: String) {
        _ = executeChecked(sql)
    }

    @discardableResult
    private func executeChecked(_ sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastError
            DevLog.shared.error("SQLite", "exec failed: \(message)")
            sqlite3_free(error)
            if transactionActive { transactionFailed = true }
            return false
        }
        return true
    }

    private func step(_ stmt: OpaquePointer?) {
        if sqlite3_step(stmt) != SQLITE_DONE {
            DevLog.shared.error("SQLite", "step failed: \(lastError)")
            if transactionActive { transactionFailed = true }
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(stmt, index)
            return
        }
        bindText(stmt, index, value)
    }

    private func bindDate(_ stmt: OpaquePointer?, _ index: Int32, _ value: Date?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        sqlite3_bind_double(stmt, index, value.timeIntervalSince1970)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: value)
    }

    private func columnOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let value = columnText(stmt, index)
        return value.isEmpty ? nil : value
    }

    private func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }
}

private enum SQLiteStoreError: LocalizedError {
    case open(message: String)

    var errorDescription: String? {
        switch self {
        case .open(let message):
            "无法打开数据库: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
