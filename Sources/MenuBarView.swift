import AppKit
import Combine
import SwiftUI

// MARK: - SwiftUI NoteTextView (for SettingsView)

struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var onTextChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.isUpdating = false
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        var isUpdating = false

        init(_ parent: NoteTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChange?(textView.string)
        }
    }
}

// MARK: - NSColor helpers

private let departmentNSColors: [NSColor] = [
    .systemBlue, .systemPurple, .systemOrange, .systemGreen, .systemPink,
    .systemYellow, .systemRed, .systemGray, NSColor(red: 0, green: 0.8, blue: 0.8, alpha: 1)
]

// MARK: - MenuBarViewController

final class MenuBarViewController: NSViewController {
    private let store: DataStore
    private var cancellables = Set<AnyCancellable>()

    private var selectedDate = Date()
    private var noteText = ""
    private var trendExpanded = true
    private var weeklyReportLoading = false
    private var weeklyReportResult: String?

    // UI elements
    private var dateLabel: NSTextField!
    private var backTodayButton: NSButton!
    private var departmentRows: NSStackView!
    private var trendSection: NSStackView!
    private var trendChartView: MiniChartNSView!
    private var trendToggleButton: NSButton!
    private var streakLabel: NSTextField!
    private var noteSection: NSStackView!
    private var noteTextView: NSTextView!
    private var noteScrollView: NSScrollView!
    private var notePlaceholder: NSTextField!
    private var reportSection: NSStackView!
    private var reportTextView: NSTextField!
    private var weeklyButton: NSButton!
    private var nextDayButton: NSButton?
    private var trendCard: NSView!
    private var noteCard: NSView!

    private var selectedKey: String {
        DataStore.dateKey(from: selectedDate)
    }

    private var isToday: Bool {
        selectedKey == store.todayKey
    }

    private static let displayDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "M/d (EEE)"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }()

    init(store: DataStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 480))
        self.view = container
        buildUI(in: container)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        selectedDate = Date()
        noteText = store.noteForKey(selectedKey)
        refreshAll()
    }

    // MARK: - Build UI

    private func buildUI(in container: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // 1. Date navigation row
        let dateRow = buildDateRow()
        stack.addArrangedSubview(dateRow)
        dateRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        // 2. Department counters (wrapped in card)
        departmentRows = NSStackView()
        departmentRows.orientation = .vertical
        departmentRows.alignment = .leading
        departmentRows.spacing = 6

        let deptCard = makeCardView()
        deptCard.addSubview(departmentRows)
        departmentRows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            departmentRows.topAnchor.constraint(equalTo: deptCard.topAnchor, constant: 10),
            departmentRows.leadingAnchor.constraint(equalTo: deptCard.leadingAnchor, constant: 10),
            departmentRows.trailingAnchor.constraint(equalTo: deptCard.trailingAnchor, constant: -10),
            departmentRows.bottomAnchor.constraint(equalTo: deptCard.bottomAnchor, constant: -10)
        ])
        stack.addArrangedSubview(deptCard)
        deptCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        // 3. Trend section (wrapped in card)
        trendSection = buildTrendSection()
        trendCard = makeCardView()
        trendCard.addSubview(trendSection)
        trendSection.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            trendSection.topAnchor.constraint(equalTo: trendCard.topAnchor, constant: 10),
            trendSection.leadingAnchor.constraint(equalTo: trendCard.leadingAnchor, constant: 10),
            trendSection.trailingAnchor.constraint(equalTo: trendCard.trailingAnchor, constant: -10),
            trendSection.bottomAnchor.constraint(equalTo: trendCard.bottomAnchor, constant: -10)
        ])
        stack.addArrangedSubview(trendCard)
        trendCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        // 4. Note section (wrapped in card)
        noteSection = buildNoteSection()
        noteCard = makeCardView()
        noteCard.addSubview(noteSection)
        noteSection.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noteSection.topAnchor.constraint(equalTo: noteCard.topAnchor, constant: 10),
            noteSection.leadingAnchor.constraint(equalTo: noteCard.leadingAnchor, constant: 10),
            noteSection.trailingAnchor.constraint(equalTo: noteCard.trailingAnchor, constant: -10),
            noteSection.bottomAnchor.constraint(equalTo: noteCard.bottomAnchor, constant: -10)
        ])
        stack.addArrangedSubview(noteCard)
        noteCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        // 5. Report section (hidden by default)
        reportSection = buildReportSection()
        reportSection.isHidden = true
        stack.addArrangedSubview(reportSection)
        reportSection.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        // 6. Spacer (flexible space)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)

        // 7. Bottom toolbar
        let toolbar = buildToolbar()
        stack.addArrangedSubview(toolbar)
        toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        // Subscribe to store changes
        store.$records
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDepartments() }
            .store(in: &cancellables)

        store.$departments
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDepartments() }
            .store(in: &cancellables)
    }

    // MARK: - Date Row

    private func buildDateRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let prevView = makeRoundedButton(title: "◀", target: self, action: #selector(prevDay))
        row.addArrangedSubview(prevView)

        dateLabel = makeLabel("", font: .systemFont(ofSize: 14, weight: .semibold))
        dateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dateLabel.alignment = .center
        row.addArrangedSubview(dateLabel)

        let nextView = makeRoundedButton(title: "▶", target: self, action: #selector(nextDay))
        row.addArrangedSubview(nextView)
        nextDayButton = nextView.subviews.first as? NSButton

        // Add "Back to today" button on the right
        backTodayButton = NSButton(title: "回到今天", target: self, action: #selector(backToToday))
        backTodayButton.isBordered = false
        backTodayButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        if #available(macOS 11.0, *) {
            backTodayButton.contentTintColor = .controlAccentColor
        }
        row.addArrangedSubview(backTodayButton)

        return row
    }

    // MARK: - Trend Section

    private func buildTrendSection() -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4

        // Header row
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY

        trendToggleButton = NSButton(title: "▼ 本周趋势", target: self, action: #selector(toggleTrend))
        trendToggleButton.isBordered = false
        trendToggleButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        if #available(macOS 11.0, *) {
            trendToggleButton.contentTintColor = .secondaryLabelColor
        }
        headerRow.addArrangedSubview(trendToggleButton)

        streakLabel = makeLabel("", font: .systemFont(ofSize: NSFont.smallSystemFontSize))
        streakLabel.textColor = .systemOrange
        headerRow.addArrangedSubview(streakLabel)

        section.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        // Chart
        trendChartView = MiniChartNSView(frame: NSRect(x: 0, y: 0, width: 310, height: 60))
        trendChartView.translatesAutoresizingMaskIntoConstraints = false
        trendChartView.heightAnchor.constraint(equalToConstant: 60).isActive = true
        section.addArrangedSubview(trendChartView)
        trendChartView.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        return section
    }

    // MARK: - Note Section

    private func buildNoteSection() -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4

        let titleLabel = makeLabel("", font: .systemFont(ofSize: NSFont.smallSystemFontSize))
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.tag = 100 // for updating
        section.addArrangedSubview(titleLabel)

        // Note text view in scroll view
        noteScrollView = NSScrollView()
        noteScrollView.hasVerticalScroller = false
        noteScrollView.hasHorizontalScroller = false
        noteScrollView.borderType = .noBorder
        noteScrollView.translatesAutoresizingMaskIntoConstraints = false
        noteScrollView.heightAnchor.constraint(equalToConstant: 80).isActive = true

        noteTextView = NSTextView()
        noteTextView.delegate = self
        noteTextView.isRichText = false
        noteTextView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        noteTextView.isEditable = true
        noteTextView.isSelectable = true
        noteTextView.allowsUndo = true
        noteTextView.drawsBackground = false
        noteTextView.textContainerInset = NSSize(width: 4, height: 4)
        noteTextView.isVerticallyResizable = true
        noteTextView.isHorizontallyResizable = false
        noteTextView.textContainer?.widthTracksTextView = true
        noteTextView.autoresizingMask = [.width]

        noteScrollView.documentView = noteTextView
        noteScrollView.drawsBackground = false

        // Border container
        let borderView = NSView()
        borderView.wantsLayer = true
        borderView.layer?.borderColor = NSColor.separatorColor.cgColor
        borderView.layer?.borderWidth = 1
        borderView.layer?.cornerRadius = 6
        borderView.translatesAutoresizingMaskIntoConstraints = false

        borderView.addSubview(noteScrollView)
        NSLayoutConstraint.activate([
            noteScrollView.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 2),
            noteScrollView.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 2),
            noteScrollView.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -2),
            noteScrollView.bottomAnchor.constraint(equalTo: borderView.bottomAnchor, constant: -2),
        ])
        borderView.heightAnchor.constraint(equalToConstant: 84).isActive = true

        // Placeholder
        notePlaceholder = makeLabel("记录今天做了什么…", font: .systemFont(ofSize: NSFont.systemFontSize))
        notePlaceholder.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        notePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        borderView.addSubview(notePlaceholder)
        NSLayoutConstraint.activate([
            notePlaceholder.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: 10),
            notePlaceholder.topAnchor.constraint(equalTo: borderView.topAnchor, constant: 8),
        ])

        section.addArrangedSubview(borderView)
        borderView.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        return section
    }

    // MARK: - Report Section

    private func buildReportSection() -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY

        let titleLabel = makeLabel("AI 周报", font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize))
        titleLabel.textColor = .secondaryLabelColor
        headerRow.addArrangedSubview(titleLabel)

        let copyBtn = NSButton(title: "复制", target: self, action: #selector(copyReport))
        copyBtn.isBordered = false
        copyBtn.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        headerRow.addArrangedSubview(copyBtn)

        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeReport))
        closeBtn.isBordered = false
        closeBtn.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        headerRow.addArrangedSubview(closeBtn)

        section.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        reportTextView = makeLabel("", font: .systemFont(ofSize: NSFont.smallSystemFontSize))
        reportTextView.maximumNumberOfLines = 10
        reportTextView.lineBreakMode = .byWordWrapping
        reportTextView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        section.addArrangedSubview(reportTextView)
        reportTextView.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        section.addArrangedSubview(makeDivider())

        return section
    }

    // MARK: - Toolbar

    private func buildToolbar() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill

        let settingsBtn = NSButton(title: "⚙", target: self, action: #selector(openSettings))
        settingsBtn.isBordered = false
        settingsBtn.font = NSFont.systemFont(ofSize: 14)
        row.addArrangedSubview(settingsBtn)

        let spacer1 = NSView()
        spacer1.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer1)

        weeklyButton = NSButton(title: "周报", target: self, action: #selector(generateReport))
        weeklyButton.isBordered = false
        weeklyButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        row.addArrangedSubview(weeklyButton)

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer2)

        let quitBtn = NSButton(title: "✕", target: self, action: #selector(quitApp))
        quitBtn.isBordered = false
        quitBtn.font = NSFont.systemFont(ofSize: 14)
        row.addArrangedSubview(quitBtn)

        return row
    }

    // MARK: - Refresh

    private func refreshAll() {
        refreshDateLabel()
        refreshDepartments()
        refreshTrend()
        refreshNote()
        refreshReport()
    }

    private func refreshDateLabel() {
        let displayDate = Self.displayDateFormatter.string(from: selectedDate)
        dateLabel.stringValue = "\(store.popoverTitle) · \(displayDate)"
        backTodayButton.isHidden = isToday

        // Disable next button when showing today
        nextDayButton?.isEnabled = !isToday
    }

    private func refreshDepartments() {
        // Remove old rows
        for view in departmentRows.arrangedSubviews {
            departmentRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if store.departments.isEmpty {
            let empty = makeLabel("暂无项目，请在设置中添加", font: .systemFont(ofSize: NSFont.systemFontSize))
            empty.textColor = .secondaryLabelColor
            departmentRows.addArrangedSubview(empty)
            return
        }

        let dayRecords = store.recordsForKey(selectedKey)
        for dept in store.departments {
            let count = dayRecords[dept, default: 0]
            let row = buildDepartmentRow(dept: dept, count: count)
            departmentRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: departmentRows.widthAnchor).isActive = true
        }
    }

    private func buildDepartmentRow(dept: String, count: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4

        // Add colored dot indicator
        let colorIndex = store.departments.firstIndex(of: dept) ?? 0
        let dotColor = departmentNSColors[colorIndex % departmentNSColors.count]
        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        row.addArrangedSubview(dot)

        let nameLabel = makeLabel(dept, font: .systemFont(ofSize: NSFont.systemFontSize))
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.addArrangedSubview(nameLabel)

        let countLabel = makeLabel("\(count)", font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
        countLabel.alignment = .left
        countLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true
        row.addArrangedSubview(countLabel)

        // Spacer to push buttons to the right
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(buttonSpacer)

        let minusView = makeRoundedButton(title: "−", target: self, action: #selector(decrementDept(_:)))
        if let minusBtn = minusView.subviews.first as? NSButton {
            minusBtn.identifier = NSUserInterfaceItemIdentifier(dept)
            minusBtn.isEnabled = count > 0
        }
        row.addArrangedSubview(minusView)

        let plusView = makeRoundedButton(title: "+", target: self, action: #selector(incrementDept(_:)))
        if let plusBtn = plusView.subviews.first as? NSButton {
            plusBtn.identifier = NSUserInterfaceItemIdentifier(dept)
        }
        row.addArrangedSubview(plusView)

        return row
    }

    private func refreshTrend() {
        trendCard.isHidden = !store.trendChartEnabled
        guard store.trendChartEnabled else { return }

        trendToggleButton.title = "\(trendExpanded ? "▼" : "▶") 本周趋势"
        trendChartView.isHidden = !trendExpanded

        if store.currentStreak > 0 {
            streakLabel.stringValue = "连续 \(store.currentStreak) 天"
            streakLabel.isHidden = false
        } else {
            streakLabel.isHidden = true
        }

        if trendExpanded {
            trendChartView.update(data: store.past7DaysBreakdown, departments: store.departments, todayKey: store.todayKey)
        }
    }

    private func refreshNote() {
        noteCard.isHidden = !store.dailyNoteEnabled
        guard store.dailyNoteEnabled else { return }

        // Update title label
        if let titleLabel = noteSection.arrangedSubviews.first as? NSTextField {
            titleLabel.stringValue = store.noteTitle
        }

        noteTextView.string = noteText
        notePlaceholder.isHidden = !noteText.isEmpty
    }

    private func refreshReport() {
        if let result = weeklyReportResult {
            reportSection.isHidden = false
            reportTextView.stringValue = result
        } else {
            reportSection.isHidden = true
        }
        weeklyButton.title = weeklyReportLoading ? "生成中…" : "周报"
        weeklyButton.isEnabled = !weeklyReportLoading
    }

    // MARK: - Actions

    @objc private func prevDay() {
        shiftDate(-1)
    }

    @objc private func nextDay() {
        shiftDate(1)
    }

    @objc private func backToToday() {
        selectedDate = Date()
        noteText = store.noteForKey(selectedKey)
        refreshAll()
    }

    @objc private func decrementDept(_ sender: NSButton) {
        guard let dept = sender.identifier?.rawValue else { return }
        store.decrementForKey(selectedKey, dept: dept)
        refreshDepartments()
    }

    @objc private func incrementDept(_ sender: NSButton) {
        guard let dept = sender.identifier?.rawValue else { return }
        store.incrementForKey(selectedKey, dept: dept)
        refreshDepartments()
    }

    @objc private func toggleTrend() {
        trendExpanded.toggle()
        refreshTrend()
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func generateReport() {
        let rawReport = WeeklyReport.generate(from: store)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawReport, forType: .string)

        if store.aiEnabled {
            weeklyReportLoading = true
            refreshReport()
            let config = store.aiConfig
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                do {
                    let aiReport = try await AIService.shared.generateWeeklyReport(rawReport: rawReport, config: config)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(aiReport, forType: .string)
                    self.weeklyReportResult = aiReport
                } catch {
                    self.weeklyReportResult = "AI 生成失败: \(error.localizedDescription)"
                }
                self.weeklyReportLoading = false
                self.refreshReport()
            }
        }
    }

    @objc private func copyReport() {
        guard let result = weeklyReportResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    @objc private func closeReport() {
        weeklyReportResult = nil
        refreshReport()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func shiftDate(_ days: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = min(d, Date())
            noteText = store.noteForKey(selectedKey)
            refreshAll()
        }
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        return divider
    }

    private func makeRoundedButton(title: String, target: Any?, action: Selector,
                                    identifier: NSUserInterfaceItemIdentifier? = nil) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.15).cgColor
        container.layer?.cornerRadius = 6
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 24).isActive = true
        container.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let btn = NSButton(title: title, target: target, action: action)
        btn.isBordered = false
        btn.font = NSFont.systemFont(ofSize: 14)
        btn.identifier = identifier
        btn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeCardView() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.12).cgColor
        card.layer?.cornerRadius = 8
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }
}

// MARK: - NSTextViewDelegate

extension MenuBarViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        noteText = textView.string
        store.setNoteForKey(selectedKey, text: noteText)
        notePlaceholder.isHidden = !noteText.isEmpty
    }
}

// MARK: - MiniChartNSView

final class MiniChartNSView: NSView {
    private var data: [(date: String, weekday: String, breakdown: [(dept: String, count: Int)])] = []
    private var departments: [String] = []
    private var todayKey: String = ""

    func update(data: [(date: String, weekday: String, breakdown: [(dept: String, count: Int)])], departments: [String], todayKey: String) {
        self.data = data
        self.departments = departments
        self.todayKey = todayKey
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !data.isEmpty else { return }

        let maxVal = max(data.map { $0.breakdown.reduce(0) { $0 + $1.count } }.max() ?? 1, 1)
        let barWidth: CGFloat = 20
        let spacing: CGFloat = (bounds.width - barWidth * CGFloat(data.count)) / CGFloat(data.count + 1)
        let labelHeight: CGFloat = 14
        let countHeight: CGFloat = 12
        let chartBottom = labelHeight + 2
        let chartTop = bounds.height - countHeight - 2

        for (i, item) in data.enumerated() {
            let total = item.breakdown.reduce(0) { $0 + $1.count }
            let x = spacing + CGFloat(i) * (barWidth + spacing)
            let isToday = item.date == todayKey

            // Weekday label at bottom
            let weekdayAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.5),
            ]
            let weekdayStr = NSAttributedString(string: item.weekday, attributes: weekdayAttr)
            let weekdaySize = weekdayStr.size()
            weekdayStr.draw(at: NSPoint(x: x + (barWidth - weekdaySize.width) / 2, y: 0))

            // Count label at top
            if total > 0 {
                let countAttr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let countStr = NSAttributedString(string: "\(total)", attributes: countAttr)
                let countSize = countStr.size()
                countStr.draw(at: NSPoint(x: x + (barWidth - countSize.width) / 2, y: chartTop + 2))
            }

            // Stacked bar
            let barHeight = total > 0 ? max(CGFloat(total) / CGFloat(maxVal) * (chartTop - chartBottom), 4) : 1
            var currentY = chartBottom

            if item.breakdown.isEmpty {
                let rect = NSRect(x: x, y: chartBottom, width: barWidth, height: 1)
                NSColor.secondaryLabelColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            } else {
                for segment in item.breakdown {
                    let segmentHeight = CGFloat(segment.count) / CGFloat(total) * barHeight
                    let colorIndex = departments.firstIndex(of: segment.dept) ?? 0
                    let color = departmentNSColors[colorIndex % departmentNSColors.count]
                    let rect = NSRect(x: x, y: currentY, width: barWidth, height: segmentHeight)
                    color.withAlphaComponent(isToday ? 1.0 : 0.55).setFill()
                    rect.fill()
                    currentY += segmentHeight
                }
            }
        }
    }
}
