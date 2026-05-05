import Foundation

enum FeishuMessageFormat: String, Codable, Sendable, CaseIterable {
    case card = "消息卡片"
    case richText = "富文本"
    case customTemplate = "自定义模板"
}

struct SendHistory: Codable, Sendable, Identifiable {
    var id = UUID()
    var timestamp: Date
    var success: Bool
    var message: String
    var retryCount: Int = 0
}

struct ScheduleTime: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var hour: Int = 18
    var minute: Int = 0
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]  // 1=周一, 7=周日, 空集表示每天

    var key: String { String(format: "%02d:%02d", hour, minute) }

    func shouldSendOn(weekday: Int) -> Bool {
        weekdays.contains(weekday)
    }

    private enum CodingKeys: String, CodingKey {
        case id, hour, minute, weekdays
    }

    init(id: UUID = UUID(), hour: Int = 18, minute: Int = 0, weekdays: Set<Int> = [1, 2, 3, 4, 5]) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 18
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? [1, 2, 3, 4, 5]
    }
}

struct FeishuWebhook: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var enabled: Bool = true
    var signEnabled: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, url, enabled, signEnabled
    }

    init(id: UUID = UUID(), url: String, enabled: Bool = true, signEnabled: Bool = false) {
        self.id = id
        self.url = url
        self.enabled = enabled
        self.signEnabled = signEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        signEnabled = try c.decodeIfPresent(Bool.self, forKey: .signEnabled) ?? false
    }
}


enum FeishuTaskAuthMode: String, Codable, Sendable, CaseIterable {
    case userOAuth = "用户 OAuth"
    case botTenant = "Bot / 应用身份"
}

struct FeishuBotConfig: Codable, Sendable {
    static let defaultTemplate = """
📊 **项目支持：**{{项目统计}}（共 {{今日总数}} 次）
---
🟢 **今日新建** {{新建数量}} 个  ·  ✅ **今日解决** {{解决数量}} 个  ·  🔶 **待处理** {{待处理数量}} 个  ·  👁 **观测中** {{观测中数量}} 个
---
**待处理问题：**
{{待处理列表}}
---
**已解决问题：**
{{已解决列表}}
---
**👁 观测中问题：**
{{观测中列表}}
---
**📝 日报：**
{{日报内容}}
"""

    var enabled: Bool = false
    var webhooks: [FeishuWebhook] = []
    var sendTimes: [ScheduleTime] = []
    var lastSentTimes: [String: String] = [:]  // key="HH:mm", value=dateKey of last send
    var lastSentDateTime: String = ""
    var messageFormat: FeishuMessageFormat = .card
    var customTemplate: String = Self.defaultTemplate
    var customTemplateTitle: String = "每日工单报告"
    var cardTitle: String = "每日工单报告"
    var sendHistory: [SendHistory] = []
    var maxRetries: Int = 3

    // 飞书应用（双向交互）
    var appID: String = ""
    var appSecret: String = ""
    var verificationToken: String = ""
    var encryptKey: String = ""
    var allowedChatIDs: [String] = []
    var tasklistGUID: String = ""
    var taskPollingInterval: Int = 5
    var taskAuthMode: FeishuTaskAuthMode = .userOAuth
    var taskDefaultCollaboratorOpenID: String = ""
    var botTasklistGUID: String = ""
    var botTasklistName: String = "TicTracker Issues"

    // 卡片模块开关
    var showSupportStats: Bool = true   // 项目支持统计
    var showOverview: Bool = true       // 统计概览（新建/解决/待处理）
    var showPending: Bool = true        // 待处理列表
    var showObserving: Bool = true      // 观测中列表
    var showResolved: Bool = true       // 今日已解决列表
    var showDailyNote: Bool = true      // 日报文字
    var showScheduled: Bool = true      // 已排期列表
    var showTesting: Bool = true        // 测试中列表
    var showComments: Bool = true       // 问题评论

    // issue 显示字段
    var fieldType: Bool = true          // 类型 (Bug/Feature/Support)
    var fieldDepartment: Bool = true    // 部门
    var fieldJiraKey: Bool = true       // Jira Key
    var fieldStatus: Bool = true        // 状态
    var fieldAssignee: Bool = false     // 负责人

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, webhookURL, webhookURLs, webhooks, signEnabled
        case sendTimes, lastSentTimes, lastSentDateTime
        case sendHour, sendMinute, lastSentDate  // legacy
        case messageFormat, sendHistory, maxRetries, customTemplate, customTemplateTitle, cardTitle
        case appID
        case appSecret
        case verificationToken
        case encryptKey
        case allowedChatIDs
        case tasklistGUID
        case taskPollingInterval
        case taskAuthMode
        case taskDefaultCollaboratorOpenID
        case botTasklistGUID, botTasklistName
        case showSupportStats, showOverview, showPending, showObserving, showScheduled, showTesting, showResolved, showDailyNote, showComments
        case fieldType, fieldDepartment, fieldJiraKey, fieldStatus, fieldAssignee
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        webhooks = try c.decodeIfPresent([FeishuWebhook].self, forKey: .webhooks) ?? []
        if webhooks.isEmpty {
            // 迁移：从 webhookURLs 或 webhookURL 迁移
            var urls = try c.decodeIfPresent([String].self, forKey: .webhookURLs) ?? []
            if urls.isEmpty {
                let legacy = try c.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
                if !legacy.isEmpty { urls = [legacy] }
            }
            let oldSignEnabled = try c.decodeIfPresent(Bool.self, forKey: .signEnabled) ?? false
            webhooks = urls.map { FeishuWebhook(url: $0, signEnabled: oldSignEnabled) }
        }
        lastSentDateTime = try c.decodeIfPresent(String.self, forKey: .lastSentDateTime) ?? ""
        messageFormat = try c.decodeIfPresent(FeishuMessageFormat.self, forKey: .messageFormat) ?? .card
        customTemplate = try c.decodeIfPresent(String.self, forKey: .customTemplate) ?? Self.defaultTemplate
        customTemplateTitle = try c.decodeIfPresent(String.self, forKey: .customTemplateTitle) ?? "每日工单报告"
        cardTitle = try c.decodeIfPresent(String.self, forKey: .cardTitle) ?? "每日工单报告"
        sendHistory = try c.decodeIfPresent([SendHistory].self, forKey: .sendHistory) ?? []
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 3
        appID = try c.decodeIfPresent(String.self, forKey: .appID) ?? ""
        appSecret = try c.decodeIfPresent(String.self, forKey: .appSecret) ?? ""
        verificationToken = try c.decodeIfPresent(String.self, forKey: .verificationToken) ?? ""
        encryptKey = try c.decodeIfPresent(String.self, forKey: .encryptKey) ?? ""
        allowedChatIDs = try c.decodeIfPresent([String].self, forKey: .allowedChatIDs) ?? []
        tasklistGUID = try c.decodeIfPresent(String.self, forKey: .tasklistGUID) ?? ""
        taskPollingInterval = max(try c.decodeIfPresent(Int.self, forKey: .taskPollingInterval) ?? 5, 1)
        taskAuthMode = try c.decodeIfPresent(FeishuTaskAuthMode.self, forKey: .taskAuthMode) ?? .userOAuth
        taskDefaultCollaboratorOpenID = try c.decodeIfPresent(String.self, forKey: .taskDefaultCollaboratorOpenID) ?? ""
        botTasklistGUID = try c.decodeIfPresent(String.self, forKey: .botTasklistGUID) ?? ""
        botTasklistName = try c.decodeIfPresent(String.self, forKey: .botTasklistName) ?? "TicTracker Issues"

        // 新格式
        sendTimes = try c.decodeIfPresent([ScheduleTime].self, forKey: .sendTimes) ?? []
        lastSentTimes = try c.decodeIfPresent([String: String].self, forKey: .lastSentTimes) ?? [:]

        // 迁移：如果 sendTimes 为空，从旧字段迁移
        if sendTimes.isEmpty {
            let hour = try c.decodeIfPresent(Int.self, forKey: .sendHour) ?? 18
            let minute = try c.decodeIfPresent(Int.self, forKey: .sendMinute) ?? 0
            sendTimes = [ScheduleTime(hour: hour, minute: minute)]
            // 迁移 lastSentDate
            let lastDate = try c.decodeIfPresent(String.self, forKey: .lastSentDate) ?? ""
            if !lastDate.isEmpty {
                lastSentTimes[sendTimes[0].key] = lastDate
            }
        }

        showSupportStats = try c.decodeIfPresent(Bool.self, forKey: .showSupportStats) ?? true
        showOverview = try c.decodeIfPresent(Bool.self, forKey: .showOverview) ?? true
        showPending = try c.decodeIfPresent(Bool.self, forKey: .showPending) ?? true
        showObserving = try c.decodeIfPresent(Bool.self, forKey: .showObserving) ?? true
        showScheduled = try c.decodeIfPresent(Bool.self, forKey: .showScheduled) ?? true
        showTesting = try c.decodeIfPresent(Bool.self, forKey: .showTesting) ?? true
        showResolved = try c.decodeIfPresent(Bool.self, forKey: .showResolved) ?? true
        showDailyNote = try c.decodeIfPresent(Bool.self, forKey: .showDailyNote) ?? true
        showComments = try c.decodeIfPresent(Bool.self, forKey: .showComments) ?? true

        fieldType = try c.decodeIfPresent(Bool.self, forKey: .fieldType) ?? true
        fieldDepartment = try c.decodeIfPresent(Bool.self, forKey: .fieldDepartment) ?? true
        fieldJiraKey = try c.decodeIfPresent(Bool.self, forKey: .fieldJiraKey) ?? true
        fieldStatus = try c.decodeIfPresent(Bool.self, forKey: .fieldStatus) ?? true
        fieldAssignee = try c.decodeIfPresent(Bool.self, forKey: .fieldAssignee) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(webhooks, forKey: .webhooks)
        try c.encode(webhooks.map { $0.url }, forKey: .webhookURLs)  // 向后兼容
        try c.encode(sendTimes, forKey: .sendTimes)
        try c.encode(lastSentTimes, forKey: .lastSentTimes)
        try c.encode(lastSentDateTime, forKey: .lastSentDateTime)
        try c.encode(messageFormat, forKey: .messageFormat)
        try c.encode(customTemplate, forKey: .customTemplate)
        try c.encode(customTemplateTitle, forKey: .customTemplateTitle)
        try c.encode(cardTitle, forKey: .cardTitle)
        try c.encode(sendHistory, forKey: .sendHistory)
        try c.encode(maxRetries, forKey: .maxRetries)
        if !appID.isEmpty {
            try c.encode(appID, forKey: .appID)
        }
        if !appSecret.isEmpty {
            try c.encode(appSecret, forKey: .appSecret)
        }
        if !verificationToken.isEmpty {
            try c.encode(verificationToken, forKey: .verificationToken)
        }
        if !encryptKey.isEmpty {
            try c.encode(encryptKey, forKey: .encryptKey)
        }
        if !allowedChatIDs.isEmpty {
            try c.encode(allowedChatIDs, forKey: .allowedChatIDs)
        }
        if !tasklistGUID.isEmpty {
            try c.encode(tasklistGUID, forKey: .tasklistGUID)
        }
        if taskPollingInterval != 5 {
            try c.encode(taskPollingInterval, forKey: .taskPollingInterval)
        }
        if taskAuthMode != .userOAuth {
            try c.encode(taskAuthMode, forKey: .taskAuthMode)
        }
        if !taskDefaultCollaboratorOpenID.isEmpty {
            try c.encode(taskDefaultCollaboratorOpenID, forKey: .taskDefaultCollaboratorOpenID)
        }
        if !botTasklistGUID.isEmpty {
            try c.encode(botTasklistGUID, forKey: .botTasklistGUID)
        }
        if botTasklistName != "TicTracker Issues" {
            try c.encode(botTasklistName, forKey: .botTasklistName)
        }

        try c.encode(showSupportStats, forKey: .showSupportStats)
        try c.encode(showOverview, forKey: .showOverview)
        try c.encode(showPending, forKey: .showPending)
        try c.encode(showObserving, forKey: .showObserving)
        try c.encode(showScheduled, forKey: .showScheduled)
        try c.encode(showTesting, forKey: .showTesting)
        try c.encode(showResolved, forKey: .showResolved)
        try c.encode(showDailyNote, forKey: .showDailyNote)
        try c.encode(showComments, forKey: .showComments)

        try c.encode(fieldType, forKey: .fieldType)
        try c.encode(fieldDepartment, forKey: .fieldDepartment)
        try c.encode(fieldJiraKey, forKey: .fieldJiraKey)
        try c.encode(fieldStatus, forKey: .fieldStatus)
        try c.encode(fieldAssignee, forKey: .fieldAssignee)
    }
}
