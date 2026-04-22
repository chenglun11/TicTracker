package main

import "encoding/json"

type SyncPayload struct {
	LastModified         float64                          `json:"lastModified"`
	Departments          []string                         `json:"departments,omitempty"`
	Records              map[string]map[string]int        `json:"records,omitempty"`
	DailyNotes           map[string]string                `json:"dailyNotes,omitempty"`
	TapTimestamps        map[string]map[string][]string   `json:"tapTimestamps,omitempty"`
	TrackedIssues        []TrackedIssue                   `json:"trackedIssues,omitempty"`
	BugTeamMembers       []string                         `json:"bugTeamMembers,omitempty"`
	JiraConfig           json.RawMessage                  `json:"jiraConfig,omitempty"`
	FeishuBotConfig      *FeishuBotConfig                 `json:"feishuBotConfig,omitempty"`
	FeishuWebhookSecrets map[string]string                `json:"feishuWebhookSecrets,omitempty"`
	AIConfig             json.RawMessage                  `json:"aiConfig,omitempty"`
	RSSFeeds             json.RawMessage                  `json:"rssFeeds,omitempty"`
	TodoTasks            json.RawMessage                  `json:"todoTasks,omitempty"`
}

type TrackedIssue struct {
	ID             string         `json:"id"`
	IssueNumber    int            `json:"issueNumber"`
	Type           string         `json:"type"`
	Title          string         `json:"title"`
	DateKey        string         `json:"dateKey"`
	CreatedAt      string         `json:"createdAt"`
	UpdatedAt      *string        `json:"updatedAt,omitempty"`
	DiaryBadge     string         `json:"diaryBadge"`
	Status         string         `json:"status"`
	Source         string         `json:"source"`
	Assignee       *string        `json:"assignee,omitempty"`
	JiraKey        *string        `json:"jiraKey,omitempty"`
	TicketURL      *string        `json:"ticketURL,omitempty"`
	Department     *string        `json:"department,omitempty"`
	Comments       []IssueComment `json:"comments"`
	ResolvedAt     *string        `json:"resolvedAt,omitempty"`
	HasDevActivity bool           `json:"hasDevActivity"`
}

type IssueComment struct {
	ID            string  `json:"id"`
	Text          string  `json:"text"`
	CreatedAt     string  `json:"createdAt"`
	JiraCommentID *string `json:"jiraCommentId,omitempty"`
}

type FeishuWebhook struct {
	ID          string `json:"id"`
	URL         string `json:"url"`
	SignEnabled bool   `json:"signEnabled"`
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
	ShowSupportStats    bool              `json:"showSupportStats"`
	ShowOverview        bool              `json:"showOverview"`
	ShowPending         bool              `json:"showPending"`
	ShowObserving       bool              `json:"showObserving"`
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
