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
    var hotkeyModifier: String {
        didSet {
            UserDefaults.standard.set(hotkeyModifier, forKey: "hotkeyModifier")
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
    var jiraIssueCounts: [String: [String: Int]] {  // dateKey → issueKey → count
        didSet { saveJiraIssueCounts() }
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

    static let modifierOptions: [(id: String, label: String, carbonFlags: Int)] = [
        ("ctrl_shift", "⌃⇧", 0x1000 | 0x0200),   // controlKey | shiftKey
        ("cmd_shift",  "⌘⇧", 0x0100 | 0x0200),    // cmdKey | shiftKey
        ("opt_shift",  "⌥⇧", 0x0800 | 0x0200),    // optionKey | shiftKey
        ("ctrl_opt",   "⌃⌥", 0x1000 | 0x0800),     // controlKey | optionKey
        ("cmd_ctrl",   "⌘⌃", 0x0100 | 0x1000),     // cmdKey | controlKey
    ]

    var currentModifierLabel: String {
        Self.modifierOptions.first { $0.id == hotkeyModifier }?.label ?? "⌃⇧"
    }

    var currentCarbonFlags: UInt32 {
        UInt32(Self.modifierOptions.first { $0.id == hotkeyModifier }?.carbonFlags ?? (0x1000 | 0x0200))
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
        hotkeyModifier = UserDefaults.standard.string(forKey: "hotkeyModifier") ?? "ctrl_shift"

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
        if let data = UserDefaults.standard.data(forKey: "jiraIssueCounts"),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            jiraIssueCounts = decoded
        } else {
            jiraIssueCounts = [:]
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
    }

    func decrementForKey(_ key: String, dept: String) {
        var day = records[key] ?? [:]
        let current = day[dept, default: 0]
        guard current > 0 else { return }
        day[dept] = current - 1
        records[key] = day
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
    }

    func jiraDecrementForKey(_ dateKey: String, issueKey: String) {
        var day = jiraIssueCounts[dateKey] ?? [:]
        let current = day[issueKey, default: 0]
        guard current > 0 else { return }
        day[issueKey] = current - 1
        jiraIssueCounts[dateKey] = day
    }

    func jiraTodayCount(issueKey: String) -> Int {
        jiraIssueCounts[todayKey]?[issueKey] ?? 0
    }

    func jiraTotalCount(issueKey: String) -> Int {
        jiraIssueCounts.values.compactMap { $0[issueKey] }.reduce(0, +)
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
    }

    func totalCountForDepartment(_ dept: String) -> Int {
        records.values.compactMap { $0[dept] }.reduce(0, +)
    }

    // MARK: - Data Management

    func clearToday() {
        records.removeValue(forKey: todayKey)
        dailyNotes.removeValue(forKey: todayKey)
    }

    func clearAllHistory() {
        records = [:]
        dailyNotes = [:]
    }

    var totalDaysTracked: Int {
        Set(records.keys).union(dailyNotes.keys).count
    }

    var totalSupportCount: Int {
        records.values.flatMap(\.values).reduce(0, +)
    }

    func exportJSON() -> String? {
        let payload: [String: Any] = [
            "departments": departments,
            "records": records,
            "dailyNotes": dailyNotes
        ]
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

    private func saveJiraIssueCounts() {
        if let data = try? JSONEncoder().encode(jiraIssueCounts) {
            UserDefaults.standard.set(data, forKey: "jiraIssueCounts")
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
}
