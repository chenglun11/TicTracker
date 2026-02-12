import Foundation

@Observable
final class DataStore {
    var departments: [String] {
        didSet { saveDepartments() }
    }
    var records: [String: [String: Int]] {
        didSet { saveRecords() }
    }

    private let departmentsKey = "departments"
    private let recordsKey = "records"

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
    }

    // MARK: - Today

    var todayKey: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    var todayRecords: [String: Int] {
        records[todayKey] ?? [:]
    }

    var todayTotal: Int {
        todayRecords.values.reduce(0, +)
    }

    func increment(_ dept: String) {
        var day = records[todayKey] ?? [:]
        day[dept, default: 0] += 1
        records[todayKey] = day
    }

    func decrement(_ dept: String) {
        var day = records[todayKey] ?? [:]
        let current = day[dept, default: 0]
        guard current > 0 else { return }
        day[dept] = current - 1
        records[todayKey] = day
    }

    // MARK: - Departments

    func addDepartment(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !departments.contains(trimmed) else { return }
        departments.append(trimmed)
    }

    func removeDepartment(at offsets: IndexSet) {
        departments.remove(atOffsets: offsets)
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
}
