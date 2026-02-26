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
        records.removeValue(forKey: todayKey)
        dailyNotes.removeValue(forKey: todayKey)
        tapTimestamps.removeValue(forKey: todayKey)
    }

    func clearAllHistory() {
        records = [:]
        dailyNotes = [:]
        tapTimestamps = [:]
        jiraTransitionLog = [:]
    }

    var totalDaysTracked: Int {
        Set(records.keys).union(dailyNotes.keys).count
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
}
