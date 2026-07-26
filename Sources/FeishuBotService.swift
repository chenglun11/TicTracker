import AppKit
import CommonCrypto
import Foundation

@MainActor
final class FeishuBotService {
    static let shared = FeishuBotService()

    private var store: DataStore?
    private var schedulerTask: Task<Void, Never>?
    private var schedulerFailureAt: [String: Date] = [:]
    private var issuePreSyncSentinel: [String: String] = [:]
    private var lastIssuePreSyncAt: Date?
    private var issuePreSyncInProgress = false
    private var cachedTenantToken: TenantTokenBundle?
    private var wakeObserver: NSObjectProtocol?
    private let schedulerFailureCooldown: TimeInterval = 10 * 60
    private let issuePreSyncLeadTime: TimeInterval = 5 * 60
    private let issuePreSyncMinInterval: TimeInterval = 5 * 60

    private struct TenantTokenBundle {
        let token: String
        let expireAt: Date
    }

    private static let keychainService = "com.tictracker.keychain"
    private static let keychainAccount = "webhook-secret"

    func setup(store: DataStore) {
        self.store = store
        observeSystemWake()
    }

    /// 一次性迁移：旧全局 secret → 复制到当前所有 webhook，避免旧签名 key 在设置页丢失。
    private func migrateSecrets(store: DataStore) {
        Self.migrateLegacySecretIfNeeded(for: store.feishuBotConfig.webhooks)
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
        DevLog.shared.info("FeishuBot", "系统唤醒，检查飞书授权与错过的定时发送")
        guard let store else { return }

        Task { [weak self, store] in
            let appID = store.feishuBotConfig.appID
            let appSecret = FeishuBotService.loadAppSecret() ?? ""
            await FeishuOAuthService.shared.refreshIfNeededOnWake(appID: appID, appSecret: appSecret)
            if store.feishuBotConfig.enabled, !store.feishuBotConfig.webhooks.isEmpty {
                await self?.catchUpMissedSends()
            }
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

        await catchUpMissedIssueMonthlyReport(now: now)
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
            let key = scheduleTime.key
            guard scheduleTime.shouldSendOn(weekday: weekday),
                  config.lastSentTimes[scheduleTime.key] != todayKey else { continue }

            await syncIssuesBeforeScheduledSendIfNeeded(
                scheduleTime,
                currentHour: hour,
                currentMinute: minute,
                todayKey: todayKey
            )

            guard isScheduleDue(scheduleTime, currentHour: hour, currentMinute: minute) else { continue }

            if let failedAt = schedulerFailureAt[key],
               now.timeIntervalSince(failedAt) < schedulerFailureCooldown {
                continue
            }

            let result = await sendReport(store: store)
            if result.success {
                store.feishuBotConfig.lastSentTimes[key] = todayKey
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                store.feishuBotConfig.lastSentDateTime = fmt.string(from: now)
                schedulerFailureAt.removeValue(forKey: key)
                DevLog.shared.info("FeishuBot", "定时发送成功 [slot=\(key)]")
            } else {
                schedulerFailureAt[key] = now
                DevLog.shared.error("FeishuBot", "定时发送失败，\(Int(schedulerFailureCooldown / 60)) 分钟后重试 [slot=\(key)]: \(result.message)")
            }
            break  // 同一轮只处理一次，避免多个补发时间点连续发送
        }

        await checkAndSendIssueMonthlyReport(now: now)
    }

    private func isScheduleDue(_ scheduleTime: ScheduleTime, currentHour: Int, currentMinute: Int) -> Bool {
        let current = currentHour * 60 + currentMinute
        let scheduled = scheduleTime.hour * 60 + scheduleTime.minute
        return current >= scheduled
    }

    private func checkAndSendIssueMonthlyReport(now: Date) async {
        guard let store, store.feishuBotConfig.enabled else { return }
        guard let monthKey = issueMonthlyReportDueMonth(now: now, config: store.feishuBotConfig) else { return }
        guard store.feishuBotConfig.issueMonthlyReportLastSentMonth != monthKey else { return }

        let failureKey = "issue-monthly:\(monthKey)"
        if let failedAt = schedulerFailureAt[failureKey],
           now.timeIntervalSince(failedAt) < schedulerFailureCooldown {
            return
        }

        let result = await sendIssueTrackingReportDirect(store: store, period: .previousMonth, scheduledMonthKey: monthKey)
        if result.success {
            store.feishuBotConfig.issueMonthlyReportLastSentMonth = monthKey
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            store.feishuBotConfig.lastSentDateTime = fmt.string(from: now)
            schedulerFailureAt.removeValue(forKey: failureKey)
            DevLog.shared.info("FeishuBot", "问题月报定时发送成功 [month=\(monthKey)]")
        } else {
            schedulerFailureAt[failureKey] = now
            DevLog.shared.error("FeishuBot", "问题月报定时发送失败 [month=\(monthKey)]: \(result.message)")
        }
    }

    private func catchUpMissedIssueMonthlyReport(now: Date) async {
        guard let store, store.feishuBotConfig.enabled else { return }
        guard let monthKey = issueMonthlyReportDueMonth(now: now, config: store.feishuBotConfig) else { return }
        guard store.feishuBotConfig.issueMonthlyReportLastSentMonth != monthKey else { return }
        DevLog.shared.info("FeishuBot", "补发错过的问题月报 [month=\(monthKey)]")
        let result = await sendIssueTrackingReportDirect(store: store, period: .previousMonth, scheduledMonthKey: monthKey)
        if result.success {
            store.feishuBotConfig.issueMonthlyReportLastSentMonth = monthKey
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            store.feishuBotConfig.lastSentDateTime = fmt.string(from: now)
            DevLog.shared.info("FeishuBot", "补发问题月报成功 [month=\(monthKey)]")
        } else {
            DevLog.shared.error("FeishuBot", "补发问题月报失败 [month=\(monthKey)]: \(result.message)")
        }
    }

    private func issueMonthlyReportDueMonth(now: Date, config: FeishuBotConfig) -> String? {
        guard config.issueMonthlyReportEnabled else { return nil }
        let calendar = Calendar.current
        let dayCount = calendar.range(of: .day, in: .month, for: now)?.count ?? 31
        let sendDay = min(max(config.issueMonthlyReportDay, 1), dayCount)
        let day = calendar.component(.day, from: now)
        let minuteOfDay = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let scheduledMinute = config.issueMonthlyReportHour * 60 + config.issueMonthlyReportMinute
        guard day > sendDay || (day == sendDay && minuteOfDay >= scheduledMinute) else { return nil }
        guard let targetMonthDate = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        return fmt.string(from: targetMonthDate)
    }

    private func syncIssuesBeforeScheduledSendIfNeeded(
        _ scheduleTime: ScheduleTime,
        currentHour: Int,
        currentMinute: Int,
        todayKey: String
    ) async {
        let currentSeconds = (currentHour * 60 + currentMinute) * 60
        let scheduledSeconds = (scheduleTime.hour * 60 + scheduleTime.minute) * 60
        let secondsUntilSend = scheduledSeconds - currentSeconds
        guard secondsUntilSend >= 0,
              TimeInterval(secondsUntilSend) <= issuePreSyncLeadTime else { return }

        let sentinelKey = "\(todayKey):\(scheduleTime.key)"
        guard issuePreSyncSentinel[sentinelKey] != todayKey else { return }
        issuePreSyncSentinel[sentinelKey] = todayKey
        await syncIssueSourcesBeforeReport(reason: "飞书定时发送前 \(Int(issuePreSyncLeadTime / 60)) 分钟同步", force: false)
    }

    private func syncIssueSourcesBeforeReport(reason: String, force: Bool) async {
        guard let store else { return }
        if issuePreSyncInProgress {
            guard force else {
                DevLog.shared.info("FeishuBot", "\(reason)：已有问题同步正在进行，跳过")
                return
            }
            DevLog.shared.info("FeishuBot", "\(reason)：已有问题同步正在进行，等待完成")
            while issuePreSyncInProgress {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if !force,
           let lastIssuePreSyncAt,
           Date().timeIntervalSince(lastIssuePreSyncAt) < issuePreSyncMinInterval {
            DevLog.shared.info("FeishuBot", "\(reason)：距离上次同步不足 \(Int(issuePreSyncMinInterval / 60)) 分钟，跳过")
            return
        }

        issuePreSyncInProgress = true
        defer {
            issuePreSyncInProgress = false
            lastIssuePreSyncAt = Date()
        }

        DevLog.shared.info("FeishuBot", "\(reason)：开始同步问题反馈")

        if canSyncFeishuTasks(store: store) {
            await syncFeishuIssueTasksBeforeReport(store: store)
        }
        if store.jiraConfig.enabled {
            _ = await JiraService.shared.fetchByMode()
            await JiraService.shared.syncTrackedIssues()
        }
        if store.linearConfig.enabled {
            await LinearService.shared.syncTrackedIssues()
        }

        DevLog.shared.info("FeishuBot", "\(reason)：问题反馈同步完成")
    }

    private func canSyncFeishuTasks(store: DataStore) -> Bool {
        guard store.issueSourceFeishuTaskEnabled else { return false }
        switch store.feishuBotConfig.taskAuthMode {
        case .botTenant:
            return !store.feishuBotConfig.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Self.loadAppSecret()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .userOAuth:
            return FeishuOAuthService.shared.isAuthorized
        }
    }

    private func syncFeishuIssueTasksBeforeReport(store: DataStore) async {
        let boundGUIDs = store.trackedIssues.compactMap { issue -> String? in
            guard let guid = issue.feishuTaskGuid, !guid.isEmpty else { return nil }
            return guid
        }

        do {
            let boundResult = try await FeishuTaskService.shared.syncBoundTasks(store: store, boundGUIDs: boundGUIDs)
            for guid in boundResult.deletedGUIDs {
                if let issue = store.trackedIssues.first(where: { $0.feishuTaskGuid == guid }) {
                    store.markIssueFeishuTaskDeleted(id: issue.id, guid: guid)
                }
            }
            for (guid, task) in boundResult.tasks {
                if let issue = store.trackedIssues.first(where: { $0.feishuTaskGuid == guid }) {
                    store.updateIssueFeishuTaskBinding(id: issue.id, task: task)
                    applyFeishuTaskCompletionStatus(store: store, issueID: issue.id, candidate: task)
                    applyFeishuTaskAssignee(store: store, issueID: issue.id, candidate: task)
                }
            }

            let tasklistResult = try await FeishuTaskService.shared.listTasks(store: store)
            var importedCount = 0
            for task in tasklistResult.tasks {
                if store.addIssueFromFeishuTask(task, forKey: store.todayKey) {
                    importedCount += 1
                }
            }
            DevLog.shared.info("FeishuBot", "飞书任务预同步完成：新增 \(importedCount) 个本地问题")
        } catch {
            DevLog.shared.error("FeishuBot", "飞书任务预同步失败：\(error.localizedDescription)")
        }
    }

    private func applyFeishuTaskCompletionStatus(store: DataStore, issueID: UUID, candidate: FeishuTaskCandidate) {
        let isCompleted = (candidate.completedAt ?? "").trimmingCharacters(in: .whitespaces).isEmpty == false
            && candidate.completedAt != "0"
        if isCompleted {
            store.updateIssueStatus(id: issueID, status: .fixed)
        } else if let issue = store.trackedIssues.first(where: { $0.id == issueID }), issue.status.isResolved {
            store.updateIssueStatus(id: issueID, status: .pending)
        }
    }

    private func applyFeishuTaskAssignee(store: DataStore, issueID: UUID, candidate: FeishuTaskCandidate) {
        guard let assignee = store.assigneeText(fromFeishuTask: candidate),
              let issue = store.trackedIssues.first(where: { $0.id == issueID }) else { return }
        let boundGUID = issue.feishuTaskGuid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard boundGUID == candidate.guid || issue.source == .feishu else { return }
        guard issue.assignee != assignee else { return }
        store.updateIssueAssigneeLocally(id: issueID, assignee: assignee)
    }

    // MARK: - Send

    /// 手动发送当天报告（不重试，即时反馈）
    func sendNow(store: DataStore) async -> (success: Bool, message: String) {
        // httpAPI 模式优先委托服务器；服务不可用时回退到本地直发
        if SyncManager.shared.config.enabled && SyncManager.shared.config.backend == .httpAPI {
            await syncIssueSourcesBeforeReport(reason: "飞书服务端发送前同步", force: true)
            guard await syncDataToServerBeforeSendIfNeeded(store: store, reason: "飞书服务端发送前上传") else {
                let localResult = await sendDirectNow(store: store)
                if localResult.success {
                    return (true, "服务器同步失败，已切换本地直发")
                }
                return (false, "服务器同步失败；本地直发也失败：\(localResult.message)")
            }
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

    /// 手动发送问题追踪月报；HTTP API 模式优先委托服务器。
    func sendIssueTrackingReportNow(store: DataStore, period: WeeklyReport.Period = .currentMonth) async -> (success: Bool, message: String) {
        if SyncManager.shared.config.enabled && SyncManager.shared.config.backend == .httpAPI {
            await syncIssueSourcesBeforeReport(reason: "问题月报服务端发送前同步", force: true)
            guard await syncDataToServerBeforeSendIfNeeded(store: store, reason: "问题月报服务端发送前上传") else {
                let localResult = await sendIssueTrackingReportDirect(store: store, period: period)
                if localResult.success {
                    return (true, "服务器同步失败，已切换本地直发问题月报")
                }
                return (false, "服务器同步失败；本地直发也失败：\(localResult.message)")
            }
            let serverResult = await sendIssueTrackingReportViaServer(period: period)
            if serverResult.success { return serverResult }

            if shouldFallbackToLocalSend(message: serverResult.message) {
                let localResult = await sendIssueTrackingReportDirect(store: store, period: period)
                if localResult.success {
                    return (true, "服务器不可用，已切换本地直发问题月报")
                }
                return (false, "服务器不可用；本地直发也失败：\(localResult.message)")
            }
            return serverResult
        }
        return await sendIssueTrackingReportDirect(store: store, period: period)
    }

    /// 本地直发飞书，不依赖同步服务器
    func sendDirectNow(store: DataStore) async -> (success: Bool, message: String) {
        guard !store.feishuBotConfig.webhooks.isEmpty else {
            return (false, "Webhook URL 为空")
        }
        await syncIssueSourcesBeforeReport(reason: "飞书发送前同步", force: true)
        let result = await sendReportOnce(store: store)
        addHistory(store: store, success: result.success, message: result.message, retryCount: 0)
        return result
    }

    private func shouldFallbackToLocalSend(message: String) -> Bool {
        let lowered = message.lowercased()
        return message.contains("网络错误") ||
            message.contains("无效的服务器 URL") ||
            message.contains("无效的响应") ||
            lowered.contains("could not connect to the server") ||
            lowered.contains("cannot connect to host") ||
            lowered.contains("network is unreachable") ||
            lowered.contains("timed out")
    }

    private func ensureSecretsMigrated(store: DataStore) {
        migrateSecrets(store: store)
    }

    private func sendViaServer() async -> (success: Bool, message: String) {
        let syncConfig = SyncManager.shared.config
        let serverURL = syncConfig.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(serverURL)/api/feishu/send") else {
            DevLog.shared.error("FeishuBot", "服务端发送失败：无效的服务器 URL [raw=\(syncConfig.serverURL)]")
            return (false, "无效的服务器 URL")
        }

        let webToken = SyncManager.shared.loadWebPortalToken().trimmingCharacters(in: .whitespacesAndNewlines)
        let token = webToken.isEmpty ? SyncManager.shared.loadCredential() : webToken
        let tokenSource = webToken.isEmpty ? "sync-token" : "web-token"
        let maskedToken: String = {
            guard !token.isEmpty else { return "<empty>" }
            if token.count <= 8 { return String(repeating: "*", count: token.count) }
            return "\(token.prefix(4))...\(token.suffix(4))"
        }()

        DevLog.shared.info(
            "FeishuBot",
            "准备通过服务器发送日报 [backend=\(syncConfig.backend.rawValue), url=\(url.absoluteString), tokenSource=\(tokenSource), token=\(maskedToken)]"
        )

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                DevLog.shared.error("FeishuBot", "服务端发送失败：无效的响应对象 [url=\(url.absoluteString)]")
                return (false, "无效的响应")
            }

            let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            DevLog.shared.info(
                "FeishuBot",
                "服务端发送响应 [status=\(http.statusCode), url=\(url.absoluteString), body=\(responseText.prefix(300))]"
            )

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let success = json["success"] as? Bool ?? false
                let message = json["message"] as? String ?? "未知响应"

                if http.statusCode == 429 {
                    DevLog.shared.error("FeishuBot", "服务端发送被限流：\(message)")
                    return (false, message)
                }

                if success {
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
                    DevLog.shared.error("FeishuBot", "服务端发送返回失败：\(message) [status=\(http.statusCode)]")
                    return (false, message)
                }
            }
            DevLog.shared.error("FeishuBot", "服务端发送失败：响应解析失败 [status=\(http.statusCode), body=\(responseText.prefix(300))]")
            return (false, "响应解析失败")
        } catch {
            let nsError = error as NSError
            DevLog.shared.error(
                "FeishuBot",
                "服务端发送网络错误 [url=\(url.absoluteString), domain=\(nsError.domain), code=\(nsError.code), desc=\(nsError.localizedDescription)]"
            )
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] {
                DevLog.shared.error("FeishuBot", "底层错误: \(underlying)")
            }
            return (false, "网络错误: \(error.localizedDescription)")
        }
    }

    private func sendIssueTrackingReportViaServer(period: WeeklyReport.Period) async -> (success: Bool, message: String) {
        let syncConfig = SyncManager.shared.config
        let serverURL = syncConfig.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let periodValue = (period == .previousMonth || period == .previousWeek) ? "previous" : "current"
        guard let url = URL(string: "\(serverURL)/api/feishu/send/issue-monthly?period=\(periodValue)") else {
            DevLog.shared.error("FeishuBot", "服务端问题月报发送失败：无效的服务器 URL [raw=\(syncConfig.serverURL)]")
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
            let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            DevLog.shared.info("FeishuBot", "服务端问题月报发送响应 [status=\(http.statusCode), body=\(responseText.prefix(300))]")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let success = json["success"] as? Bool ?? false
                let message = json["message"] as? String ?? "未知响应"
                if success {
                    if let store = self.store {
                        addHistory(store: store, success: true, message: "通过服务器发送问题月报成功", retryCount: 0)
                    }
                    return (true, message)
                }
                return (false, message)
            }
            return (false, "响应解析失败")
        } catch {
            DevLog.shared.error("FeishuBot", "服务端问题月报发送网络错误：\(error.localizedDescription)")
            return (false, "网络错误: \(error.localizedDescription)")
        }
    }

    private func sendReport(store: DataStore) async -> (success: Bool, message: String) {
        await syncIssueSourcesBeforeReport(reason: "飞书定时发送前兜底同步", force: true)

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
        var payload = generateDailyReport(store: store)
        if let imageKey = await uploadReportImageIfNeeded(store: store) {
            attachReportImage(imageKey: imageKey, to: &payload)
        }
        return await sendPayloadToEnabledWebhooks(payload, store: store, successLabel: "日报")
    }

    private func sendIssueTrackingReportDirect(store: DataStore, period: WeeklyReport.Period, scheduledMonthKey: String? = nil) async -> (success: Bool, message: String) {
        guard !store.feishuBotConfig.webhooks.isEmpty else {
            return (false, "Webhook URL 为空")
        }
        ensureSecretsMigrated(store: store)
        await syncIssueSourcesBeforeReport(reason: "问题月报发送前同步", force: true)
        var payload = generateIssueTrackingCardReport(store: store, period: period)
        if let imageKey = await uploadIssueTrackingReportImageIfNeeded(store: store, period: period) {
            attachReportImage(imageKey: imageKey, to: &payload)
        }
        let result = await sendPayloadToEnabledWebhooks(payload, store: store, successLabel: "问题月报")
        addHistory(store: store, success: result.success, message: result.message, retryCount: 0)
        if result.success, let scheduledMonthKey {
            store.feishuBotConfig.issueMonthlyReportLastSentMonth = scheduledMonthKey
        }
        return result
    }

    private func syncDataToServerBeforeSendIfNeeded(store: DataStore, reason: String) async -> Bool {
        guard SyncManager.shared.config.enabled,
              SyncManager.shared.config.backend == .httpAPI else { return true }
        DevLog.shared.info("FeishuBot", "\(reason)：开始同步本地数据到服务器")
        do {
            try await SyncManager.shared.uploadCurrentSnapshot(store: store)
            DevLog.shared.info("FeishuBot", "\(reason)：本地数据同步完成")
            return true
        } catch {
            DevLog.shared.error("FeishuBot", "\(reason)：同步失败，停止服务端发送：\(error.localizedDescription)")
            return false
        }
    }

    private func sendPayloadToEnabledWebhooks(_ payload: [String: Any], store: DataStore, successLabel: String) async -> (success: Bool, message: String) {
        let webhooks = store.feishuBotConfig.webhooks.filter {
            $0.enabled && !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard !webhooks.isEmpty else {
            return (false, "没有启用的 Webhook")
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
                        DevLog.shared.info("FeishuBot", "\(successLabel)发送成功: \(trimmedURL)")
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
            return (true, successCount == 1 ? "\(successLabel)发送成功" : "\(successLabel)发送成功（\(successCount) 个地址）")
        }
        if successCount > 0 {
            return (true, "\(successLabel)部分发送成功（\(successCount)/\(webhooks.count)）")
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

    private func uploadReportImageIfNeeded(store: DataStore) async -> String? {
        guard store.feishuBotConfig.includeVisualReportImage else { return nil }
        guard store.feishuBotConfig.messageFormat != .richText else { return nil }
        guard let pngData = ReportVisualRenderer.pngData(for: ReportVisualRenderer.renderDailyReport(store: store)) else {
            DevLog.shared.warn("FeishuBot", "可视化报表图生成失败，跳过附图")
            return nil
        }

        do {
            let token = try await tenantAccessToken(store: store)
            return try await uploadImage(pngData, tenantAccessToken: token)
        } catch {
            DevLog.shared.warn("FeishuBot", "可视化报表图上传失败，跳过附图：\(error.localizedDescription)")
            return nil
        }
    }

    private func uploadIssueTrackingReportImageIfNeeded(store: DataStore, period: WeeklyReport.Period) async -> String? {
        guard store.feishuBotConfig.issueMonthlyReportIncludeImage else { return nil }
        guard let pngData = await ReportVisualRenderer.issueTrackingPNGData(store: store, period: period) else {
            DevLog.shared.warn("FeishuBot", "问题月报图生成失败，跳过附图")
            return nil
        }

        do {
            let token = try await tenantAccessToken(store: store)
            return try await uploadImage(pngData, tenantAccessToken: token)
        } catch {
            DevLog.shared.warn("FeishuBot", "问题月报图上传失败，跳过附图：\(error.localizedDescription)")
            return nil
        }
    }

    private func attachReportImage(imageKey: String, to payload: inout [String: Any]) {
        guard payload["msg_type"] as? String == "interactive",
              var card = payload["card"] as? [String: Any],
              var elements = card["elements"] as? [[String: Any]]
        else { return }

        let imageElement: [String: Any] = [
            "tag": "img",
            "img_key": imageKey,
            "alt": ["tag": "plain_text", "content": "可视化报表"],
            "mode": "fit_horizontal"
        ]
        let insertIndex = min(1, elements.count)
        elements.insert(["tag": "hr"], at: insertIndex)
        elements.insert(imageElement, at: insertIndex + 1)
        card["elements"] = elements
        payload["card"] = card
    }

    private func tenantAccessToken(store: DataStore) async throws -> String {
        let now = Date()
        if let cachedTenantToken, cachedTenantToken.expireAt.timeIntervalSince(now) > 300 {
            return cachedTenantToken.token
        }

        let appID = store.feishuBotConfig.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = Self.loadAppSecret()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appID.isEmpty, !appSecret.isEmpty else {
            throw NSError(domain: "FeishuBot", code: 1, userInfo: [NSLocalizedDescriptionKey: "App ID 或 App Secret 缺失"])
        }
        guard let url = URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal") else {
            throw NSError(domain: "FeishuBot", code: 2, userInfo: [NSLocalizedDescriptionKey: "tenant token URL 无效"])
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "app_id": appID,
            "app_secret": appSecret
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        guard status == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (payload["code"] as? Int ?? 0) == 0,
              let token = payload["tenant_access_token"] as? String,
              !token.isEmpty
        else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String ?? body
            throw NSError(domain: "FeishuBot", code: status, userInfo: [NSLocalizedDescriptionKey: "获取 tenant_access_token 失败：\(message.prefix(200))"])
        }

        let expire = (payload["expire"] as? NSNumber)?.doubleValue ?? 7200
        cachedTenantToken = TenantTokenBundle(token: token, expireAt: now.addingTimeInterval(expire))
        return token
    }

    private func uploadImage(_ data: Data, tenantAccessToken: String) async throws -> String {
        guard let url = URL(string: "https://open.feishu.cn/open-apis/im/v1/images") else {
            throw NSError(domain: "FeishuBot", code: 3, userInfo: [NSLocalizedDescriptionKey: "图片上传 URL 无效"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image_type\"\r\n\r\n")
        append("message\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"report.png\"\r\n")
        append("Content-Type: image/png\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(tenantAccessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let rawBody = String(data: responseData, encoding: .utf8) ?? "<non-utf8>"
        guard status == 200,
              let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              (payload["code"] as? Int ?? 0) == 0,
              let data = payload["data"] as? [String: Any],
              let imageKey = data["image_key"] as? String,
              !imageKey.isEmpty
        else {
            let message = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?["msg"] as? String ?? rawBody
            throw NSError(domain: "FeishuBot", code: status, userInfo: [NSLocalizedDescriptionKey: "图片上传失败：\(message.prefix(200))"])
        }
        DevLog.shared.info("FeishuBot", "可视化报表图已上传")
        return imageKey
    }

    // MARK: - Shared Data

    private struct ReportData {
        let todayKey: String
        let newIssues: [TrackedIssue]
        let resolvedToday: [TrackedIssue]
        let pending: [TrackedIssue]
        let inProgress: [TrackedIssue]
        let scheduled: [TrackedIssue]
        let testing: [TrackedIssue]
        let observing: [TrackedIssue]
        let myReportedToday: [TrackedIssue]
        let focusTagged: [TrackedIssue]
        let focusTag: String
        let todayRecords: [String: Int]
        let todayTotal: Int
        let dailyNote: String
        let config: FeishuBotConfig
        let jiraServerURL: String
    }

    private struct IssueMonthlyReportData {
        let title: String
        let subtitle: String
        let comparisonSubtitle: String
        let issues: [TrackedIssue]
        let openIssues: [TrackedIssue]
        let resolvedIssues: [TrackedIssue]
        let createdTotal: Int
        let updatedTotal: Int
        let resolvedTotal: Int
        let previousCreatedTotal: Int
        let previousResolvedTotal: Int
        let previousOpenTotal: Int
        let previousStaleTotal: Int
        let closureRate: Int
        let previousClosureRate: Int
        let staleOpenIssues: [TrackedIssue]
        let unassignedOpenIssues: [TrackedIssue]
        let typeTotals: [(String, Int)]
        let statusTotals: [(String, Int)]
        let assigneeTotals: [(String, Int)]
        let analysisNotes: [String]
    }

    private func collectReportData(store: DataStore) -> ReportData {
        let config = store.feishuBotConfig
        let todayKey = store.todayKey
        let allIssues = store.issuesVisibleForKey(todayKey)
        let focusTag = config.focusIssueTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReportData(
            todayKey: todayKey,
            newIssues: allIssues.filter { $0.dateKey == todayKey && !$0.isEffectivelyResolved },
            resolvedToday: allIssues.filter { issue in
                guard issue.isEffectivelyResolved, let resolvedAt = issue.resolvedAt else { return false }
                return DataStore.dateKey(from: resolvedAt) == todayKey
            },
            pending: allIssues.filter { !$0.isEffectivelyResolved && $0.effectiveStatus != .observing && $0.effectiveStatus != .scheduled && $0.effectiveStatus != .testing && $0.effectiveStatus != .inProgress },
            inProgress: allIssues.filter { $0.effectiveStatus == .inProgress },
            scheduled: allIssues.filter { $0.effectiveStatus == .scheduled },
            testing: allIssues.filter { $0.effectiveStatus == .testing },
            observing: allIssues.filter { $0.effectiveStatus == .observing },
            myReportedToday: [],
            focusTagged: focusTag.isEmpty ? [] : allIssues.filter { $0.issueTags.contains(focusTag) },
            focusTag: focusTag,
            todayRecords: store.todayRecords,
            todayTotal: store.todayTotal,
            dailyNote: store.dailyNotes[todayKey] ?? "",
            config: config,
            jiraServerURL: store.jiraConfig.serverURL
        )
    }

    private func collectIssueMonthlyReportData(store: DataStore, period: WeeklyReport.Period) -> IssueMonthlyReportData {
        let calendar = Calendar.current
        let (start, end) = WeeklyReport.dateRange(for: period)
        let keyFmt = DateFormatter()
        keyFmt.dateFormat = "yyyy-MM-dd"
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "M/d"

        func dateKey(from date: Date) -> String {
            keyFmt.string(from: date)
        }

        func primaryDate(_ issue: TrackedIssue) -> Date {
            issue.reportedAt ?? issue.createdAt
        }

        func primaryCreatedKey(_ issue: TrackedIssue) -> String {
            dateKey(from: primaryDate(issue))
        }

        func isReportUpdateComment(_ comment: IssueComment) -> Bool {
            let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            if text.hasPrefix("[Linear] 已导入") || text.hasPrefix("[Linear] 已通过链接导入") {
                return false
            }
            return true
        }

        func hasReportUpdateActivity(_ issue: TrackedIssue, startKey: String, endKey: String) -> Bool {
            let createdKey = primaryCreatedKey(issue)
            let resolvedKey = issue.resolvedAt.map { dateKey(from: $0) }
            return issue.comments.contains { comment in
                guard isReportUpdateComment(comment) else { return false }
                let key = dateKey(from: comment.createdAt)
                guard key >= startKey && key <= endKey else { return false }
                guard key != createdKey else { return false }
                guard key != resolvedKey else { return false }
                return true
            }
        }

        func normalizedAssignee(_ issue: TrackedIssue) -> String {
            if let assignee = issue.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
                return assignee
            }
            if let assignee = issue.linearAssignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
                return assignee
            }
            return "未分配"
        }

        struct PeriodStats {
            let start: Date
            let end: Date
            let issues: [TrackedIssue]
            let openIssues: [TrackedIssue]
            let resolvedIssues: [TrackedIssue]
            let updatedIssues: [TrackedIssue]
            let staleOpenIssues: [TrackedIssue]
            let unassignedOpenIssues: [TrackedIssue]
            let typeTotals: [(String, Int)]
            let statusTotals: [(String, Int)]
            let assigneeTotals: [(String, Int)]
            let closureRate: Int
        }

        func periodStats(start: Date, end: Date) -> PeriodStats {
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: end)!
            let startKey = keyFmt.string(from: start)
            let endKey = keyFmt.string(from: end)
            let issues = store.visibleTrackedIssues
                .filter { issue in
                    let date = primaryDate(issue)
                    return date >= start && date < endExclusive
                }
                .sorted {
                    if $0.isEffectivelyResolved != $1.isEffectivelyResolved { return !$0.isEffectivelyResolved }
                    if $0.effectiveStatus != $1.effectiveStatus { return Self.issueStatusRank($0.effectiveStatus) < Self.issueStatusRank($1.effectiveStatus) }
                    return primaryDate($0) > primaryDate($1)
                }

            let allOpenBeforePeriodEnd = store.visibleTrackedIssues
                .filter { issue in
                    guard !issue.isEffectivelyResolved else { return false }
                    return primaryDate(issue) < endExclusive
                }
                .sorted {
                    if $0.isEscalated != $1.isEscalated { return $0.isEscalated }
                    if $0.effectiveStatus != $1.effectiveStatus { return Self.issueStatusRank($0.effectiveStatus) < Self.issueStatusRank($1.effectiveStatus) }
                    return primaryDate($0) < primaryDate($1)
                }

            let updatedIssues = issues.filter { hasReportUpdateActivity($0, startKey: startKey, endKey: endKey) }
            let referenceDate = min(Date(), endExclusive)
            let staleThreshold = calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
            let staleOpenIssues = allOpenBeforePeriodEnd
                .filter { $0.effectiveStatus != .observing && primaryDate($0) < staleThreshold }
                .sorted { primaryDate($0) < primaryDate($1) }
            let unassignedOpenIssues = allOpenBeforePeriodEnd.filter { normalizedAssignee($0) == "未分配" }

            let typeTotals = IssueType.allCases.compactMap { type -> (String, Int)? in
                let count = issues.filter { $0.type == type }.count
                return count > 0 ? (type.rawValue, count) : nil
            }
            let statusTotals = IssueStatus.allCases.compactMap { status -> (String, Int)? in
                let count = issues.filter { $0.effectiveStatus == status }.count
                return count > 0 ? (status.rawValue, count) : nil
            }
            var assigneeCounts: [String: Int] = [:]
            for issue in issues {
                assigneeCounts[normalizedAssignee(issue), default: 0] += 1
            }
            let assigneeTotals = assigneeCounts
                .map { ($0.key, $0.value) }
                .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            let resolvedIssues = issues.filter(\.isEffectivelyResolved)
            let closureRate = issues.isEmpty ? 0 : Int((Double(resolvedIssues.count) / Double(issues.count) * 100).rounded())

            return PeriodStats(
                start: start,
                end: end,
                issues: issues,
                openIssues: allOpenBeforePeriodEnd,
                resolvedIssues: resolvedIssues,
                updatedIssues: updatedIssues,
                staleOpenIssues: staleOpenIssues,
                unassignedOpenIssues: unassignedOpenIssues,
                typeTotals: typeTotals,
                statusTotals: statusTotals,
                assigneeTotals: assigneeTotals,
                closureRate: closureRate
            )
        }

        let previousEnd = calendar.date(byAdding: .day, value: -1, to: start)!
        let previousStart = calendar.date(from: calendar.dateComponents([.year, .month], from: previousEnd))!
        let current = periodStats(start: start, end: end)
        let previous = periodStats(start: previousStart, end: previousEnd)

        func deltaText(_ current: Int, _ previous: Int) -> String {
            let delta = current - previous
            if delta > 0 { return "+\(delta)" }
            if delta < 0 { return "\(delta)" }
            return "持平"
        }

        func deltaPP(_ current: Int, _ previous: Int) -> String {
            let delta = current - previous
            if delta > 0 { return "+\(delta)pp" }
            if delta < 0 { return "\(delta)pp" }
            return "持平"
        }

        var analysisNotes: [String] = []
        let net = current.issues.count - current.resolvedIssues.count
        analysisNotes.append("较上月：新增 \(deltaText(current.issues.count, previous.issues.count))，已关闭 \(deltaText(current.resolvedIssues.count, previous.resolvedIssues.count))，未关闭 \(deltaText(current.openIssues.count, previous.openIssues.count))，积压 \(deltaText(current.staleOpenIssues.count, previous.staleOpenIssues.count))。")
        analysisNotes.append("本期新增 \(current.issues.count) 个，已关闭 \(current.resolvedIssues.count) 个，关闭率 \(current.closureRate)%（较上月 \(deltaPP(current.closureRate, previous.closureRate))）。")
        if net > 0 {
            analysisNotes.append("月末未关闭 \(current.openIssues.count) 个，净增加 \(net) 个，积压压力上升。")
        } else if net < 0 {
            analysisNotes.append("月末未关闭 \(current.openIssues.count) 个，净减少 \(abs(net)) 个，问题消化速度较好。")
        } else {
            analysisNotes.append("新增与关闭持平，月末未关闭 \(current.openIssues.count) 个。")
        }
        if let topType = current.typeTotals.max(by: { $0.1 < $1.1 }) {
            analysisNotes.append("\(topType.0) 是本期最高频类型，占 \(shareText(topType.1, total: current.issues.count))。")
        }
        if let topAssignee = current.assigneeTotals.first, topAssignee.0 != "未分配" {
            analysisNotes.append("\(topAssignee.0) 承接最多问题，共 \(topAssignee.1) 个。")
        }
        if current.staleOpenIssues.count > 0 {
            analysisNotes.append("\(current.staleOpenIssues.count) 个未关闭问题已超过 7 天，建议优先复盘。")
        }
        if current.unassignedOpenIssues.count > 0 {
            analysisNotes.append("\(current.unassignedOpenIssues.count) 个未关闭问题未分配负责人。")
        }

        return IssueMonthlyReportData(
            title: "问题追踪\(period.reportName)",
            subtitle: "\(displayFmt.string(from: start)) - \(displayFmt.string(from: end))",
            comparisonSubtitle: "\(displayFmt.string(from: previousStart)) - \(displayFmt.string(from: previousEnd))",
            issues: current.issues,
            openIssues: current.openIssues,
            resolvedIssues: current.resolvedIssues,
            createdTotal: current.issues.count,
            updatedTotal: current.updatedIssues.count,
            resolvedTotal: current.resolvedIssues.count,
            previousCreatedTotal: previous.issues.count,
            previousResolvedTotal: previous.resolvedIssues.count,
            previousOpenTotal: previous.openIssues.count,
            previousStaleTotal: previous.staleOpenIssues.count,
            closureRate: current.closureRate,
            previousClosureRate: previous.closureRate,
            staleOpenIssues: current.staleOpenIssues,
            unassignedOpenIssues: current.unassignedOpenIssues,
            typeTotals: current.typeTotals,
            statusTotals: current.statusTotals,
            assigneeTotals: current.assigneeTotals,
            analysisNotes: analysisNotes
        )
    }

    private func generateIssueTrackingCardReport(store: DataStore, period: WeeklyReport.Period) -> [String: Any] {
        let d = collectIssueMonthlyReportData(store: store, period: period)
        let cfg = store.feishuBotConfig
        var elements: [[String: Any]] = []

        elements.append([
            "tag": "div",
            "text": ["tag": "lark_md", "content": "**周期：** \(d.subtitle)\n**对比上月：** \(d.comparisonSubtitle)"]
        ])
        elements.append(["tag": "hr"])
        elements.append([
            "tag": "div",
            "text": [
                "tag": "lark_md",
                "content": "🟦 **本期新增** \(d.createdTotal) 个（上月 \(d.previousCreatedTotal)）  ·  ✅ **已关闭** \(d.resolvedTotal) 个（上月 \(d.previousResolvedTotal)）\n🔶 **未关闭** \(d.openIssues.count) 个（上月 \(d.previousOpenTotal)）  ·  🟣 **积压** \(d.staleOpenIssues.count) 个（上月 \(d.previousStaleTotal)）  ·  🟢 **更新** \(d.updatedTotal) 个"
            ]
        ])

        if !d.analysisNotes.isEmpty {
            elements.append(["tag": "hr"])
            elements.append([
                "tag": "div",
                "text": ["tag": "lark_md", "content": "**分析摘要：**\n" + d.analysisNotes.map { "- \($0)" }.joined(separator: "\n")]
            ])
        }

        let distributionLines = [
            ("类型分布", compactPairs(d.typeTotals)),
            ("状态分布", compactPairs(d.statusTotals)),
            ("负责人 Top 8", compactPairs(Array(d.assigneeTotals.prefix(8))))
        ].filter { !$0.1.isEmpty }
        if !distributionLines.isEmpty {
            elements.append(["tag": "hr"])
            let content = distributionLines
                .map { "**\($0.0)：** \($0.1)" }
                .joined(separator: "\n")
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        let focusIssues = prioritizedIssueMonthlyFocusIssues(d)
        if !focusIssues.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**重点问题（最多 8 条）：**"
            for issue in focusIssues.prefix(8) {
                content += "\n" + Self.formatIssue(issue, showStatus: true, config: cfg, jiraServerURL: store.jiraConfig.serverURL, showTimes: true)
            }
            let omitted = max(focusIssues.count - min(focusIssues.count, 8), 0)
            if omitted > 0 {
                content += "\n_其余 \(omitted) 条未关闭问题已省略，请打开问题月报查看详情。_"
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        if !d.staleOpenIssues.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**积压问题（超过 7 天未关闭，最多 8 条）：**"
            for issue in d.staleOpenIssues.prefix(8) {
                content += "\n" + Self.formatIssue(issue, showStatus: true, config: cfg, jiraServerURL: store.jiraConfig.serverURL, showTimes: true)
            }
            if d.staleOpenIssues.count > 8 {
                content += "\n_其余 \(d.staleOpenIssues.count - 8) 条积压问题已省略，请打开问题月报查看详情。_"
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        if d.issues.isEmpty {
            elements.append(["tag": "hr"])
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": "本期暂无问题记录"]])
        }

        elements.append(["tag": "note", "elements": Self.footerNoteElements()])

        return [
            "msg_type": "interactive",
            "card": [
                "config": ["wide_screen_mode": true],
                "header": ["title": ["tag": "plain_text", "content": d.title], "template": "purple"],
                "elements": elements
            ]
        ]
    }

    private func prioritizedIssueMonthlyFocusIssues(_ data: IssueMonthlyReportData) -> [TrackedIssue] {
        var result: [TrackedIssue] = []
        var seen = Set<UUID>()
        let staleIDs = Set(data.staleOpenIssues.map(\.id))
        func append(_ issues: [TrackedIssue]) {
            for issue in issues where !staleIDs.contains(issue.id) && seen.insert(issue.id).inserted {
                result.append(issue)
            }
        }
        append(data.unassignedOpenIssues)
        append(data.openIssues)
        return result
    }

    private func compactPairs(_ pairs: [(String, Int)]) -> String {
        pairs
            .filter { $0.1 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: "，")
    }

    private func shareText(_ count: Int, total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(count) / Double(total) * 100).rounded()))%"
    }

    private static func issueStatusRank(_ status: IssueStatus) -> Int {
        switch status {
        case .pending: return 0
        case .inProgress: return 1
        case .testing: return 2
        case .scheduled: return 3
        case .observing: return 4
        case .fixed: return 5
        case .ignored: return 6
        }
    }

    // MARK: - Rich Text (post) Report

    private func generateRichTextReport(store: DataStore) -> [String: Any] {
        let d = collectReportData(store: store)
        var lines: [[[String: Any]]] = []

        // === 解决情况高亮摘要 ===
        if d.config.showOverview {
            var statsLine = "🟢 今日新建 \(d.newIssues.count)  ·  ✅ 今日解决 \(d.resolvedToday.count)  ·  🔶 待处理 \(d.pending.count)"
            if !d.inProgress.isEmpty {
                statsLine += "  ·  🔄 处理中 \(d.inProgress.count)"
            }
            if !d.observing.isEmpty {
                statsLine += "  ·  👁 观测中 \(d.observing.count)"
            }
            lines.append([
                text(statsLine)
            ])
            lines.append([text("")])
        }

        // === 待处理问题 ===
        if d.config.showPending && !d.pending.isEmpty {
            lines.append([text("📋 待处理问题：")])
            for issue in d.pending {
                lines.append(richTextIssueLine(issue, showStatus: d.config.fieldStatus, config: d.config, jiraServerURL: d.jiraServerURL))
            }
            lines.append([text("")])
        }

        // === 处理中问题 ===
        if d.config.showInProgress && !d.inProgress.isEmpty {
            lines.append([text("🔄 处理中问题：")])
            for issue in d.inProgress {
                lines.append(richTextIssueLine(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL))
            }
            lines.append([text("")])
        }

        // === 观测中问题 ===
        if d.config.showObserving && !d.observing.isEmpty {
            lines.append([text("👁 观测中问题：")])
            for issue in d.observing {
                lines.append(richTextIssueLine(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL))
            }
            lines.append([text("")])
        }

        // === 已排期问题 ===
        if d.config.showScheduled && !d.scheduled.isEmpty {
            lines.append([text("📅 已排期问题：")])
            for issue in d.scheduled {
                lines.append(richTextIssueLine(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL))
            }
            lines.append([text("")])
        }

        // === 测试中问题 ===
        if d.config.showTesting && !d.testing.isEmpty {
            lines.append([text("🧪 测试中问题：")])
            for issue in d.testing {
                lines.append(richTextIssueLine(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL))
            }
            lines.append([text("")])
        }

        // === 今日已解决 ===
        if d.config.showResolved && !d.resolvedToday.isEmpty {
            lines.append([text("✅ 今日已解决：")])
            for issue in d.resolvedToday {
                lines.append(richTextIssueLine(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL))
            }
            lines.append([text("")])
        }

        // === 我今日提交 ===
        if d.config.showMyReported && !d.myReportedToday.isEmpty {
            lines.append([text("🙋 我今日提交：")])
            for issue in d.myReportedToday {
                lines.append(richTextIssueLine(issue, showStatus: d.config.fieldStatus, config: d.config, jiraServerURL: d.jiraServerURL))
            }
            lines.append([text("")])
        }

        // === 今日重点 tag ===
        if d.config.showFocusTag && !d.focusTag.isEmpty && !d.focusTagged.isEmpty {
            lines.append([text("🏷 今日重点（\(d.focusTag)）：")])
            for issue in d.focusTagged {
                lines.append(richTextIssueLine(issue, showStatus: d.config.fieldStatus, config: d.config, jiraServerURL: d.jiraServerURL))
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
        lines.append([text(Self.footerNoteText())])

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
        let title = Self.reportIssueTitle(issue)
        var parts = [text("· ")]
        if Self.hasLinearBinding(issue) {
            parts.append(text(title))
            parts.append(text(" · "))
            if let url = Self.reportIssueURL(issue, jiraServerURL: jiraServerURL) {
                parts.append(link(Self.linearReportLabel(issue), href: url))
            } else {
                parts.append(text(Self.linearReportLabel(issue)))
            }
            parts.append(text(" · \(Self.linearReportDetails(issue))"))
        } else if let url = Self.reportIssueURL(issue, jiraServerURL: jiraServerURL) {
            parts.append(link(title, href: url))
        } else {
            parts.append(text(title))
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
            "我提交列表": formatIssueListMd(d.myReportedToday, showStatus: true, config: d.config, jiraServerURL: d.jiraServerURL),
            "重点Tag": d.focusTag.isEmpty ? "未配置" : d.focusTag,
            "重点列表": formatIssueListMd(d.focusTagged, showStatus: true, config: d.config, jiraServerURL: d.jiraServerURL),
            "日报内容": d.dailyNote.isEmpty ? "无" : d.dailyNote,
            "当前时间": timeFmt.string(from: Date()),
        ]

        var result = removeSupportStatsLines(from: template)
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
        elements.append(["tag": "note", "elements": Self.footerNoteElements()])

        return [
            "msg_type": "interactive",
            "card": [
                "config": ["wide_screen_mode": true],
                "header": ["title": ["tag": "plain_text", "content": d.config.customTemplateTitle.isEmpty ? "每日工单报告" : d.config.customTemplateTitle], "template": "blue"],
                "elements": elements
            ]
        ]
    }

    private func removeSupportStatsLines(from text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.contains("项目支持")
                    && !trimmed.contains("{{项目统计}}")
                    && !trimmed.contains("{{今日总数}}")
            }
            .joined(separator: "\n")
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
        var elements: [[String: Any]] = []

        // 日期
        let dateLine = "**日期：** \(d.todayKey)"
        elements.append(["tag": "div", "text": ["tag": "lark_md", "content": dateLine]])

        // 统计概览（高亮）
        if d.config.showOverview {
            elements.append(["tag": "hr"])
            var statsLine = "🟢 **今日新建** \(d.newIssues.count) 个  ·  ✅ **今日解决** \(d.resolvedToday.count) 个  ·  🔶 **待处理** \(d.pending.count) 个"
            if !d.inProgress.isEmpty {
                statsLine += "  ·  🔄 **处理中** \(d.inProgress.count) 个"
            }
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
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 处理中问题列表 + 评论
        if d.config.showInProgress && !d.inProgress.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**🔄 处理中问题：**"
            for issue in d.inProgress {
                content += "\n" + Self.formatIssue(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL)
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 观测中问题列表 + 评论
        if d.config.showObserving && !d.observing.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**👁 观测中问题：**"
            for issue in d.observing {
                content += "\n" + Self.formatIssue(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL)
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 已排期问题列表 + 评论
        if d.config.showScheduled && !d.scheduled.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**📅 已排期问题：**"
            for issue in d.scheduled {
                content += "\n" + Self.formatIssue(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL)
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 测试中问题列表 + 评论
        if d.config.showTesting && !d.testing.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**🧪 测试中问题：**"
            for issue in d.testing {
                content += "\n" + Self.formatIssue(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL)
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 今日已解决列表 + 评论
        if d.config.showResolved && !d.resolvedToday.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**今日已解决：**"
            for issue in d.resolvedToday {
                content += "\n" + Self.formatIssue(issue, showStatus: false, config: d.config, jiraServerURL: d.jiraServerURL)
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 我今日提交
        if d.config.showMyReported && !d.myReportedToday.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**我今日提交：**"
            for issue in d.myReportedToday {
                content += "\n" + Self.formatIssue(issue, showStatus: d.config.fieldStatus, config: d.config, jiraServerURL: d.jiraServerURL)
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 今日重点 tag
        if d.config.showFocusTag && !d.focusTag.isEmpty && !d.focusTagged.isEmpty {
            elements.append(["tag": "hr"])
            var content = "**今日重点（\(d.focusTag)）：**"
            for issue in d.focusTagged {
                content += "\n" + Self.formatIssue(issue, showStatus: d.config.fieldStatus, config: d.config, jiraServerURL: d.jiraServerURL)
            }
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": content]])
        }

        // 日报文字
        if d.config.showDailyNote && !d.dailyNote.isEmpty {
            elements.append(["tag": "hr"])
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": "**日报：**\n\(d.dailyNote)"]])
        }

        // 无数据
        let hasContent = d.config.showOverview
            || (d.config.showPending && !d.pending.isEmpty)
            || (d.config.showInProgress && !d.inProgress.isEmpty)
            || (d.config.showObserving && !d.observing.isEmpty)
            || (d.config.showScheduled && !d.scheduled.isEmpty)
            || (d.config.showTesting && !d.testing.isEmpty)
            || (d.config.showResolved && !d.resolvedToday.isEmpty)
            || (d.config.showMyReported && !d.myReportedToday.isEmpty)
            || (d.config.showFocusTag && !d.focusTag.isEmpty && !d.focusTagged.isEmpty)
        if !hasContent {
            elements.append(["tag": "hr"])
            elements.append(["tag": "div", "text": ["tag": "lark_md", "content": "今日暂无工单记录"]])
        }

        // 底部备注
        elements.append(["tag": "note", "elements": Self.footerNoteElements()])

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

    private static var webPortalURL: String {
        let url = SyncManager.shared.config.webPortalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? "" : url
    }

    private static func footerNoteElements() -> [[String: Any]] {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let portal = webPortalURL
        let content: String
        if portal.isEmpty {
            content = "由 TicTracker 自动生成 | \(timeFmt.string(from: Date()))"
        } else {
            content = "由 TicTracker 自动生成 | \(timeFmt.string(from: Date())) | 查看详情: \(portal)"
        }
        return [["tag": "plain_text", "content": content]]
    }

    private static func footerNoteText() -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm"
        let portal = webPortalURL
        if !portal.isEmpty {
            return "—— 由 TicTracker 自动生成 | \(timeFmt.string(from: Date())) | 查看详情: \(portal)"
        }
        return "—— 由 TicTracker 自动生成 | \(timeFmt.string(from: Date()))"
    }

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
    private static func formatIssue(_ issue: TrackedIssue, showStatus: Bool, config: FeishuBotConfig, jiraServerURL: String = "", showTimes: Bool = false) -> String {
        let title = reportIssueTitle(issue)
        if hasLinearBinding(issue) {
            let label = escapeMarkdownLinkText(linearReportLabel(issue))
            let linearReference: String
            if let url = reportIssueURL(issue, jiraServerURL: jiraServerURL) {
                linearReference = "[\(label)](\(url))"
            } else {
                linearReference = label
            }
            return "- \(title)\n  \(linearReference) · \(linearReportDetails(issue))"
        }
        guard let url = reportIssueURL(issue, jiraServerURL: jiraServerURL) else {
            return "- \(title)"
        }
        return "- [\(escapeMarkdownLinkText(title))](\(url))"
    }

    private static func reportIssueTitle(_ issue: TrackedIssue) -> String {
        issue.title
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func hasLinearBinding(_ issue: TrackedIssue) -> Bool {
        issue.linearIssueId?.isEmpty == false || issue.linearKey?.isEmpty == false || issue.linearUrl?.isEmpty == false
    }

    private static func linearReportLabel(_ issue: TrackedIssue) -> String {
        let key = issue.linearKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? "Linear" : "Linear \(key)"
    }

    private static func linearReportDetails(_ issue: TrackedIssue) -> String {
        let assignee = nonEmpty(issue.linearAssignee) ?? nonEmpty(issue.assignee) ?? "未分配"
        let creator = nonEmpty(issue.linearCreator) ?? "未知"
        let created = linearDateText(issue.linearCreatedAt) ?? issueDateTimeText(issue.createdAt)
        let updated = linearDateText(issue.linearUpdatedAt)
            ?? issue.updatedAt.map(issueDateTimeText)
            ?? created
        return "处理人：\(assignee) · 创建人：\(creator) · 创建：\(created) · 更新：\(updated)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func linearDateText(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? basic.date(from: value) else { return nil }
        return issueDateTimeText(date)
    }

    /// Keep the report visually title-only while retaining its external issue binding.
    private static func reportIssueURL(_ issue: TrackedIssue, jiraServerURL: String) -> String? {
        if let linearURL = linearKeyAndURL(issue)?.url, !linearURL.isEmpty {
            return linearURL
        }
        if let jiraKey = issue.jiraKey?.trimmingCharacters(in: .whitespacesAndNewlines), !jiraKey.isEmpty,
           let jiraURL = jiraKeyAndURL(jiraKey, serverURL: jiraServerURL).url {
            return jiraURL
        }
        if let ticketURL = issue.ticketURL?.trimmingCharacters(in: .whitespacesAndNewlines), !ticketURL.isEmpty {
            return ticketURL
        }
        return nil
    }

    private static func escapeMarkdownLinkText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func issueTimelineText(_ issue: TrackedIssue) -> String {
        "创建 \(issueDateTimeText(issue.createdAt)) · 更新 \(issueDateTimeText(issueLatestActivityDate(issue)))"
    }

    private static func issueDateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func issueLatestActivityDate(_ issue: TrackedIssue) -> Date {
        var dates = [issue.createdAt]
        if let reportedAt = issue.reportedAt { dates.append(reportedAt) }
        if let updatedAt = issue.updatedAt { dates.append(updatedAt) }
        if let resolvedAt = issue.resolvedAt { dates.append(resolvedAt) }
        dates.append(contentsOf: issue.comments.map(\.createdAt))
        return dates.max() ?? issue.updatedAt ?? issue.createdAt
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

    /// 提取 Linear 的显示文本和完整 URL
    private static func linearKeyAndURL(_ issue: TrackedIssue) -> (key: String, url: String?)? {
        let key = issue.linearKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = issue.linearUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = issue.linearProjectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            let label = project.isEmpty ? "Linear \(key)" : "Linear \(project) / \(key)"
            return (label, url.isEmpty ? nil : url)
        }
        if !url.isEmpty, let parsed = URL(string: url) {
            let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fallback = parsed.lastPathComponent.isEmpty ? String(trimmed.split(separator: "/").last ?? "Linear") : parsed.lastPathComponent
            let label = project.isEmpty ? "Linear \(fallback)" : "Linear \(project) / \(fallback)"
            return (label, url)
        }
        if let issueID = issue.linearIssueId?.trimmingCharacters(in: .whitespacesAndNewlines), !issueID.isEmpty {
            let label = project.isEmpty ? "Linear \(issueID)" : "Linear \(project) / \(issueID)"
            return (label, nil)
        }
        return nil
    }

    /// 格式化 Linear 链接为 lark_md
    private static func linearMarkdown(_ issue: TrackedIssue) -> String? {
        guard let linear = linearKeyAndURL(issue) else { return nil }
        if let url = linear.url {
            return "[\(linear.key)](\(url))"
        }
        return linear.key
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

    private static let credentialsLock = NSLock()
    nonisolated(unsafe) private static var cachedAppSecret: String?
    nonisolated(unsafe) private static var cachedWebhookSecrets: [UUID: String] = [:]
    nonisolated(unsafe) private static var didLoadCredentials = false
    nonisolated(unsafe) private static var didCheckLegacySecret = false

    @discardableResult
    static func saveAppSecret(_ secret: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return deleteAppSecret()
        }
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        var creds = FeishuCredentials.load()
        creds.appSecret = trimmed
        guard FeishuCredentials.save(creds) else { return false }
        cachedAppSecret = trimmed
        didLoadCredentials = true
        return true
    }

    @discardableResult
    static func deleteAppSecret() -> Bool {
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        var creds = FeishuCredentials.load()
        creds.appSecret = nil
        guard FeishuCredentials.save(creds) else { return false }
        cachedAppSecret = nil
        didLoadCredentials = true
        return true
    }

    static func loadAppSecret() -> String? {
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        ensureCredentialsLoaded()
        return cachedAppSecret
    }

    /// Moves secrets written by legacy FeishuBotConfig versions into Keychain.
    /// The caller must persist the sanitized config only after this returns true.
    static func migrateLegacyConfigSecrets(_ config: inout FeishuBotConfig) -> Bool {
        let appSecret = config.appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let verificationToken = config.verificationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let encryptKey = config.encryptKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appSecret.isEmpty || !verificationToken.isEmpty || !encryptKey.isEmpty else {
            return false
        }

        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        var credentials = FeishuCredentials.load()
        if credentials.appSecret?.isEmpty ?? true, !appSecret.isEmpty {
            credentials.appSecret = appSecret
        }
        if credentials.verificationToken?.isEmpty ?? true, !verificationToken.isEmpty {
            credentials.verificationToken = verificationToken
        }
        if credentials.encryptKey?.isEmpty ?? true, !encryptKey.isEmpty {
            credentials.encryptKey = encryptKey
        }
        guard FeishuCredentials.save(credentials) else { return false }

        cachedAppSecret = credentials.appSecret
        didLoadCredentials = true
        config.appSecret = ""
        config.verificationToken = ""
        config.encryptKey = ""
        return true
    }

    static func loadSecret(for webhookID: UUID) -> String? {
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        ensureCredentialsLoaded()
        return cachedWebhookSecrets[webhookID]
    }

    static func loadSecrets(for webhookIDs: [UUID]) -> [UUID: String] {
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        ensureCredentialsLoaded()
        var out: [UUID: String] = [:]
        for id in webhookIDs {
            if let s = cachedWebhookSecrets[id] { out[id] = s }
        }
        return out
    }

    static func migrateLegacySecretIfNeeded(for webhooks: [FeishuWebhook]) {
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        ensureCredentialsLoaded()
        guard let legacySecret = loadLegacySecret(), !legacySecret.isEmpty else {
            if !didCheckLegacySecret {
                didCheckLegacySecret = true
                Task { @MainActor in
                    DevLog.shared.info("FeishuBot", "未发现旧版全局 Webhook Secret")
                }
            }
            return
        }
        didCheckLegacySecret = true

        var creds = FeishuCredentials.load()
        var migratedCount = 0
        for webhook in webhooks {
            guard creds.webhookSecrets[webhook.id.uuidString]?.isEmpty ?? true else { continue }
            creds.webhookSecrets[webhook.id.uuidString] = legacySecret
            cachedWebhookSecrets[webhook.id] = legacySecret
            migratedCount += 1
        }

        guard migratedCount > 0 else {
            deleteLegacySecret()
            Task { @MainActor in
                DevLog.shared.info("FeishuBot", "旧版全局 Webhook Secret 已存在于当前 Webhook")
            }
            return
        }

        if FeishuCredentials.save(creds) {
            deleteLegacySecret()
            Task { @MainActor in
                DevLog.shared.info("FeishuBot", "已恢复旧版全局 Webhook Secret 到 \(migratedCount) 个 Webhook")
            }
        } else {
            Task { @MainActor in
                DevLog.shared.error("FeishuBot", "恢复旧版全局 Webhook Secret 失败：凭据保存失败")
            }
        }
    }

    @discardableResult
    static func deleteSecret(for webhookID: UUID) -> Bool {
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        var creds = FeishuCredentials.load()
        creds.webhookSecrets.removeValue(forKey: webhookID.uuidString)
        guard FeishuCredentials.save(creds) else { return false }
        cachedWebhookSecrets.removeValue(forKey: webhookID)
        didLoadCredentials = true
        return true
    }

    @discardableResult
    static func saveSecret(for webhookID: UUID, secret: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return deleteSecret(for: webhookID)
        }
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        var creds = FeishuCredentials.load()
        creds.webhookSecrets[webhookID.uuidString] = trimmed
        guard FeishuCredentials.save(creds) else { return false }
        cachedWebhookSecrets[webhookID] = trimmed
        didLoadCredentials = true
        return true
    }

    static func warmUpSecrets() {
        credentialsLock.lock()
        defer { credentialsLock.unlock() }
        ensureCredentialsLoaded()
    }

    private static func ensureCredentialsLoaded() {
        guard !didLoadCredentials else { return }
        didLoadCredentials = true
        let creds = FeishuCredentials.load()
        cachedAppSecret = creds.appSecret
        for (uuidStr, secret) in creds.webhookSecrets {
            if let id = UUID(uuidString: uuidStr) {
                cachedWebhookSecrets[id] = secret
            }
        }
        if let bundleData = creds.oauthBundle {
            FeishuOAuthService.shared.warmUpFromBatch(bundleData)
        }
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
