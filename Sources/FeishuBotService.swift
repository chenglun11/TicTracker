import AppKit
import CommonCrypto
import Foundation

@MainActor
final class FeishuBotService {
    static let shared = FeishuBotService()

    private var store: DataStore?
    private var schedulerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    private static let keychainService = "com.tictracker.keychain"
    private static let keychainAccount = "webhook-secret"

    func setup(store: DataStore) {
        self.store = store
        observeSystemWake()
    }

    /// 一次性迁移：旧全局 secret → 复制到所有 signEnabled 的 webhook
    private func migrateSecrets(store: DataStore) {
        guard let secret = Self.loadLegacySecret(), !secret.isEmpty else { return }
        for webhook in store.feishuBotConfig.webhooks where webhook.signEnabled {
            if Self.loadSecret(for: webhook.id) == nil {
                Self.saveSecret(for: webhook.id, secret: secret)
            }
        }
        Self.deleteLegacySecret()
        DevLog.shared.info("FeishuBot", "已迁移全局 Secret 到 \(store.feishuBotConfig.webhooks.filter { $0.signEnabled }.count) 个 Webhook")
    }

    // MARK: - System Wake

    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWake()
            }
        }
    }

    private func handleSystemWake() {
        DevLog.shared.info("FeishuBot", "系统唤醒，检查是否有错过的定时发送")
        guard let store, store.feishuBotConfig.enabled,
              !store.feishuBotConfig.webhooks.isEmpty else { return }

        Task { [weak self] in
            await self?.catchUpMissedSends()
        }
    }

    /// 唤醒后检查今天是否有已过时间但未发送的定时任务，如有则补发
    private func catchUpMissedSends() async {
        guard let store else { return }

        // httpAPI 模式下由服务器负责
        if SyncManager.shared.config.enabled && SyncManager.shared.config.backend == .httpAPI {
            return
        }

        let config = store.feishuBotConfig
        let now = Date()
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let todayKey = DataStore.dateKey(from: now)
        let isoWeekday = calendar.component(.weekday, from: now)
        let weekday = isoWeekday == 1 ? 7 : isoWeekday - 1

        for scheduleTime in config.sendTimes {
            // 已经发过了，跳过
            guard config.lastSentTimes[scheduleTime.key] != todayKey else { continue }

            // 检查星期限制
            guard scheduleTime.shouldSendOn(weekday: weekday) else { continue }

            // 只补发已过去的时间点（当前时间 > 计划时间）
            let isPast = currentHour > scheduleTime.hour
                || (currentHour == scheduleTime.hour && currentMinute > scheduleTime.minute)
            guard isPast else { continue }

            DevLog.shared.info("FeishuBot", "补发错过的 \(scheduleTime.key) 日报")
            let result = await sendReport(store: store)
            if result.success {
                store.feishuBotConfig.lastSentTimes[scheduleTime.key] = todayKey
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                store.feishuBotConfig.lastSentDateTime = fmt.string(from: now)
                DevLog.shared.info("FeishuBot", "补发 \(scheduleTime.key) 成功")
            } else {
                DevLog.shared.error("FeishuBot", "补发 \(scheduleTime.key) 失败: \(result.message)")
            }
        }
    }

    // MARK: - Scheduler

    func startScheduler() {
        stopScheduler()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAndSend()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        DevLog.shared.info("FeishuBot", "定时发送已启动，共 \(store?.feishuBotConfig.sendTimes.count ?? 0) 个时间点")
    }

    func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
        DevLog.shared.info("FeishuBot", "定时发送已停止")
    }

    func restartScheduler() {
        guard store?.feishuBotConfig.enabled == true else { return }
        startScheduler()
    }

    private func checkAndSend() async {
        guard let store, store.feishuBotConfig.enabled,
              !store.feishuBotConfig.webhooks.isEmpty else { return }

        // 新增：httpAPI 模式下由服务器 scheduler 负责定时发送
        if SyncManager.shared.config.enabled && SyncManager.shared.config.backend == .httpAPI {
            return
        }

        let config = store.feishuBotConfig
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let todayKey = DataStore.dateKey(from: now)
        let isoWeekday = calendar.component(.weekday, from: now)
        // Calendar.weekday: 1=Sun, 2=Mon..7=Sat → ISO: 1=Mon..7=Sun
        let weekday = isoWeekday == 1 ? 7 : isoWeekday - 1

        for scheduleTime in config.sendTimes {
            guard hour == scheduleTime.hour,
                  minute == scheduleTime.minute,
                  scheduleTime.shouldSendOn(weekday: weekday),
                  config.lastSentTimes[scheduleTime.key] != todayKey else { continue }

            let result = await sendReport(store: store)
            if result.success {
                store.feishuBotConfig.lastSentTimes[scheduleTime.key] = todayKey
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                store.feishuBotConfig.lastSentDateTime = fmt.string(from: now)
            }
            break  // 同一轮只发一次，避免多个时间点同分钟重复发
        }
    }

    // MARK: - Send

    /// 手动发送当天报告（不重试，即时反馈）
    func sendNow(store: DataStore) async -> (success: Bool, message: String) {
        // httpAPI 模式优先委托服务器；服务不可用时回退到本地直发
        if SyncManager.shared.config.enabled && SyncManager.shared.config.backend == .httpAPI {
            let serverResult = await self.sendViaServer()
            if serverResult.success { return serverResult }

            let lowered = serverResult.message.lowercased()
            let shouldFallback = serverResult.message.contains("网络错误") ||
                serverResult.message.contains("无效的服务器 URL") ||
                serverResult.message.contains("无效的响应") ||
                lowered.contains("could not connect to the server") ||
                lowered.contains("cannot connect to host") ||
                lowered.contains("network is unreachable") ||
                lowered.contains("timed out")

            if shouldFallback {
                let localResult = await sendDirectNow(store: store)
                if localResult.success {
                    return (true, "服务器不可用，已切换本地直发")
                }
                return (false, "服务器不可用；本地直发也失败：\(localResult.message)")
            }

            return serverResult
        }
        return await sendDirectNow(store: store)
    }

    /// 本地直发飞书，不依赖同步服务器
    func sendDirectNow(store: DataStore) async -> (success: Bool, message: String) {
        guard !store.feishuBotConfig.webhooks.isEmpty else {
            return (false, "Webhook URL 为空")
        }
        let result = await sendReportOnce(store: store)
        addHistory(store: store, success: result.success, message: result.message, retryCount: 0)
        return result
    }

    private func ensureSecretsMigrated(store: DataStore) {
        migrateSecrets(store: store)
    }

    private func sendViaServer() async -> (success: Bool, message: String) {
        let syncConfig = SyncManager.shared.config
        let serverURL = syncConfig.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(serverURL)/api/feishu/send") else {
            return (false, "无效的服务器 URL")
        }

        let webToken = SyncManager.shared.loadWebPortalToken().trimmingCharacters(in: .whitespacesAndNewlines)
        let token = webToken.isEmpty ? SyncManager.shared.loadCredential() : webToken
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "无效的响应")
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let success = json["success"] as? Bool ?? false
                let message = json["message"] as? String ?? "未知响应"

                if http.statusCode == 429 {
                    return (false, message)  // 冷却中
                }

                if success {
                    // 更新本地状态（让 UI 及时反映）
                    if let store = self.store {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                        store.feishuBotConfig.lastSentDateTime = fmt.string(from: Date())
                        addHistory(store: store, success: true, message: "通过服务器发送成功", retryCount: 0)
                    }
                    DevLog.shared.info("FeishuBot", "通过服务器 API 发送成功")
                    return (true, message)
                } else {
                    if let store = self.store {
                        addHistory(store: store, success: false, message: message, retryCount: 0)
                    }
                    return (false, message)
                }
            }
            return (false, "响应解析失败")
        } catch {
            return (false, "网络错误: \(error.localizedDescription)")
        }
    }

    private func sendReport(store: DataStore) async -> (success: Bool, message: String) {
        var retryCount = 0
        var lastError = ""

        while retryCount <= store.feishuBotConfig.maxRetries {
            let result = await sendReportOnce(store: store)

            if result.success {
                addHistory(store: store, success: true, message: result.message, retryCount: retryCount)
                return result
            }

            lastError = result.message

            // 配置错误不重试
            if result.message.contains("URL 无效") || result.message.contains("Secret 未配置") ||
               result.message.contains("JSON 序列化失败") {
                addHistory(store: store, success: false, message: result.message, retryCount: retryCount)
                return result
            }

            retryCount += 1
            if retryCount <= store.feishuBotConfig.maxRetries {
                DevLog.shared.info("FeishuBot", "第 \(retryCount) 次重试...")
                try? await Task.sleep(for: .seconds(5))
            }
        }

        addHistory(store: store, success: false, message: lastError, retryCount: retryCount - 1)
        return (false, "\(lastError)（重试 \(retryCount - 1) 次后失败）")
    }

    private func sendReportOnce(store: DataStore) async -> (success: Bool, message: String) {
        ensureSecretsMigrated(store: store)
        let payload = generateDailyReport(store: store)
        let webhooks = store.feishuBotConfig.webhooks.filter {
            !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard !webhooks.isEmpty else {
            return (false, "Webhook URL 为空")
        }

        var successCount = 0
        var failureMessages: [String] = []

        for webhook in webhooks {
            let trimmedURL = webhook.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmedURL) else {
                DevLog.shared.error("FeishuBot", "Webhook URL 无效: \(trimmedURL)")
                failureMessages.append("无效 URL")
                continue
            }

            var body = payload
            if webhook.signEnabled {
                guard let secret = Self.loadSecret(for: webhook.id), !secret.isEmpty else {
                    DevLog.shared.error("FeishuBot", "签名已启用但 Secret 未配置: \(trimmedURL)")
                    failureMessages.append("Secret 未配置")
                    continue
                }
                let timestamp = String(Int(Date().timeIntervalSince1970))
                let sign = Self.generateSign(timestamp: timestamp, secret: secret)
                body["timestamp"] = timestamp
                body["sign"] = sign
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
                failureMessages.append("JSON 序列化失败")
                continue
            }

            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    failureMessages.append("无效的响应")
                    continue
                }
                guard http.statusCode == 200 else {
                    DevLog.shared.error("FeishuBot", "HTTP \(http.statusCode): \(trimmedURL)")
                    failureMessages.append("HTTP \(http.statusCode)")
                    continue
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let code = json["StatusCode"] as? Int ?? json["code"] as? Int
                    if code == 0 {
                        successCount += 1
                        DevLog.shared.info("FeishuBot", "日报发送成功: \(trimmedURL)")
                        continue
                    }
                    let msg = json["StatusMessage"] as? String ?? json["msg"] as? String ?? "未知错误"
                    DevLog.shared.error("FeishuBot", "飞书返回错误: \(msg) [\(trimmedURL)]")
                    failureMessages.append(msg)
                    continue
                }
                let text = String(data: data, encoding: .utf8) ?? "unknown"
                DevLog.shared.error("FeishuBot", "飞书返回错误: \(text) [\(trimmedURL)]")
                failureMessages.append("响应解析失败")
            } catch {
                DevLog.shared.error("FeishuBot", "发送失败: \(error.localizedDescription) [\(trimmedURL)]")
                failureMessages.append("网络错误: \(error.localizedDescription)")
            }
        }

        if successCount == webhooks.count {
            return (true, successCount == 1 ? "发送成功" : "发送成功（\(successCount) 个地址）")
        }
        if successCount > 0 {
            return (true, "部分发送成功（\(successCount)/\(webhooks.count)）")
        }
        return (false, failureMessages.first ?? "发送失败")
    }

    private func addHistory(store: DataStore, success: Bool, message: String, retryCount: Int) {
        let history = SendHistory(timestamp: Date(), success: success, message: message, retryCount: retryCount)
        store.feishuBotConfig.sendHistory.insert(history, at: 0)
        if store.feishuBotConfig.sendHistory.count > 50 {
            store.feishuBotConfig.sendHistory.removeLast()
        }
    }

    // MARK: - Report Generation

    private func generateDailyReport(store: DataStore) -> [String: Any] {
        switch store.feishuBotConfig.messageFormat {
        case .card:
            return generateCardReport(store: store)
        case .richText:
            return generateRichTextReport(store: store)
        case .customTemplate:
            return generateCustomTemplateReport(store: store)
        }
    }

    // MARK: - Shared Data

    private struct ReportData {
        let todayKey: String
        let newIssues: [TrackedIssue]
        let resolvedToday: [TrackedIssue]
        let pending: [TrackedIssue]
        let scheduled: [TrackedIssue]
        let testing: [TrackedIssue]
        let observing: [TrackedIssue]
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
            pending: allIssues.filter { !$0.status.isResolved && $0.status != .observing && $0.status != .scheduled && $0.status != .testing },
            scheduled: allIssues.filter { $0.status == .scheduled },
            testing: allIssues.filter { $0.status == .testing },
            observing: allIssues.filter { $0.status == .observing },
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
            var statsLine = "🟢 今日新建 \(d.newIssues.count)  ·  ✅ 今日解决 \(d.resolvedToday.count)  ·  🔶 待处理 \(d.pending.count)"
            if !d.observing.isEmpty {
                statsLine += "  ·  👁 观测中 \(d.observing.count)"
            }
            lines.append([
                text(statsLine)
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

        // === 观测中问题 ===
        if d.config.showObserving && !d.observing.isEmpty {
            lines.append([text("👁 观测中问题：")])
            for issue in d.observing {
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

        // === 已排期问题 ===
        if d.config.showScheduled && !d.scheduled.isEmpty {
            lines.append([text("📅 已排期问题：")])
            for issue in d.scheduled {
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

        // === 测试中问题 ===
        if d.config.showTesting && !d.testing.isEmpty {
            lines.append([text("🧪 测试中问题：")])
            for issue in d.testing {
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
                        "title": d.config.cardTitle.isEmpty ? "每日工单报告（\(d.todayKey)）" : "\(d.config.cardTitle)（\(d.todayKey)）",
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

    // MARK: - Custom Template Report

    private func generateCustomTemplateReport(store: DataStore) -> [String: Any] {
        let d = collectReportData(store: store)
        let template = d.config.customTemplate

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"

        let deptStats: String = {
            if d.todayTotal == 0 { return "无" }
            return d.todayRecords.sorted(by: { $0.key < $1.key })
                .map { "\($0.key) \($0.value)次" }
                .joined(separator: "，")
        }()

        let variables: [String: String] = [
            "日期": d.todayKey,
            "今日总数": "\(d.todayTotal)",
            "项目统计": deptStats,
            "新建数量": "\(d.newIssues.count)",
            "解决数量": "\(d.resolvedToday.count)",
            "待处理数量": "\(d.pending.count)",
            "观测中数量": "\(d.observing.count)",
            "已排期数量": "\(d.scheduled.count)",
            "测试中数量": "\(d.testing.count)",
            "待处理列表": formatIssueListMd(d.pending, showStatus: true, config: d.config, jiraServerURL: d.jiraServerURL),
            "已解决列表": formatIssueListMd(d.resolvedToday, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL),
            "观测中列表": formatIssueListMd(d.observing, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL),
            "已排期列表": formatIssueListMd(d.scheduled, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL),
            "测试中列表": formatIssueListMd(d.testing, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL),
            "日报内容": d.dailyNote.isEmpty ? "无" : d.dailyNote,
            "当前时间": timeFmt.string(from: Date()),
        ]

        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        // 按 --- 分隔为多个卡片段落，每段一个 lark_md div，段间加 hr 分隔线
        let sections = result.components(separatedBy: "\n---\n")
        var elements: [[String: Any]] = []
        for (i, section) in sections.enumerated() {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if i > 0 { elements.append(["tag": "hr"]) }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": trimmed]])
        }
        if elements.isEmpty {
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": "（空模板）"]])
        }

        // 底部备注
        elements.append(["tag": "note", "elements": [["tag": "plain_text", "content": "由 TicTracker 自动生成 | \(timeFmt.string(from: Date()))"]]])

        return [
            "msg_type": "interactive",
            "card": [
                "config": ["wide_screen_mode": true],
                "header": ["title": ["tag": "plain_text", "content": d.config.customTemplateTitle.isEmpty ? "每日工单报告" : d.config.customTemplateTitle], "template": "blue"],
                "elements": elements
            ]
        ]
    }

    /// 格式化 issue 列表为 lark_md（用于自定义模板卡片）
    private func formatIssueListMd(_ issues: [TrackedIssue], showStatus: Bool, config: FeishuBotConfig, jiraServerURL: String) -> String {
        if issues.isEmpty { return "无" }
        return issues.map { issue in
            Self.formatIssue(issue, showStatus: showStatus, config: config, jiraServerURL: jiraServerURL)
        }.joined(separator: "\n")
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
            var statsLine = "🟢 **今日新建** \(d.newIssues.count) 个  ·  ✅ **今日解决** \(d.resolvedToday.count) 个  ·  🔶 **待处理** \(d.pending.count) 个"
            if !d.observing.isEmpty {
                statsLine += "  ·  👁 **观测中** \(d.observing.count) 个"
            }
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

        // 观测中问题列表 + 评论
        if d.config.showObserving && !d.observing.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**👁 观测中问题：**"
            for issue in d.observing {
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

        // 已排期问题列表 + 评论
        if d.config.showScheduled && !d.scheduled.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**📅 已排期问题：**"
            for issue in d.scheduled {
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

        // 测试中问题列表 + 评论
        if d.config.showTesting && !d.testing.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**🧪 测试中问题：**"
            for issue in d.testing {
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
            || (d.config.showObserving && !d.observing.isEmpty)
            || (d.config.showScheduled && !d.scheduled.isEmpty)
            || (d.config.showTesting && !d.testing.isEmpty)
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
                "header": ["title": ["tag": "plain_text", "content": d.config.cardTitle.isEmpty ? "每日工单报告" : d.config.cardTitle], "template": "blue"],
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

    static func saveSecret(for webhookID: UUID, secret: String) {
        if let data = secret.data(using: .utf8) {
            KeychainHelper.save(service: keychainService, account: "webhook-secret-\(webhookID.uuidString)", data: data)
        }
    }

    static func loadSecret(for webhookID: UUID) -> String? {
        guard let data = KeychainHelper.load(service: keychainService, account: "webhook-secret-\(webhookID.uuidString)") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func loadSecrets(for webhookIDs: [UUID]) -> [UUID: String] {
        let accounts = KeychainHelper.loadAll(service: keychainService)
        var secrets: [UUID: String] = [:]
        let wanted = Set(webhookIDs)
        for id in wanted {
            let account = "webhook-secret-\(id.uuidString)"
            if let data = accounts[account], let secret = String(data: data, encoding: .utf8) {
                secrets[id] = secret
            }
        }
        return secrets
    }

    static func deleteSecret(for webhookID: UUID) {
        KeychainHelper.delete(service: keychainService, account: "webhook-secret-\(webhookID.uuidString)")
    }

    // 旧全局 secret（仅用于迁移）
    private static func loadLegacySecret() -> String? {
        guard let data = KeychainHelper.load(service: keychainService, account: keychainAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacySecret() {
        KeychainHelper.delete(service: keychainService, account: keychainAccount)
    }
}
