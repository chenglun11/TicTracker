import Foundation

enum FeishuMessageFormat: String, Codable, Sendable, CaseIterable {
    case card = "消息卡片"
    case richText = "富文本"
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

    var key: String { String(format: "%02d:%02d", hour, minute) }
}

struct FeishuBotConfig: Codable, Sendable {
    var enabled: Bool = false
    var webhookURL: String = ""
    var signEnabled: Bool = false
    var sendTimes: [ScheduleTime] = []
    var lastSentTimes: [String: String] = [:]  // key="HH:mm", value=dateKey of last send
    var lastSentDateTime: String = ""
    var messageFormat: FeishuMessageFormat = .card
    var sendHistory: [SendHistory] = []
    var maxRetries: Int = 3

    // 卡片模块开关
    var showSupportStats: Bool = true   // 项目支持统计
    var showOverview: Bool = true       // 统计概览（新建/解决/待处理）
    var showPending: Bool = true        // 待处理列表
    var showObserving: Bool = true      // 观测中列表
    var showResolved: Bool = true       // 今日已解决列表
    var showDailyNote: Bool = true      // 日报文字
    var showComments: Bool = true       // 问题评论

    // issue 显示字段
    var fieldType: Bool = true          // 类型 (Bug/Feature/Support)
    var fieldDepartment: Bool = true    // 部门
    var fieldJiraKey: Bool = true       // Jira Key
    var fieldStatus: Bool = true        // 状态
    var fieldAssignee: Bool = false     // 负责人

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, webhookURL, signEnabled
        case sendTimes, lastSentTimes, lastSentDateTime
        case sendHour, sendMinute, lastSentDate  // legacy
        case messageFormat, sendHistory, maxRetries
        case showSupportStats, showOverview, showPending, showObserving, showResolved, showDailyNote, showComments
        case fieldType, fieldDepartment, fieldJiraKey, fieldStatus, fieldAssignee
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
        signEnabled = try c.decodeIfPresent(Bool.self, forKey: .signEnabled) ?? false
        lastSentDateTime = try c.decodeIfPresent(String.self, forKey: .lastSentDateTime) ?? ""
        messageFormat = try c.decodeIfPresent(FeishuMessageFormat.self, forKey: .messageFormat) ?? .card
        sendHistory = try c.decodeIfPresent([SendHistory].self, forKey: .sendHistory) ?? []
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 3

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
        try c.encode(webhookURL, forKey: .webhookURL)
        try c.encode(signEnabled, forKey: .signEnabled)
        try c.encode(sendTimes, forKey: .sendTimes)
        try c.encode(lastSentTimes, forKey: .lastSentTimes)
        try c.encode(lastSentDateTime, forKey: .lastSentDateTime)
        try c.encode(messageFormat, forKey: .messageFormat)
        try c.encode(sendHistory, forKey: .sendHistory)
        try c.encode(maxRetries, forKey: .maxRetries)

        try c.encode(showSupportStats, forKey: .showSupportStats)
        try c.encode(showOverview, forKey: .showOverview)
        try c.encode(showPending, forKey: .showPending)
        try c.encode(showObserving, forKey: .showObserving)
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
