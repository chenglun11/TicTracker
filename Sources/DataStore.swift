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

    var past7DaysTotals: [(date: String, weekday: String, total: Int)] {
        let calendar = Calendar.current
        return (0..<7).reversed().map { daysAgo in
            let d = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
            let key = Self.dateFormatter.string(from: d)
            let total = records[key]?.values.reduce(0, +) ?? 0
            return (key, Self.weekdayFormatter.string(from: d), total)
        }
    }

    var currentStreak: Int {
        let calendar = Calendar.current
        let fmt = Self.dateFormatter
        var streak = 0
        for daysAgo in 0..<365 {
            let d = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
            let key = fmt.string(from: d)
            let hasData = records[key] != nil || (dailyNotes[key].map { !$0.isEmpty } ?? false)
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
}
