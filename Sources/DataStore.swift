import Foundation

@MainActor
@Observable
final class DataStore {
    var departments: [String] {
        didSet { saveDepartments() }
    }
    var records: [String: [String: Int]] {
        didSet { saveRecords() }
    }
    var dailyNotes: [String: String] {
        didSet { saveDailyNotes() }
    }
    var popoverTitle: String {
        didSet { UserDefaults.standard.set(popoverTitle, forKey: "popoverTitle") }
    }
    var noteTitle: String {
        didSet { UserDefaults.standard.set(noteTitle, forKey: "noteTitle") }
    }
    var hotkeyBindings: [String: HotkeyBinding] {
        didSet {
            saveHotkeyBindings()
            HotkeyManager.shared.rebindHotkeys()
        }
    }

    // MARK: - Jira

    var jiraConfig: JiraConfig {
        didSet { saveJiraConfig() }
    }
    var jiraIssues: [JiraIssue] {
        didSet { saveJiraIssues() }
    }
    var reportedJiraIssues: [JiraIssue] {
        didSet { saveReportedJiraIssues() }
    }
    /// Jira issues filtered by jiraSourceMode: 0=assigned, 1=reported, 2=all
    var filteredJiraIssues: [JiraIssue] {
        switch jiraSourceMode {
        case 0: return jiraIssues
        case 1: return reportedJiraIssues
        default:
            var seen = Set<String>()
            var result: [JiraIssue] = []
            for issue in jiraIssues + reportedJiraIssues {
                if seen.insert(issue.key).inserted { result.append(issue) }
            }
            return result
        }
    }

    var jiraIssueCounts: [String: [String: Int]] {  // dateKey → issueKey → count
        didSet { saveJiraIssueCounts() }
    }
    var jiraTransitionLog: [String: [String]] {  // dateKey → [issueKey] (已流转，每天每工单只计一次)
        didSet { saveJiraTransitionLog() }
    }

    // MARK: - RSS

    var rssFeeds: [RSSFeed] {
        didSet { saveRSSFeeds() }
    }
    var rssItems: [String: [RSSItem]] {  // feedID.uuidString -> items
        didSet { saveRSSItems() }
    }
    var rssPollingInterval: Int {  // minutes, default 10
        didSet { UserDefaults.standard.set(rssPollingInterval, forKey: "rssPollingInterval") }
    }

    // MARK: - Todo Tasks

    var todoTasks: [TodoTask] {
        didSet { saveTodoTasks() }
    }

    // MARK: - Bug Entries

    var trackedIssues: [TrackedIssue] {
        didSet { saveTrackedIssues() }
    }
    var bugTeamMembers: [String] {
        didSet { saveBugTeamMembers() }
    }

    // MARK: - Operation Log

    var operationLog: [OperationLogEntry] = [] {
        didSet { saveOperationLog() }
    }

    // MARK: - Tap Timestamps

    var tapTimestamps: [String: [String: [String]]] {  // dateKey → dept → ["HH:mm:ss", ...]
        didSet { saveTapTimestamps() }
    }

    // MARK: - Feature Toggles

    var dailyNoteEnabled: Bool {
        didSet { UserDefaults.standard.set(dailyNoteEnabled, forKey: "dailyNoteEnabled") }
    }
    var trendChartEnabled: Bool {
        didSet { UserDefaults.standard.set(trendChartEnabled, forKey: "trendChartEnabled") }
    }
    var timestampEnabled: Bool {
        didSet { UserDefaults.standard.set(timestampEnabled, forKey: "timestampEnabled") }
    }
    var hotkeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled")
            if hotkeyEnabled {
                HotkeyManager.shared.rebindHotkeys()
            } else {
                HotkeyManager.shared.unregisterAll()
            }
        }
    }
    var todoEnabled: Bool {
        didSet { UserDefaults.standard.set(todoEnabled, forKey: "todoEnabled") }
    }
    var issueTrackerEnabled: Bool {
        didSet { UserDefaults.standard.set(issueTrackerEnabled, forKey: "issueTrackerEnabled") }
    }
    var diaryShowAllPending: Bool {
        didSet { UserDefaults.standard.set(diaryShowAllPending, forKey: "diaryShowAllPending") }
    }
    var jiraSourceMode: Int {
        didSet { UserDefaults.standard.set(jiraSourceMode, forKey: "jiraSourceMode") }
    }  // 0=assigned, 1=reported, 2=all
    var rssEnabled: Bool {
        didSet {
            UserDefaults.standard.set(rssEnabled, forKey: "rssEnabled")
            if rssEnabled {
                RSSFeedManager.shared.startPolling()
            } else {
                RSSFeedManager.shared.stopPolling()
            }
        }
    }

    // MARK: - AI

    var aiConfig: AIConfig {
        didSet { saveAIConfig() }
    }
    var aiEnabled: Bool {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled") }
    }

    private let departmentsKey = "departments"
    private let recordsKey = "records"
    private let dailyNotesKey = "dailyNotes"

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private static let weekdayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    static func dateKey(from date: Date) -> String {
        dateFormatter.string(from: date)
    }

    init() {
        if let data = UserDefaults.standard.array(forKey: departmentsKey) as? [String] {
            departments = data
        } else {
            departments = ["研发部", "产品部", "设计部", "运营部"]
        }
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
        if let data = UserDefaults.standard.data(forKey: dailyNotesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            dailyNotes = decoded
        } else {
            dailyNotes = [:]
        }
        popoverTitle = UserDefaults.standard.string(forKey: "popoverTitle") ?? "今日技术支持"
        noteTitle = UserDefaults.standard.string(forKey: "noteTitle") ?? "今日小记"

        // Initialize hotkeyBindings (migration happens after all stored properties are set)
        if let data = UserDefaults.standard.data(forKey: "hotkeyBindings"),
           let decoded = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) {
            hotkeyBindings = decoded
        } else {
            hotkeyBindings = [:]
        }

        // Jira
        if let data = UserDefaults.standard.data(forKey: "jiraConfig"),
           let decoded = try? JSONDecoder().decode(JiraConfig.self, from: data) {
            jiraConfig = decoded
        } else {
            jiraConfig = JiraConfig()
        }
        if let data = UserDefaults.standard.data(forKey: "jiraIssues"),
           let decoded = try? JSONDecoder().decode([JiraIssue].self, from: data) {
            jiraIssues = decoded
        } else {
            jiraIssues = []
        }
        if let data = UserDefaults.standard.data(forKey: "reportedJiraIssues"),
           let decoded = try? JSONDecoder().decode([JiraIssue].self, from: data) {
            reportedJiraIssues = decoded
        } else {
            reportedJiraIssues = []
        }
        if let data = UserDefaults.standard.data(forKey: "jiraIssueCounts"),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            jiraIssueCounts = decoded
        } else {
            jiraIssueCounts = [:]
        }
        if let data = UserDefaults.standard.data(forKey: "jiraTransitionLog"),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            jiraTransitionLog = decoded
        } else {
            jiraTransitionLog = [:]
        }

        // RSS
        if let data = UserDefaults.standard.data(forKey: "rssFeeds"),
           let decoded = try? JSONDecoder().decode([RSSFeed].self, from: data) {
            rssFeeds = decoded
        } else {
            rssFeeds = []
        }
        if let data = UserDefaults.standard.data(forKey: "rssItems"),
           let decoded = try? JSONDecoder().decode([String: [RSSItem]].self, from: data) {
            rssItems = decoded
        } else {
            rssItems = [:]
        }
        rssPollingInterval = UserDefaults.standard.object(forKey: "rssPollingInterval") as? Int ?? 10

        // Todo tasks
        if let data = UserDefaults.standard.data(forKey: "todoTasks"),
           let decoded = try? JSONDecoder().decode([TodoTask].self, from: data) {
            todoTasks = decoded
        } else {
            todoTasks = []
        }

        // Tracked issues (unified: bug + hotfix + issue)
        if let data = UserDefaults.standard.data(forKey: "trackedIssues"),
           let decoded = try? JSONDecoder().decode([TrackedIssue].self, from: data) {
            trackedIssues = decoded
        } else {
            // Migrate from legacy separate arrays
            var migrated: [TrackedIssue] = []
            if let bugData = UserDefaults.standard.data(forKey: "bugEntries"),
               let bugs = try? JSONDecoder().decode([TrackedIssue].self, from: bugData) {
                migrated += bugs  // TrackedIssue decoder handles BugEntry format
            }
            if let issueData = UserDefaults.standard.data(forKey: "projectIssues"),
               let issues = try? JSONDecoder().decode([TrackedIssue].self, from: issueData) {
                migrated += issues  // TrackedIssue decoder handles ProjectIssue format
            }
            trackedIssues = migrated
            // Can't call saveTrackedIssues() here as init isn't complete yet
            // Save directly to UserDefaults
            if !migrated.isEmpty,
               let data = try? JSONEncoder().encode(migrated) {
                UserDefaults.standard.set(data, forKey: "trackedIssues")
            }
        }
        if let data = UserDefaults.standard.array(forKey: "bugTeamMembers") as? [String] {
            bugTeamMembers = data
        } else {
            bugTeamMembers = []
        }

        // Tap timestamps
        if let data = UserDefaults.standard.data(forKey: "tapTimestamps"),
           let decoded = try? JSONDecoder().decode([String: [String: [String]]].self, from: data) {
            tapTimestamps = decoded
        } else {
            tapTimestamps = [:]
        }

        // Feature toggles (default: all enabled)
        dailyNoteEnabled = UserDefaults.standard.object(forKey: "dailyNoteEnabled") as? Bool ?? true
        trendChartEnabled = UserDefaults.standard.object(forKey: "trendChartEnabled") as? Bool ?? true
        timestampEnabled = UserDefaults.standard.object(forKey: "timestampEnabled") as? Bool ?? true
        hotkeyEnabled = UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true
        rssEnabled = UserDefaults.standard.object(forKey: "rssEnabled") as? Bool ?? true
        todoEnabled = UserDefaults.standard.object(forKey: "todoEnabled") as? Bool ?? true
        diaryShowAllPending = UserDefaults.standard.object(forKey: "diaryShowAllPending") as? Bool ?? true
        // Load operation log
        if let data = UserDefaults.standard.data(forKey: "operationLog"),
           let decoded = try? JSONDecoder().decode([OperationLogEntry].self, from: data) {
            operationLog = decoded
        } else {
            operationLog = []
        }
        // Migrate: if either old toggle was on, enable unified tracker
        if let existing = UserDefaults.standard.object(forKey: "issueTrackerEnabled") as? Bool {
            issueTrackerEnabled = existing
        } else {
            let bugOn = UserDefaults.standard.object(forKey: "bugModeEnabled") as? Bool ?? true
            let issueOn = UserDefaults.standard.object(forKey: "projectIssueEnabled") as? Bool ?? true
            let unified = bugOn || issueOn
            issueTrackerEnabled = unified
            UserDefaults.standard.set(unified, forKey: "issueTrackerEnabled")
        }
        jiraSourceMode = UserDefaults.standard.object(forKey: "jiraSourceMode") as? Int ?? 2 // default: all

        // AI
        if let data = UserDefaults.standard.data(forKey: "aiConfig"),
           let decoded = try? JSONDecoder().decode(AIConfig.self, from: data) {
            aiConfig = decoded
        } else {
            aiConfig = AIConfig()
        }
        aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? false

        // Restore base URL / model from Keychain (survives reinstall)
        let stored = AIService.shared.loadAll()
        if !stored.baseURL.isEmpty { aiConfig.baseURL = stored.baseURL }
        if !stored.model.isEmpty { aiConfig.model = stored.model }

        // Migrate legacy hotkeyModifier → per-project bindings
        if hotkeyBindings.isEmpty, UserDefaults.standard.string(forKey: "hotkeyModifier") != nil {
            let legacyMod = UserDefaults.standard.string(forKey: "hotkeyModifier") ?? "ctrl_shift"
            let legacyFlags: UInt32 = {
                let map: [String: UInt32] = [
                    "ctrl_shift": 0x1000 | 0x0200,
                    "cmd_shift":  0x0100 | 0x0200,
                    "opt_shift":  0x0800 | 0x0200,
                    "ctrl_opt":   0x1000 | 0x0800,
                    "cmd_ctrl":   0x0100 | 0x1000,
                ]
                return map[legacyMod] ?? (0x1000 | 0x0200)
            }()
            let keyCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
            var migrated: [String: HotkeyBinding] = [:]
            for (i, dept) in departments.prefix(9).enumerated() {
                migrated[dept] = HotkeyBinding(keyCode: keyCodes[i], carbonModifiers: legacyFlags)
            }
            hotkeyBindings = migrated
        }
    }

    // MARK: - Today

    var todayKey: String {
        Self.dateFormatter.string(from: Date())
    }

    var todayNote: String {
        dailyNotes[todayKey] ?? ""
    }

    func setTodayNote(_ text: String) {
        dailyNotes[todayKey] = text.isEmpty ? nil : text
    }

    var todayRecords: [String: Int] {
        records[todayKey] ?? [:]
    }

    var todayTotal: Int {
        todayRecords.values.reduce(0, +)
    }

    func increment(_ dept: String) {
        incrementForKey(todayKey, dept: dept)
    }

    func decrement(_ dept: String) {
        decrementForKey(todayKey, dept: dept)
    }

    // MARK: - By Date Key

    func recordsForKey(_ key: String) -> [String: Int] {
        records[key] ?? [:]
    }

    func totalForKey(_ key: String) -> Int {
        recordsForKey(key).values.reduce(0, +)
    }

    func incrementForKey(_ key: String, dept: String) {
        var day = records[key] ?? [:]
        day[dept, default: 0] += 1
        records[key] = day
        logOperation(module: "计数", action: "+1", detail: "\(dept) [\(key)]")

        // Record timestamp
        if timestampEnabled {
            var dayTaps = tapTimestamps[key] ?? [:]
            var deptTaps = dayTaps[dept] ?? []
            deptTaps.append(Self.timeFormatter.string(from: Date()))
            dayTaps[dept] = deptTaps
            tapTimestamps[key] = dayTaps
        }
    }

    func decrementForKey(_ key: String, dept: String) {
        var day = records[key] ?? [:]
        let current = day[dept, default: 0]
        guard current > 0 else { return }
        day[dept] = current - 1
        records[key] = day
        logOperation(module: "计数", action: "-1", detail: "\(dept) [\(key)]")

        // Remove last timestamp
        var dayTaps = tapTimestamps[key] ?? [:]
        if var deptTaps = dayTaps[dept], !deptTaps.isEmpty {
            deptTaps.removeLast()
            dayTaps[dept] = deptTaps.isEmpty ? nil : deptTaps
            tapTimestamps[key] = dayTaps.isEmpty ? nil : dayTaps
        }
    }

    func noteForKey(_ key: String) -> String {
        dailyNotes[key] ?? ""
    }

    func setNoteForKey(_ key: String, text: String) {
        dailyNotes[key] = text.isEmpty ? nil : text
    }

    // MARK: - Weekly Trend

    var past7DaysBreakdown: [(date: String, weekday: String, breakdown: [(dept: String, count: Int)])] {
        let calendar = Calendar.current
        return (0..<7).reversed().map { daysAgo in
            let d = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
            let key = Self.dateFormatter.string(from: d)
            let dayRecords = records[key] ?? [:]
            let breakdown = departments.compactMap { dept -> (dept: String, count: Int)? in
                let count = dayRecords[dept, default: 0]
                return count > 0 ? (dept, count) : nil
            }
            return (key, Self.weekdayFormatter.string(from: d), breakdown)
        }
    }

    var currentStreak: Int {
        let calendar = Calendar.current
        let fmt = Self.dateFormatter
        var streak = 0
        for daysAgo in 0..<365 {
            let d = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
            let key = fmt.string(from: d)
            let dayTotal = records[key]?.values.reduce(0, +) ?? 0
            let hasData = dayTotal > 0 || (dailyNotes[key].map { !$0.isEmpty } ?? false)
            if hasData {
                streak += 1
            } else if daysAgo == 0 {
                continue // 今天还没记也没关系
            } else {
                break
            }
        }
        return streak
    }

    // MARK: - Jira Counts

    func jiraIncrementForKey(_ dateKey: String, issueKey: String) {
        var day = jiraIssueCounts[dateKey] ?? [:]
        day[issueKey, default: 0] += 1
        jiraIssueCounts[dateKey] = day
        if let issue = jiraIssues.first(where: { $0.key == issueKey }),
           let dept = jiraConfig.matchedDepartment(for: issue) {
            incrementForKey(dateKey, dept: dept)
        }
    }

    func jiraDecrementForKey(_ dateKey: String, issueKey: String) {
        var day = jiraIssueCounts[dateKey] ?? [:]
        let current = day[issueKey, default: 0]
        guard current > 0 else { return }
        day[issueKey] = current - 1
        jiraIssueCounts[dateKey] = day
        if let issue = jiraIssues.first(where: { $0.key == issueKey }),
           let dept = jiraConfig.matchedDepartment(for: issue) {
            decrementForKey(dateKey, dept: dept)
        }
    }

    /// 流转成功后调用，每天每工单只计一次到关联项目
    func jiraTransitioned(_ dateKey: String, issueKey: String) {
        var log = jiraTransitionLog[dateKey] ?? []
        guard !log.contains(issueKey) else { return }
        log.append(issueKey)
        jiraTransitionLog[dateKey] = log
        // 关联到项目 +1
        if let issue = jiraIssues.first(where: { $0.key == issueKey }),
           let dept = jiraConfig.matchedDepartment(for: issue) {
            incrementForKey(dateKey, dept: dept)
        }
    }

    func jiraTodayCount(issueKey: String) -> Int {
        jiraIssueCounts[todayKey]?[issueKey] ?? 0
    }

    func jiraTotalCount(issueKey: String) -> Int {
        jiraIssueCounts.values.compactMap { $0[issueKey] }.reduce(0, +)
    }

    // MARK: - RSS Item Actions

    func toggleRSSItemRead(feedID: UUID, itemID: String) {
        guard var items = rssItems[feedID.uuidString],
              let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].isRead.toggle()
        rssItems[feedID.uuidString] = items
    }

    func toggleRSSItemFavorite(feedID: UUID, itemID: String) {
        guard var items = rssItems[feedID.uuidString],
              let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].isFavorite.toggle()
        rssItems[feedID.uuidString] = items
    }

    func markAllRSSItemsRead(feedID: UUID) {
        guard var items = rssItems[feedID.uuidString] else { return }
        for i in items.indices {
            items[i].isRead = true
        }
        rssItems[feedID.uuidString] = items
    }

    // MARK: - Departments

    func addDepartment(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !departments.contains(trimmed) else { return }
        departments.append(trimmed)
    }

    func renameDepartment(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !departments.contains(trimmed),
              let idx = departments.firstIndex(of: oldName) else { return }
        departments[idx] = trimmed
        // Migrate historical records
        for key in records.keys {
            if let count = records[key]?[oldName] {
                records[key]?[trimmed] = count
                records[key]?.removeValue(forKey: oldName)
            }
        }
        // Migrate tap timestamps
        for key in tapTimestamps.keys {
            if let taps = tapTimestamps[key]?[oldName] {
                tapTimestamps[key]?[trimmed] = taps
                tapTimestamps[key]?.removeValue(forKey: oldName)
            }
        }
        // Migrate hotkey binding
        if let binding = hotkeyBindings[oldName] {
            hotkeyBindings[trimmed] = binding
            hotkeyBindings.removeValue(forKey: oldName)
        }
    }

    func totalCountForDepartment(_ dept: String) -> Int {
        records.values.compactMap { $0[dept] }.reduce(0, +)
    }

    // MARK: - Data Management

    func clearToday() {
        logOperation(module: "系统", action: "清除", detail: "今日数据 [\(todayKey)]")
        records.removeValue(forKey: todayKey)
        dailyNotes.removeValue(forKey: todayKey)
        tapTimestamps.removeValue(forKey: todayKey)
        trackedIssues.removeAll { $0.dateKey == todayKey }
    }

    func clearAllHistory() {
        logOperation(module: "系统", action: "清除", detail: "全部历史数据")
        records = [:]
        dailyNotes = [:]
        tapTimestamps = [:]
        jiraTransitionLog = [:]
        trackedIssues = []
    }

    var totalDaysTracked: Int {
        Set(records.keys).union(dailyNotes.keys).union(Set(trackedIssues.map(\.dateKey))).count
    }

    var totalSupportCount: Int {
        records.values.flatMap(\.values).reduce(0, +)
    }

    func exportJSON() -> String? {
        var payload: [String: Any] = [
            "departments": departments,
            "records": records,
            "dailyNotes": dailyNotes
        ]
        if !tapTimestamps.isEmpty {
            payload["tapTimestamps"] = tapTimestamps
        }
        if !trackedIssues.isEmpty,
           let issueData = try? JSONEncoder().encode(trackedIssues),
           let issueArray = try? JSONSerialization.jsonObject(with: issueData) {
            payload["trackedIssues"] = issueArray
        }
        if !bugTeamMembers.isEmpty {
            payload["bugTeamMembers"] = bugTeamMembers
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportCSV() -> String {
        let allDates = Set(records.keys).union(dailyNotes.keys).sorted().reversed()
        var lines: [String] = []
        let header = (["日期"] + departments + ["合计", "日报"]).map { escapeCSV($0) }
        lines.append(header.joined(separator: ","))
        for date in allDates {
            let dayRecords = records[date] ?? [:]
            let counts = departments.map { String(dayRecords[$0, default: 0]) }
            let total = String(dayRecords.values.reduce(0, +))
            let note = dailyNotes[date] ?? ""
            let row = [date] + counts + [total, escapeCSV(note)]
            lines.append(row.joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\n")
    }

    private func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    func importJSON(from jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let depts = obj["departments"] as? [String] {
            departments = depts
        }
        if let recs = obj["records"] as? [String: [String: Int]] {
            records = recs
        }
        if let notes = obj["dailyNotes"] as? [String: String] {
            dailyNotes = notes
        }
        if let taps = obj["tapTimestamps"] as? [String: [String: [String]]] {
            tapTimestamps = taps
        }
        // Import tracked issues (new unified format, or migrate from legacy)
        if let issueArray = obj["trackedIssues"],
           let issueData = try? JSONSerialization.data(withJSONObject: issueArray),
           let decoded = try? JSONDecoder().decode([TrackedIssue].self, from: issueData) {
            trackedIssues = decoded
        } else {
            // Fallback: import from legacy separate arrays
            var migrated: [TrackedIssue] = []
            if let bugArray = obj["bugEntries"],
               let bugData = try? JSONSerialization.data(withJSONObject: bugArray),
               let bugs = try? JSONDecoder().decode([TrackedIssue].self, from: bugData) {
                migrated += bugs
            }
            if let issueArray = obj["projectIssues"],
               let issueData = try? JSONSerialization.data(withJSONObject: issueArray),
               let issues = try? JSONDecoder().decode([TrackedIssue].self, from: issueData) {
                migrated += issues
            }
            if !migrated.isEmpty { trackedIssues = migrated }
        }
        if let members = obj["bugTeamMembers"] as? [String] {
            bugTeamMembers = members
        }
        return true
    }

    // MARK: - Persistence

    private func saveDepartments() {
        UserDefaults.standard.set(departments, forKey: departmentsKey)
    }

    private func saveRecords() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    private func saveDailyNotes() {
        if let data = try? JSONEncoder().encode(dailyNotes) {
            UserDefaults.standard.set(data, forKey: dailyNotesKey)
        }
    }

    private func saveHotkeyBindings() {
        if let data = try? JSONEncoder().encode(hotkeyBindings) {
            UserDefaults.standard.set(data, forKey: "hotkeyBindings")
        }
    }

    private func saveJiraConfig() {
        if let data = try? JSONEncoder().encode(jiraConfig) {
            UserDefaults.standard.set(data, forKey: "jiraConfig")
        }
    }

    private func saveJiraIssues() {
        if let data = try? JSONEncoder().encode(jiraIssues) {
            UserDefaults.standard.set(data, forKey: "jiraIssues")
        }
    }

    private func saveReportedJiraIssues() {
        if let data = try? JSONEncoder().encode(reportedJiraIssues) {
            UserDefaults.standard.set(data, forKey: "reportedJiraIssues")
        }
    }

    private func saveJiraIssueCounts() {
        if let data = try? JSONEncoder().encode(jiraIssueCounts) {
            UserDefaults.standard.set(data, forKey: "jiraIssueCounts")
        }
    }

    private func saveJiraTransitionLog() {
        if let data = try? JSONEncoder().encode(jiraTransitionLog) {
            UserDefaults.standard.set(data, forKey: "jiraTransitionLog")
        }
    }

    private func saveRSSFeeds() {
        if let data = try? JSONEncoder().encode(rssFeeds) {
            UserDefaults.standard.set(data, forKey: "rssFeeds")
        }
    }

    private func saveRSSItems() {
        if let data = try? JSONEncoder().encode(rssItems) {
            UserDefaults.standard.set(data, forKey: "rssItems")
        }
    }

    private func saveTapTimestamps() {
        if let data = try? JSONEncoder().encode(tapTimestamps) {
            UserDefaults.standard.set(data, forKey: "tapTimestamps")
        }
    }

    private func saveAIConfig() {
        if let data = try? JSONEncoder().encode(aiConfig) {
            UserDefaults.standard.set(data, forKey: "aiConfig")
        }
    }

    private func saveTodoTasks() {
        if let data = try? JSONEncoder().encode(todoTasks) {
            UserDefaults.standard.set(data, forKey: "todoTasks")
        }
    }

    private func saveTrackedIssues() {
        if let data = try? JSONEncoder().encode(trackedIssues) {
            UserDefaults.standard.set(data, forKey: "trackedIssues")
        }
    }

    private func saveBugTeamMembers() {
        UserDefaults.standard.set(bugTeamMembers, forKey: "bugTeamMembers")
    }

    private func saveOperationLog() {
        if let data = try? JSONEncoder().encode(operationLog) {
            UserDefaults.standard.set(data, forKey: "operationLog")
        }
    }

    func logOperation(module: String, action: String, detail: String) {
        let entry = OperationLogEntry(module: module, action: action, detail: detail)
        operationLog.insert(entry, at: 0)
        if operationLog.count > 200 {
            operationLog = Array(operationLog.prefix(200))
        }
        // Check if we need an auto snapshot (every 30 minutes)
        SnapshotManager.shared.autoSnapshotIfNeeded(store: self)
    }

    func clearOperationLog() {
        operationLog = []
    }

    func deleteOperationLogEntry(id: UUID) {
        operationLog.removeAll { $0.id == id }
    }

    // MARK: - Todo Task Helpers

    func tasksForKey(_ key: String) -> [TodoTask] {
        todoTasks.filter { $0.dateKey == key }
    }

    func allTasksForDate(_ date: Date) -> [TodoTask] {
        let key = Self.dateKey(from: date)
        let byDateKey = todoTasks.filter { $0.dateKey == key }
        let byDueDate = todoTasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            return Calendar.current.isDate(dueDate, inSameDayAs: date) && task.dateKey != key
        }
        return byDateKey + byDueDate
    }

    func addTask(_ task: TodoTask, forKey key: String) {
        var newTask = task
        newTask.dateKey = key
        todoTasks.append(newTask)
        logOperation(module: "任务", action: "新增", detail: task.title)
    }

    func updateTask(_ task: TodoTask, forKey key: String) {
        if let index = todoTasks.firstIndex(where: { $0.id == task.id }) {
            todoTasks[index] = task
        }
    }

    func deleteTask(id: UUID, forKey key: String) {
        if let task = todoTasks.first(where: { $0.id == id }) {
            logOperation(module: "任务", action: "删除", detail: task.title)
        }
        todoTasks.removeAll { $0.id == id }
    }

    var todayTasks: [TodoTask] {
        allTasksForDate(Date())
    }

    var incompleteTodayTasksCount: Int {
        todayTasks.filter { !$0.isCompleted }.count
    }

    // MARK: - Tracked Issue Helpers

    func issuesForKey(_ key: String) -> [TrackedIssue] {
        trackedIssues.filter { $0.dateKey == key }
    }

    /// Issues that have activity on a given date (created or commented that day)
    func issuesActiveForKey(_ key: String) -> [TrackedIssue] {
        trackedIssues.filter { issue in
            if issue.dateKey == key { return true }
            return issue.comments.contains { Self.dateKey(from: $0.createdAt) == key }
        }
    }

    /// 当天创建/有活动的问题 + 更早的仍未解决问题（不重复）
    func issuesVisibleForKey(_ key: String) -> [TrackedIssue] {
        let active = issuesActiveForKey(key)
        let activeIDs = Set(active.map(\.id))
        let carryOver = trackedIssues.filter {
            !activeIDs.contains($0.id) && $0.dateKey < key && !$0.status.isResolved
        }
        return active + carryOver
    }

    var unresolvedIssueCount: Int {
        issuesVisibleForKey(todayKey).filter { !$0.status.isResolved }.count
    }

    func addIssue(_ title: String, type: IssueType, forKey key: String,
                  assignee: String? = nil, jiraKey: String? = nil,
                  department: String? = nil) {
        var entry = TrackedIssue(title: title, type: type)
        entry.dateKey = key
        entry.assignee = assignee
        entry.jiraKey = jiraKey
        entry.department = department
        trackedIssues.append(entry)
        logOperation(module: "问题", action: "新增", detail: "[\(type.rawValue)] \(title)")
    }

    private func touchIssue(at idx: Int) {
        trackedIssues[idx].updatedAt = Date()
        if trackedIssues[idx].diaryBadge != .auto {
            trackedIssues[idx].diaryBadge = .auto
        }
    }

    func updateIssueStatus(id: UUID, status: IssueStatus) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        let title = trackedIssues[idx].title
        let oldStatus = trackedIssues[idx].status.rawValue
        trackedIssues[idx].status = status
        trackedIssues[idx].resolvedAt = status.isResolved ? Date() : nil
        touchIssue(at: idx)
        logOperation(module: "问题", action: "状态", detail: "\(title): \(oldStatus)→\(status.rawValue)")
    }

    func updateIssueAssignee(id: UUID, assignee: String?) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].assignee = assignee
        touchIssue(at: idx)
    }

    func addIssueComment(id: UUID, text: String) {
        guard !text.isEmpty, let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].comments.append(IssueComment(text: text))
        touchIssue(at: idx)
    }

    /// Add a pre-built IssueComment (used by Jira comment sync with custom createdAt / jiraCommentId)
    func addIssueCommentDirect(id: UUID, comment: IssueComment) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].comments.append(comment)
        touchIssue(at: idx)
    }

    func deleteIssueComment(issueID: UUID, commentID: UUID) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == issueID }) else { return }
        trackedIssues[idx].comments.removeAll { $0.id == commentID }
        touchIssue(at: idx)
    }

    func updateIssueJiraKey(id: UUID, jiraKey: String?) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].jiraKey = jiraKey
        // Auto-set source to Jira when jiraKey is provided
        if let key = jiraKey, !key.isEmpty, trackedIssues[idx].source == .manual {
            trackedIssues[idx].source = .jira
        }
        touchIssue(at: idx)
    }

    func updateIssueCreatedAt(id: UUID, date: Date) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].createdAt = date
    }

    func updateIssueUpdatedAt(id: UUID, date: Date) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].updatedAt = date
    }

    func updateIssueSource(id: UUID, source: IssueSource) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].source = source
        touchIssue(at: idx)
    }

    func updateIssueTicketURL(id: UUID, ticketURL: String?) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].ticketURL = ticketURL
        touchIssue(at: idx)
    }

    func updateIssueTitle(id: UUID, title: String) {
        guard !title.isEmpty, let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        let old = trackedIssues[idx].title
        trackedIssues[idx].title = title
        touchIssue(at: idx)
        logOperation(module: "问题", action: "改名", detail: "\(old)→\(title)")
    }

    func updateIssueDepartment(id: UUID, department: String?) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].department = department
        touchIssue(at: idx)
    }

    func updateIssueType(id: UUID, type: IssueType) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].type = type
        touchIssue(at: idx)
    }

    func updateIssueDiaryBadge(id: UUID, badge: DiaryBadge) {
        guard let idx = trackedIssues.firstIndex(where: { $0.id == id }) else { return }
        trackedIssues[idx].diaryBadge = badge
    }

    func deleteIssue(id: UUID) {
        if let issue = trackedIssues.first(where: { $0.id == id }) {
            logOperation(module: "问题", action: "删除", detail: "[\(issue.type.rawValue)] \(issue.title)")
        }
        trackedIssues.removeAll { $0.id == id }
    }
}
