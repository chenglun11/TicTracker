import AppKit
import Foundation

@MainActor
enum ReportVisualRenderer {
    private struct VisualData {
        let title: String
        let subtitle: String
        let records: [String: Int]
        let dailyTotals: [(label: String, count: Int)]
        let issues: [TrackedIssue]
        let note: String
        let supportTotal: Int
    }

    static func renderDailyReport(store: DataStore) -> NSImage {
        let records = store.todayRecords
        let visibleIssues = store.issuesVisibleForKey(store.todayKey)
        let date = Date()
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "yyyy-MM-dd EEEE"
        displayFmt.locale = Locale(identifier: "zh_CN")
        let data = VisualData(
            title: store.feishuBotConfig.cardTitle.isEmpty ? "每日工单报告" : store.feishuBotConfig.cardTitle,
            subtitle: displayFmt.string(from: date),
            records: records,
            dailyTotals: [(label: "今日", count: records.values.reduce(0, +))],
            issues: visibleIssues,
            note: store.dailyNotes[store.todayKey] ?? "",
            supportTotal: records.values.reduce(0, +)
        )
        return render(data: data)
    }

    static func renderPeriodReport(store: DataStore, period: WeeklyReport.Period) -> NSImage {
        let calendar = Calendar.current
        let (start, end) = WeeklyReport.dateRange(for: period)
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: end)!
        let keyFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM-dd"
        let shortFmt = DateFormatter()
        shortFmt.dateFormat = "M/d"
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "M/d"

        var records: [String: Int] = [:]
        var dailyTotals: [(String, Int)] = []
        var notes: [String] = []
        var date = start
        while date <= end {
            let key = keyFmt.string(from: date)
            let supportCount = store.records[key]?.values.reduce(0, +) ?? 0
            let jiraCount = store.jiraIssueCounts[key]?.values.reduce(0, +) ?? 0
            dailyTotals.append((dayFmt.string(from: date), supportCount + jiraCount))
            for (name, count) in store.records[key] ?? [:] {
                records[name, default: 0] += count
            }
            if let note = store.dailyNotes[key], !note.isEmpty {
                notes.append("\(dayFmt.string(from: date)): \(note)")
            }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }

        let issues = store.visibleTrackedIssues.filter { issue in
            let keyInRange = issue.dateKey >= keyFmt.string(from: start) && issue.dateKey <= keyFmt.string(from: end)
            let createdInRange = issue.createdAt >= start && issue.createdAt < endExclusive
            let updatedInRange = issue.updatedAt.map { $0 >= start && $0 < endExclusive } ?? false
            let resolvedInRange = issue.resolvedAt.map { $0 >= start && $0 < endExclusive } ?? false
            return keyInRange || createdInRange || updatedInRange || resolvedInRange
        }

        let title = "技术支持\(period.reportName)"
        let subtitle = "\(shortFmt.string(from: start)) - \(shortFmt.string(from: end))"
        let data = VisualData(
            title: title,
            subtitle: subtitle,
            records: records,
            dailyTotals: dailyTotals,
            issues: issues,
            note: notes.joined(separator: "\n"),
            supportTotal: records.values.reduce(0, +)
        )
        return render(data: data)
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func render(data: VisualData) -> NSImage {
        let width: CGFloat = 1200
        let margin: CGFloat = 64
        let contentWidth = width - margin * 2
        let issueRows = max(data.issues.count, 1)
        let projectRows = max(data.records.count, 1)
        let dayRows = max(data.dailyTotals.count, 1)
        let noteHeight = data.note.isEmpty ? 0 : min(max(textHeight(data.note, width: contentWidth - 48, font: .systemFont(ofSize: 28)) + 72, 120), 420)
        let height = max(1100, 520 + CGFloat(projectRows * 42 + dayRows * 34 + issueRows * 58) + noteHeight)
        let image = NSImage(size: NSSize(width: width, height: height))

        image.lockFocus()
        NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()

        var y = height - margin
        drawText(data.title, x: margin, y: y, width: contentWidth, font: .boldSystemFont(ofSize: 54), color: NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.13, alpha: 1))
        y -= 58
        drawText(data.subtitle, x: margin, y: y, width: contentWidth, font: .systemFont(ofSize: 28), color: .secondaryLabelColor)
        y -= 72

        let pending = data.issues.filter { !$0.status.isResolved && $0.status != .observing }.count
        let resolved = data.issues.filter(\.status.isResolved).count
        drawMetricCards(
            [
                ("支持次数", "\(data.supportTotal)", NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1)),
                ("问题总数", "\(data.issues.count)", NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.88, alpha: 1)),
                ("待处理", "\(pending)", NSColor(calibratedRed: 0.90, green: 0.36, blue: 0.18, alpha: 1)),
                ("已解决", "\(resolved)", NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.34, alpha: 1))
            ],
            x: margin,
            y: y,
            width: contentWidth
        )
        y -= 170

        y = drawSection(title: "项目支持", x: margin, y: y, width: contentWidth) { sectionY in
            drawBars(
                rows: data.records.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value },
                emptyText: "暂无项目支持记录",
                x: margin + 24,
                y: sectionY,
                width: contentWidth - 48,
                accent: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1)
            )
        }

        y = drawSection(title: "每日趋势", x: margin, y: y - 24, width: contentWidth) { sectionY in
            drawDailyTrend(data.dailyTotals, x: margin + 24, y: sectionY, width: contentWidth - 48)
        }

        var statusCounts: [IssueStatus: Int] = [:]
        for issue in data.issues {
            statusCounts[issue.status, default: 0] += 1
        }
        let statusRows: [(String, Int)] = statusCounts
            .map { status, count in (status.rawValue, count) }
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1 }
        y = drawSection(title: "问题状态", x: margin, y: y - 24, width: contentWidth) { sectionY in
            drawBars(rows: statusRows, emptyText: "暂无问题记录", x: margin + 24, y: sectionY, width: contentWidth - 48, accent: NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.88, alpha: 1))
        }

        let issueRowsData = data.issues.sorted {
            if $0.status.isResolved != $1.status.isResolved { return !$0.status.isResolved }
            return $0.dateKey > $1.dateKey
        }
        y = drawSection(title: "问题明细", x: margin, y: y - 24, width: contentWidth) { sectionY in
            drawIssueRows(issueRowsData, x: margin + 24, y: sectionY, width: contentWidth - 48)
        }

        if !data.note.isEmpty {
            _ = drawSection(title: "记录", x: margin, y: y - 24, width: contentWidth) { sectionY in
                let rect = NSRect(x: margin + 24, y: sectionY - noteHeight + 34, width: contentWidth - 48, height: noteHeight - 48)
                drawWrappedText(data.note, rect: rect, font: .systemFont(ofSize: 26), color: .labelColor)
                return noteHeight
            }
        }

        image.unlockFocus()
        return image
    }

    private static func drawMetricCards(_ cards: [(String, String, NSColor)], x: CGFloat, y: CGFloat, width: CGFloat) {
        let gap: CGFloat = 18
        let cardWidth = (width - gap * CGFloat(cards.count - 1)) / CGFloat(cards.count)
        for (index, card) in cards.enumerated() {
            let rect = NSRect(x: x + CGFloat(index) * (cardWidth + gap), y: y - 128, width: cardWidth, height: 128)
            rounded(rect, radius: 18, color: .white)
            card.2.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 8, height: rect.height), xRadius: 4, yRadius: 4).fill()
            drawText(card.0, x: rect.minX + 28, y: rect.maxY - 38, width: cardWidth - 56, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            drawText(card.1, x: rect.minX + 28, y: rect.maxY - 92, width: cardWidth - 56, font: .boldSystemFont(ofSize: 44), color: card.2)
        }
    }

    private static func drawSection(title: String, x: CGFloat, y: CGFloat, width: CGFloat, draw: (CGFloat) -> CGFloat) -> CGFloat {
        drawText(title, x: x, y: y, width: width, font: .boldSystemFont(ofSize: 32), color: .labelColor)
        let contentStart = y - 56
        let contentHeight = draw(contentStart)
        return contentStart - contentHeight
    }

    private static func drawBars(rows: [(String, Int)], emptyText: String, x: CGFloat, y: CGFloat, width: CGFloat, accent: NSColor) -> CGFloat {
        guard !rows.isEmpty else {
            drawText(emptyText, x: x, y: y, width: width, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            return 48
        }
        let maxValue = max(rows.map(\.1).max() ?? 1, 1)
        var cursor = y
        for row in rows {
            drawText(row.0, x: x, y: cursor, width: 260, font: .systemFont(ofSize: 24), color: .labelColor)
            drawText("\(row.1)", x: x + width - 80, y: cursor, width: 80, font: .boldSystemFont(ofSize: 24), color: .labelColor, alignment: .right)
            let barX = x + 290
            let barWidth = max(8, (width - 400) * CGFloat(row.1) / CGFloat(maxValue))
            rounded(NSRect(x: barX, y: cursor - 20, width: width - 400, height: 14), radius: 7, color: NSColor(calibratedWhite: 0.88, alpha: 1))
            rounded(NSRect(x: barX, y: cursor - 20, width: barWidth, height: 14), radius: 7, color: accent)
            cursor -= 42
        }
        return CGFloat(rows.count * 42)
    }

    private static func drawDailyTrend(_ rows: [(label: String, count: Int)], x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        guard !rows.isEmpty else {
            drawText("暂无趋势数据", x: x, y: y, width: width, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            return 64
        }
        let chartHeight: CGFloat = 180
        let maxValue = max(rows.map(\.count).max() ?? 1, 1)
        let gap: CGFloat = 10
        let barWidth = max(18, (width - gap * CGFloat(rows.count - 1)) / CGFloat(rows.count))
        let baseY = y - chartHeight
        for (index, row) in rows.enumerated() {
            let h = max(6, (chartHeight - 48) * CGFloat(row.count) / CGFloat(maxValue))
            let barX = x + CGFloat(index) * (barWidth + gap)
            rounded(NSRect(x: barX, y: baseY + 34, width: barWidth, height: h), radius: 6, color: NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.34, alpha: 1))
            drawText(row.label, x: barX - 8, y: baseY + 18, width: barWidth + 16, font: .systemFont(ofSize: 18), color: .secondaryLabelColor, alignment: .center)
            drawText("\(row.count)", x: barX - 8, y: baseY + 52 + h, width: barWidth + 16, font: .boldSystemFont(ofSize: 18), color: .labelColor, alignment: .center)
        }
        return chartHeight
    }

    private static func drawIssueRows(_ issues: [TrackedIssue], x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        guard !issues.isEmpty else {
            drawText("暂无问题记录", x: x, y: y, width: width, font: .systemFont(ofSize: 24), color: .secondaryLabelColor)
            return 48
        }
        var cursor = y
        for issue in issues {
            let statusColor = issue.status.isResolved ? NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.34, alpha: 1) : NSColor(calibratedRed: 0.90, green: 0.36, blue: 0.18, alpha: 1)
            rounded(NSRect(x: x, y: cursor - 44, width: 110, height: 32), radius: 8, color: statusColor.withAlphaComponent(0.12))
            drawText(issue.status.rawValue, x: x + 10, y: cursor - 20, width: 90, font: .boldSystemFont(ofSize: 18), color: statusColor, alignment: .center)
            let meta = [issue.linearKey, issue.jiraKey, issue.assignee, issue.department].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            drawText(issue.title, x: x + 130, y: cursor - 4, width: width - 130, font: .systemFont(ofSize: 24), color: .labelColor)
            drawText(meta.isEmpty ? "\(issue.type.rawValue) · \(issue.dateKey)" : "\(issue.type.rawValue) · \(issue.dateKey) · \(meta)", x: x + 130, y: cursor - 32, width: width - 130, font: .systemFont(ofSize: 18), color: .secondaryLabelColor)
            cursor -= 58
        }
        return CGFloat(issues.count * 58)
    }

    private static func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: NSRect(x: x, y: y - font.pointSize - 6, width: width, height: font.pointSize + 12), withAttributes: attrs)
    }

    private static func drawWrappedText(_ text: String, rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private static func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        return ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs).height)
    }
}
