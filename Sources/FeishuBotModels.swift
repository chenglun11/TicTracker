import Foundation

enum FeishuMessageFormat: String, Codable, Sendable, CaseIterable {
    case card = "消息卡片"
    case richText = "富文本"
}

struct FeishuBotConfig: Codable, Sendable {
    var enabled: Bool = false
    var webhookURL: String = ""
    var signEnabled: Bool = false
    var sendHour: Int = 18
    var sendMinute: Int = 0
    var lastSentDate: String = ""
    var messageFormat: FeishuMessageFormat = .card

    // 卡片模块开关
    var showSupportStats: Bool = true   // 项目支持统计
    var showOverview: Bool = true       // 统计概览（新建/解决/待处理）
    var showPending: Bool = true        // 待处理列表
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL) ?? ""
        signEnabled = try c.decodeIfPresent(Bool.self, forKey: .signEnabled) ?? false
        sendHour = try c.decodeIfPresent(Int.self, forKey: .sendHour) ?? 18
        sendMinute = try c.decodeIfPresent(Int.self, forKey: .sendMinute) ?? 0
        lastSentDate = try c.decodeIfPresent(String.self, forKey: .lastSentDate) ?? ""
        messageFormat = try c.decodeIfPresent(FeishuMessageFormat.self, forKey: .messageFormat) ?? .card

        showSupportStats = try c.decodeIfPresent(Bool.self, forKey: .showSupportStats) ?? true
        showOverview = try c.decodeIfPresent(Bool.self, forKey: .showOverview) ?? true
        showPending = try c.decodeIfPresent(Bool.self, forKey: .showPending) ?? true
        showResolved = try c.decodeIfPresent(Bool.self, forKey: .showResolved) ?? true
        showDailyNote = try c.decodeIfPresent(Bool.self, forKey: .showDailyNote) ?? true
        showComments = try c.decodeIfPresent(Bool.self, forKey: .showComments) ?? true

        fieldType = try c.decodeIfPresent(Bool.self, forKey: .fieldType) ?? true
        fieldDepartment = try c.decodeIfPresent(Bool.self, forKey: .fieldDepartment) ?? true
        fieldJiraKey = try c.decodeIfPresent(Bool.self, forKey: .fieldJiraKey) ?? true
        fieldStatus = try c.decodeIfPresent(Bool.self, forKey: .fieldStatus) ?? true
        fieldAssignee = try c.decodeIfPresent(Bool.self, forKey: .fieldAssignee) ?? false
    }
}
