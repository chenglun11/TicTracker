import SwiftUI
import Charts

struct StatisticsView: View {
    @Bindable var store: DataStore
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var endDate = Date()

    @State private var showStartPicker = false
    @State private var showEndPicker = false

    private func computeFilteredData() -> [(dept: String, count: Int)] {
        var totals: [String: Int] = [:]
        let calendar = Calendar.current
        var current = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        while current <= end {
            let key = DataStore.dateKey(from: current)
            if let dayRecords = store.records[key] {
                for (dept, count) in dayRecords {
                    totals[dept, default: 0] += count
                }
            }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return store.departments.compactMap { dept in
            let count = totals[dept, default: 0]
            return count > 0 ? (dept, count) : nil
        }
    }

    private struct Preset {
        let label: String
        let start: Date
    }

    private var presets: [Preset] {
        let cal = Calendar.current
        let today = Date()
        return [
            Preset(label: "近 7 天", start: cal.date(byAdding: .day, value: -6, to: today)!),
            Preset(label: "近 30 天", start: cal.date(byAdding: .day, value: -29, to: today)!),
            Preset(label: "本月", start: cal.date(from: cal.dateComponents([.year, .month], from: today))!),
            Preset(label: "全部", start: earliestDate),
        ]
    }

    private static let dateParseFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private var earliestDate: Date {
        let keys = Set(store.records.keys).union(store.dailyNotes.keys)
        return keys.compactMap { Self.dateParseFmt.date(from: $0) }.min() ?? Date()
    }

    private func isPresetActive(_ preset: Preset) -> Bool {
        Calendar.current.isDate(startDate, inSameDayAs: preset.start)
            && Calendar.current.isDateInToday(endDate)
    }

    private var dayCount: Int {
        let cal = Calendar.current
        return max((cal.dateComponents([.day], from: cal.startOfDay(for: startDate), to: cal.startOfDay(for: endDate)).day ?? 0) + 1, 0)
    }

    private static let displayFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy/M/d"
        return fmt
    }()

    var body: some View {
        let items = computeFilteredData()
        let grandTotal = items.reduce(0) { $0 + $1.count }
        VStack(spacing: 16) {
            // Date range presets + pickers
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.label) { preset in
                        Button(preset.label) {
                            startDate = preset.start
                            endDate = Date()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            isPresetActive(preset) ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(isPresetActive(preset) ? .white : .primary)
                    }
                    Spacer()
                }
                HStack(spacing: 6) {
                    Button(Self.displayFmt.string(from: startDate)) {
                        showStartPicker.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .popover(isPresented: $showStartPicker) {
                        DatePicker("", selection: $startDate, in: ...endDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(8)
                    }

                    Text("—")
                        .foregroundStyle(.tertiary)

                    Button(Self.displayFmt.string(from: endDate)) {
                        showEndPicker.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .popover(isPresented: $showEndPicker) {
                        DatePicker("", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(8)
                    }

                    Spacer()
                    Text("\(dayCount) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal)

            if items.isEmpty {
                Spacer()
                Text("所选日期范围内无数据")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Chart(items, id: \.dept) { item in
                    BarMark(
                        x: .value("项目", item.dept),
                        y: .value("次数", item.count)
                    )
                    .foregroundStyle(by: .value("项目", item.dept))
                }
                .chartForegroundStyleScale(
                    domain: items.map(\.dept),
                    range: items.map { item in
                        let idx = store.departments.firstIndex(of: item.dept) ?? 0
                        return departmentColors[idx % departmentColors.count]
                    }
                )
                .padding(.horizontal)

                List(items, id: \.dept) { item in
                    HStack {
                        let idx = store.departments.firstIndex(of: item.dept) ?? 0
                        Circle()
                            .fill(departmentColors[idx % departmentColors.count])
                            .frame(width: 8, height: 8)
                        Text(item.dept)
                        Spacer()
                        Text("\(item.count) 次")
                            .monospacedDigit()
                        Text(String(format: "%.1f%%", Double(item.count) / Double(grandTotal) * 100))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.top)
        .frame(minWidth: 500, minHeight: 400)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
