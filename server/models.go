package main

import (
	"encoding/json"
	"time"
)

// Issue 状态常量，避免中文字面量散落各处
const (
	StatusPending   = "待处理"
	StatusScheduled = "已排期"
	StatusTesting   = "测试中"
	StatusObserving = "观测中"
	StatusResolved  = "已修复"
	StatusIgnored   = "已忽略"
)

type SyncPayload struct {
	LastModified         float64                        `json:"lastModified"`
	Departments          []string                       `json:"departments,omitempty"`
	Records              map[string]map[string]int      `json:"records,omitempty"`
	DailyNotes           map[string]string              `json:"dailyNotes,omitempty"`
	TapTimestamps        map[string]map[string][]string `json:"tapTimestamps,omitempty"`
	TrackedIssues        []TrackedIssue                 `json:"trackedIssues,omitempty"`
	BugTeamMembers       []string                       `json:"bugTeamMembers,omitempty"`
	JiraConfig           json.RawMessage                `json:"jiraConfig,omitempty"`
	FeishuBotConfig      *FeishuBotConfig               `json:"feishuBotConfig,omitempty"`
	FeishuWebhookSecrets map[string]string              `json:"feishuWebhookSecrets,omitempty"`
	AIConfig             json.RawMessage                `json:"aiConfig,omitempty"`
	RSSFeeds             json.RawMessage                `json:"rssFeeds,omitempty"`
	TodoTasks            json.RawMessage                `json:"todoTasks,omitempty"`
}

type TrackedIssue struct {
	ID             string         `json:"id"`
	IssueNumber    int            `json:"issueNumber"`
	Type           string         `json:"type"`
	Title          string         `json:"title"`
	DateKey        string         `json:"dateKey"`
	CreatedAt      FlexTime       `json:"createdAt"`
	UpdatedAt      *FlexTime      `json:"updatedAt,omitempty"`
	DiaryBadge     string         `json:"diaryBadge"`
	Status         string         `json:"status"`
	Source         string         `json:"source"`
	Assignee       *string        `json:"assignee,omitempty"`
	JiraKey        *string        `json:"jiraKey,omitempty"`
	TicketURL      *string        `json:"ticketURL,omitempty"`
	Department     *string        `json:"department,omitempty"`
	Comments       []IssueComment `json:"comments"`
	ResolvedAt     *FlexTime      `json:"resolvedAt,omitempty"`
	HasDevActivity bool           `json:"hasDevActivity"`
	FeishuTaskGUID *string        `json:"feishuTaskGuid,omitempty"`
}

type IssueComment struct {
	ID            string   `json:"id"`
	Text          string   `json:"text"`
	CreatedAt     FlexTime `json:"createdAt"`
	JiraCommentID *string  `json:"jiraCommentId,omitempty"`
}

// FlexTime 兼容 string 和 number 两种 JSON 格式的时间字段，并保留原始格式
type FlexTime struct {
	Value   string
	RawJSON json.RawMessage // 保留原始 JSON 用于序列化
}

func (f FlexTime) MarshalJSON() ([]byte, error) {
	if len(f.RawJSON) > 0 {
		return f.RawJSON, nil
	}
	if f.Value == "" {
		return json.Marshal("")
	}
	return json.Marshal(f.Value)
}

func (f *FlexTime) UnmarshalJSON(data []byte) error {
	f.RawJSON = append(json.RawMessage{}, data...)
	// 尝试 string
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		f.Value = s
		return nil
	}
	// 尝试 number（Swift Date.timeIntervalSinceReferenceDate）
	var n float64
	if err := json.Unmarshal(data, &n); err == nil {
		const appleEpochOffset = 978307200
		ts := int64(n) + appleEpochOffset
		f.Value = time.Unix(ts, 0).Format("2006-01-02 15:04:05")
		return nil
	}
	f.Value = string(data)
	return nil
}

type FeishuWebhook struct {
	ID          string `json:"id"`
	URL         string `json:"url"`
	Enabled     *bool  `json:"enabled,omitempty"`
	SignEnabled bool   `json:"signEnabled"`
}

func (w FeishuWebhook) SendEnabled() bool {
	return w.Enabled == nil || *w.Enabled
}

type FeishuBotConfig struct {
	Enabled             bool              `json:"enabled"`
	WebhookURL          string            `json:"webhookURL"` // 保留向后兼容
	Webhooks            []FeishuWebhook   `json:"webhooks"`
	SignEnabled         bool              `json:"signEnabled"`
	SendTimes           []ScheduleTime    `json:"sendTimes"`
	LastSentTimes       map[string]string `json:"lastSentTimes"`
	LastSentDateTime    string            `json:"lastSentDateTime"`
	MessageFormat       string            `json:"messageFormat"`
	CustomTemplate      string            `json:"customTemplate"`
	CustomTemplateTitle string            `json:"customTemplateTitle"`
	CardTitle           string            `json:"cardTitle"`
	MaxRetries          int               `json:"maxRetries"`
	WebPortalURL        string            `json:"webPortalURL"`
	AppID               string            `json:"appID,omitempty"`
	AppSecret           string            `json:"appSecret,omitempty"`           // 新增：应用密钥（同步方案，优先级低于 yaml/env）
	VerificationToken   string            `json:"verificationToken,omitempty"`   // 新增：飞书事件订阅 verification token
	EncryptKey          string            `json:"encryptKey,omitempty"`          // 新增：飞书事件订阅 encrypt key
	AllowedChatIDs      []string          `json:"allowedChatIDs,omitempty"`      // 新增：机器人命令白名单（空=全部允许）
	TasklistGUID        string            `json:"tasklistGUID,omitempty"`
	ShowSupportStats    bool              `json:"showSupportStats"`
	ShowOverview        bool              `json:"showOverview"`
	ShowPending         bool              `json:"showPending"`
	ShowObserving       bool              `json:"showObserving"`
	ShowScheduled       bool              `json:"showScheduled"`
	ShowTesting         bool              `json:"showTesting"`
	ShowResolved        bool              `json:"showResolved"`
	ShowDailyNote       bool              `json:"showDailyNote"`
	ShowComments        bool              `json:"showComments"`
	FieldType           bool              `json:"fieldType"`
	FieldDepartment     bool              `json:"fieldDepartment"`
	FieldJiraKey        bool              `json:"fieldJiraKey"`
	FieldStatus         bool              `json:"fieldStatus"`
	FieldAssignee       bool              `json:"fieldAssignee"`
}

type ScheduleTime struct {
	ID       string `json:"id"`
	Hour     int    `json:"hour"`
	Minute   int    `json:"minute"`
	Weekdays []int  `json:"weekdays"` // 1=Mon, 7=Sun; empty=every day
}
