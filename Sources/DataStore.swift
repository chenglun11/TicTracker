import Foundation
import Combine

final class DataStore: ObservableObject {
    @Published var departments: [String] {
        didSet { saveDepartments() }
    }
    @Published var records: [String: [String: Int]] {
        didSet { saveRecords() }
    }
    @Published var dailyNotes: [String: String] {
        didSet { saveDailyNotes() }
    }
    @Published var popoverTitle: String {
        didSet { UserDefaults.standard.set(popoverTitle, forKey: "popoverTitle") }
    }
    @Published var noteTitle: String {
        didSet { UserDefaults.standard.set(noteTitle, forKey: "noteTitle") }
    }

    // MARK: - Feature Toggles

    @Published var dailyNoteEnabled: Bool {
        didSet { UserDefaults.standard.set(dailyNoteEnabled, forKey: "dailyNoteEnabled") }
    }
    @Published var trendChartEnabled: Bool {
        didSet { UserDefaults.standard.set(trendChartEnabled, forKey: "trendChartEnabled") }
    }

    // MARK: - AI

    @Published var aiConfig: AIConfig {
        didSet { saveAIConfig() }
    }
    @Published var aiEnabled: Bool {
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

        // Feature toggles
        dailyNoteEnabled = UserDefaults.standard.object(forKey: "dailyNoteEnabled") as? Bool ?? true
        trendChartEnabled = UserDefaults.standard.object(forKey: "trendChartEnabled") as? Bool ?? true

        // AI
        if let data = UserDefaults.standard.data(forKey: "aiConfig"),
           let decoded = try? JSONDecoder().decode(AIConfig.self, from: data) {
            aiConfig = decoded
        } else {
            aiConfig = AIConfig()
        }
        aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? false

        // Restore base URL / model from Keychain
        let stored = AIService.shared.loadAll()
        if !stored.baseURL.isEmpty { aiConfig.baseURL = stored.baseURL }
        if !stored.model.isEmpty { aiConfig.model = stored.model }
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
                continue
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
            "dailyNotes": dailyNotes,
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

    private func saveAIConfig() {
        if let data = try? JSONEncoder().encode(aiConfig) {
            UserDefaults.standard.set(data, forKey: "aiConfig")
        }
    }
}
