import CommonCrypto
import Foundation

@MainActor
final class FeishuBotService {
    static let shared = FeishuBotService()

    private var store: DataStore?
    private var schedulerTask: Task<Void, Never>?

    private static let keychainService = "com.tictracker.feishu-bot"
    private static let keychainAccount = "webhook-secret"

    func setup(store: DataStore) {
        self.store = store
    }

    // MARK: - Scheduler

    func startScheduler() {
        stopScheduler()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAndSend()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        DevLog.shared.info("FeishuBot", "定时发送已启动")
    }

    func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    func restartScheduler() {
        guard store?.feishuBotConfig.enabled == true else { return }
        startScheduler()
    }

    private func checkAndSend() async {
        guard let store, store.feishuBotConfig.enabled,
              !store.feishuBotConfig.webhookURL.isEmpty else { return }

        let config = store.feishuBotConfig
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let todayKey = DataStore.dateKey(from: now)

        guard hour == config.sendHour,
              minute == config.sendMinute,
              config.lastSentDate != todayKey else { return }

        let result = await sendReport(store: store)
        if result.success {
            store.feishuBotConfig.lastSentDate = todayKey
        }
    }

    // MARK: - Send

    /// 手动发送当天报告
    func sendNow(store: DataStore) async -> (success: Bool, message: String) {
        guard !store.feishuBotConfig.webhookURL.isEmpty else {
            return (false, "Webhook URL 为空")
        }
        return await sendReport(store: store)
    }

    private func sendReport(store: DataStore) async -> (success: Bool, message: String) {
        let payload = generateDailyReport(store: store)
        let config = store.feishuBotConfig

        guard let url = URL(string: config.webhookURL) else {
            DevLog.shared.error("FeishuBot", "Webhook URL 无效: \(config.webhookURL)")
            return (false, "Webhook URL 无效")
        }

        var body = payload
        if config.signEnabled {
            guard let secret = Self.loadSecret(), !secret.isEmpty else {
                DevLog.shared.error("FeishuBot", "签名已启用但 Secret 未配置")
                return (false, "签名 Secret 未配置")
            }
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let sign = Self.generateSign(timestamp: timestamp, secret: secret)
            body["timestamp"] = timestamp
            body["sign"] = sign
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            DevLog.shared.error("FeishuBot", "JSON 序列化失败")
            return (false, "JSON 序列化失败")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "无效的响应")
            }
            guard http.statusCode == 200 else {
                DevLog.shared.error("FeishuBot", "HTTP \(http.statusCode)")
                return (false, "HTTP \(http.statusCode)")
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let code = json["StatusCode"] as? Int ?? json["code"] as? Int
                if code == 0 {
                    DevLog.shared.info("FeishuBot", "日报发送成功")
                    return (true, "发送成功")
                }
                let msg = json["StatusMessage"] as? String ?? json["msg"] as? String ?? "未知错误"
                DevLog.shared.error("FeishuBot", "飞书返回错误: \(msg)")
                return (false, msg)
            }
            let text = String(data: data, encoding: .utf8) ?? "unknown"
            DevLog.shared.error("FeishuBot", "飞书返回错误: \(text)")
            return (false, "响应解析失败")
        } catch {
            DevLog.shared.error("FeishuBot", "发送失败: \(error.localizedDescription)")
            return (false, "网络错误: \(error.localizedDescription)")
        }
    }

    // MARK: - Report Generation

    private func generateDailyReport(store: DataStore) -> [String: Any] {
        switch store.feishuBotConfig.messageFormat {
        case .card:
            return generateCardReport(store: store)
        case .richText:
            return generateRichTextReport(store: store)
        }
    }

    // MARK: - Shared Data

    private struct ReportData {
        let todayKey: String
        let newIssues: [TrackedIssue]
        let resolvedToday: [TrackedIssue]
        let pending: [TrackedIssue]
        let todayRecords: [String: Int]
        let todayTotal: Int
        let dailyNote: String
        let config: FeishuBotConfig
        let jiraServerURL: String
    }

    private func collectReportData(store: DataStore) -> ReportData {
        let config = store.feishuBotConfig
        let todayKey = store.todayKey
        let allIssues = store.issuesVisibleForKey(todayKey)
        return ReportData(
            todayKey: todayKey,
            newIssues: allIssues.filter { $0.dateKey == todayKey && !$0.status.isResolved },
            resolvedToday: allIssues.filter { issue in
                guard issue.status.isResolved, let resolvedAt = issue.resolvedAt else { return false }
                return DataStore.dateKey(from: resolvedAt) == todayKey
            },
            pending: allIssues.filter { !$0.status.isResolved },
            todayRecords: store.todayRecords,
            todayTotal: store.todayTotal,
            dailyNote: store.dailyNotes[todayKey] ?? "",
            config: config,
            jiraServerURL: store.jiraConfig.serverURL
        )
    }

    // MARK: - Rich Text (post) Report

    private func generateRichTextReport(store: DataStore) -> [String: Any] {
        let d = collectReportData(store: store)
        let commentFmt = DateFormatter()
        commentFmt.dateFormat = "M/d HH:mm"

        var lines: [[[String: Any]]] = []

        // === 解决情况高亮摘要 ===
        if d.config.showOverview {
            lines.append([
                text("🟢 今日新建 \(d.newIssues.count)  ·  ✅ 今日解决 \(d.resolvedToday.count)  ·  🔶 待处理 \(d.pending.count)")
            ])
            lines.append([text("")])
        }

        // === 项目支持统计 ===
        if d.config.showSupportStats && d.todayTotal > 0 {
            let parts = d.todayRecords.sorted(by: { $0.key < $1.key })
                .map { "\($0.key) \($0.value)次" }
            lines.append([
                text("📊 项目支持：\(parts.joined(separator: "，"))（共 \(d.todayTotal) 次）")
            ])
            lines.append([text("")])
        }

        // === 待处理问题 ===
        if d.config.showPending && !d.pending.isEmpty {
            lines.append([text("📋 待处理问题：")])
            for issue in d.pending {
                lines.append(richTextIssueLine(issue, showStatus: d.config.fieldStatus, config: d.config, jiraServerURL: d.jiraServerURL))
                if d.config.showComments {
                    for comment in issue.comments.suffix(2) {
                        let time = commentFmt.string(from: comment.createdAt)
                        lines.append([text("      ↳ [\(time)] \(Self.truncateTitle(comment.text, maxLength: 80))")])
                    }
                }
            }
            lines.append([text("")])
        }

        // === 今日已解决 ===
        if d.config.showResolved && !d.resolvedToday.isEmpty {
            lines.append([text("✅ 今日已解决：")])
            for issue in d.resolvedToday {
                lines.append(richTextIssueLine(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL))
                if d.config.showComments {
                    for comment in issue.comments.suffix(2) {
                        let time = commentFmt.string(from: comment.createdAt)
                        lines.append([text("      ↳ [\(time)] \(Self.truncateTitle(comment.text, maxLength: 80))")])
                    }
                }
            }
            lines.append([text("")])
        }

        // === 日报文字 ===
        if d.config.showDailyNote && !d.dailyNote.isEmpty {
            lines.append([text("📝 日报：")])
            for noteLine in d.dailyNote.components(separatedBy: .newlines) {
                lines.append([text(noteLine)])
            }
            lines.append([text("")])
        }

        // 无数据
        if lines.isEmpty {
            lines.append([text("今日暂无工单记录")])
        }

        // 底部
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append([text("—— 由 TicTracker 自动生成 | \(timeFmt.string(from: Date()))")])

        return [
            "msg_type": "post",
            "content": [
                "post": [
                    "zh_cn": [
                        "title": "每日工单报告（\(d.todayKey)）",
                        "content": lines
                    ]
                ]
            ]
        ]
    }

    /// 富文本: 单个 issue 行（含可选链接）
    private func richTextIssueLine(_ issue: TrackedIssue, showStatus: Bool, config: FeishuBotConfig, jiraServerURL: String) -> [[String: Any]] {
        let title = Self.truncateTitle(issue.title)
        var parts: [[String: Any]] = []

        let statusStr = showStatus ? "[\(issue.status.rawValue)] " : ""
        var tagParts: [String] = []
        if config.fieldType { tagParts.append(issue.type.rawValue) }
        if config.fieldDepartment, let dept = issue.department, !dept.isEmpty { tagParts.append(dept) }
        if config.fieldAssignee, let a = issue.assignee, !a.isEmpty { tagParts.append(a) }
        let tagStr = tagParts.isEmpty ? "" : " (\(tagParts.joined(separator: " · ")))"

        // Jira key 作为超链接
        if config.fieldJiraKey, let jira = issue.jiraKey, !jira.isEmpty {
            let (key, url) = Self.jiraKeyAndURL(jira, serverURL: jiraServerURL)
            parts.append(text("· \(statusStr)\(title)\(tagStr) "))
            if let url {
                parts.append(link(key, href: url))
            } else {
                parts.append(text(key))
            }
        } else {
            parts.append(text("· \(statusStr)\(title)\(tagStr)"))
        }

        return parts
    }

    // MARK: - Card Report

    private func generateCardReport(store: DataStore) -> [String: Any] {
        let d = collectReportData(store: store)
        let commentFmt = DateFormatter()
        commentFmt.dateFormat = "M/d HH:mm"

        var elements: [[String: Any]] = []

        // 日期 + 项目支持统计
        var dateLine = "**日期：** \(d.todayKey)"
        if d.config.showSupportStats && d.todayTotal > 0 {
            let parts = d.todayRecords.sorted(by: { $0.key < $1.key })
                .map { "\($0.key) \($0.value)次" }
            dateLine += "\n**项目支持：** \(parts.joined(separator: "，"))（共 \(d.todayTotal) 次）"
        }
        elements.append(["tag": "div", "text": ["tag": "lark_md", "content": dateLine]])

        // 统计概览（高亮）
        if d.config.showOverview {
            elements.append(["tag": "hr"])
            let statsLine = "🟢 **今日新建** \(d.newIssues.count) 个  ·  ✅ **今日解决** \(d.resolvedToday.count) 个  ·  🔶 **待处理** \(d.pending.count) 个"
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": statsLine]])
        }

        // 待处理问题列表 + 评论
        if d.config.showPending && !d.pending.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**待处理问题：**"
            for issue in d.pending {
                content += "\n" + Self.formatIssue(issue, showStatus: d.config.fieldStatus, config: d.config, jiraServerURL: d.jiraServerURL)
                if d.config.showComments {
                    for comment in issue.comments.suffix(2) {
                        let time = commentFmt.string(from: comment.createdAt)
                        content += "\n    *[\(time)] \(Self.truncateTitle(comment.text, maxLength: 80))*"
                    }
                }
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 今日已解决列表 + 评论
        if d.config.showResolved && !d.resolvedToday.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**今日已解决：**"
            for issue in d.resolvedToday {
                content += "\n" + Self.formatIssue(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL)
                if d.config.showComments {
                    for comment in issue.comments.suffix(2) {
                        let time = commentFmt.string(from: comment.createdAt)
                        content += "\n    *[\(time)] \(Self.truncateTitle(comment.text, maxLength: 80))*"
                    }
                }
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 日报文字
        if d.config.showDailyNote && !d.dailyNote.isEmpty {
            elements.append(["tag": "hr"])
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": "**日报：**\n\(d.dailyNote)"]])
        }

        // 无数据
        let hasContent = (d.config.showSupportStats && d.todayTotal > 0)
            || d.config.showOverview
            || (d.config.showPending && !d.pending.isEmpty)
            || (d.config.showResolved && !d.resolvedToday.isEmpty)
        if !hasContent {
            elements.append(["tag": "hr"])
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": "今日暂无工单记录"]])
        }

        // 底部备注
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"
        elements.append(["tag": "note", "elements": [["tag": "plain_text", "content": "由 TicTracker 自动生成 | \(timeFmt.string(from: Date()))"]]])

        return [
            "msg_type": "interactive",
            "card": [
                "config": ["wide_screen_mode": true],
                "header": ["title": ["tag": "plain_text", "content": "每日工单报告"], "template": "blue"],
                "elements": elements
            ]
        ]
    }

    // MARK: - Issue Formatting

    /// 将 jiraKey 转为 [KEY](url) 超链接
    private static func formatJiraKey(_ jiraKey: String, serverURL: String) -> String {
        if jiraKey.hasPrefix("http"), let url = URL(string: jiraKey) {
            let key = url.lastPathComponent
            return "[\(key)](\(jiraKey))"
        }
        // 普通 key，用 jiraConfig.serverURL 拼接
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.isEmpty {
            return "[\(jiraKey)](\(base)/browse/\(jiraKey))"
        }
        return jiraKey
    }

    /// 截断过长标题，只取第一行
    private static func truncateTitle(_ title: String, maxLength: Int = 50) -> String {
        let firstLine = title.components(separatedBy: .newlines).first ?? title
        if firstLine.count > maxLength {
            return String(firstLine.prefix(maxLength)) + "…"
        }
        return firstLine
    }

    /// 格式化单个 issue 为一行 markdown
    private static func formatIssue(_ issue: TrackedIssue, showStatus: Bool, config: FeishuBotConfig, jiraServerURL: String = "") -> String {
        let title = truncateTitle(issue.title)
        var tags: [String] = []
        if config.fieldType { tags.append(issue.type.rawValue) }
        if config.fieldDepartment, let dept = issue.department, !dept.isEmpty { tags.append(dept) }
        if config.fieldJiraKey, let jira = issue.jiraKey, !jira.isEmpty { tags.append(formatJiraKey(jira, serverURL: jiraServerURL)) }
        if config.fieldAssignee, let assignee = issue.assignee, !assignee.isEmpty { tags.append(assignee) }
        let tagPart = tags.isEmpty ? "" : " (\(tags.joined(separator: " · ")))"
        let statusPrefix = showStatus ? "[\(issue.status.rawValue)] " : ""
        return "- \(statusPrefix)\(title)\(tagPart)"
    }

    /// 提取 jiraKey 的显示文本和完整 URL
    private static func jiraKeyAndURL(_ jiraKey: String, serverURL: String) -> (key: String, url: String?) {
        if jiraKey.hasPrefix("http"), let u = URL(string: jiraKey) {
            return (u.lastPathComponent, jiraKey)
        }
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.isEmpty {
            return (jiraKey, "\(base)/browse/\(jiraKey)")
        }
        return (jiraKey, nil)
    }

    // MARK: - Rich Text Helpers

    private func text(_ content: String) -> [String: Any] {
        ["tag": "text", "text": content]
    }

    private func boldText(_ content: String) -> [String: Any] {
        ["tag": "text", "text": content]
    }

    private func link(_ text: String, href: String) -> [String: Any] {
        ["tag": "a", "text": text, "href": href]
    }

    // MARK: - HMAC-SHA256 Signature

    /// 飞书签名: base64(HMAC-SHA256(key=timestamp\nsecret, data=""))
    static func generateSign(timestamp: String, secret: String) -> String {
        let stringToSign = "\(timestamp)\n\(secret)"
        let keyData = Array(stringToSign.utf8)
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let empty = [UInt8]()
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
               keyData, keyData.count,
               empty, 0,
               &hmac)
        return Data(hmac).base64EncodedString()
    }

    // MARK: - Keychain

    static func saveSecret(_ secret: String) {
        if let data = secret.data(using: .utf8) {
            KeychainHelper.save(service: keychainService, account: keychainAccount, data: data)
        }
    }

    static func loadSecret() -> String? {
        guard let data = KeychainHelper.load(service: keychainService, account: keychainAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
