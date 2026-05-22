package main

import (
	"crypto/rand"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type SetupResponse struct {
	Initialized       bool     `json:"initialized"`
	Departments       []string `json:"departments"`
	TeamMembers       []string `json:"teamMembers"`
	CurrentMemberName string   `json:"currentMemberName"`
	Feishu            struct {
		Enabled                  bool   `json:"enabled"`
		WebhookCount             int    `json:"webhookCount"`
		WebhookSecretConfigured  bool   `json:"webhookSecretConfigured"`
		SendTime                 string `json:"sendTime"`
		FocusIssueTag            string `json:"focusIssueTag"`
		AppID                    string `json:"appID"`
		AppSecretConfigured      bool   `json:"appSecretConfigured"`
		VerificationTokenPresent bool   `json:"verificationTokenPresent"`
		EncryptKeyPresent        bool   `json:"encryptKeyPresent"`
		TasklistGUID             string `json:"tasklistGUID"`
	} `json:"feishu"`
	Linear struct {
		Enabled     bool   `json:"enabled"`
		TeamID      string `json:"teamId"`
		TeamName    string `json:"teamName"`
		ProjectID   string `json:"projectId"`
		ProjectName string `json:"projectName"`
	} `json:"linear"`
}

type SetupRequest struct {
	Departments       []string `json:"departments"`
	TeamMembers       []string `json:"teamMembers"`
	CurrentMemberName string   `json:"currentMemberName"`
	Feishu            struct {
		Enabled           bool   `json:"enabled"`
		WebhookURL        string `json:"webhookURL"`
		WebhookSecret     string `json:"webhookSecret"`
		SendHour          int    `json:"sendHour"`
		SendMinute        int    `json:"sendMinute"`
		FocusIssueTag     string `json:"focusIssueTag"`
		AppID             string `json:"appID"`
		AppSecret         string `json:"appSecret"`
		VerificationToken string `json:"verificationToken"`
		EncryptKey        string `json:"encryptKey"`
		TasklistGUID      string `json:"tasklistGUID"`
	} `json:"feishu"`
	Linear struct {
		Enabled     bool   `json:"enabled"`
		TeamID      string `json:"teamId"`
		TeamName    string `json:"teamName"`
		ProjectID   string `json:"projectId"`
		ProjectName string `json:"projectName"`
	} `json:"linear"`
}

func HandleGetSetup(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := store.Load(c.Request.Context())
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read setup"})
			return
		}
		c.JSON(http.StatusOK, buildSetupResponse(payload))
	}
}

func HandlePutSetup(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body SetupRequest
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}

		err := store.Update(c.Request.Context(), func(payload *SyncPayload) error {
			applySetup(payload, body)
			return nil
		})
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save setup"})
			return
		}

		payload, _ := store.Load(c.Request.Context())
		c.JSON(http.StatusOK, buildSetupResponse(payload))
	}
}

func buildSetupResponse(payload *SyncPayload) SetupResponse {
	var res SetupResponse
	res.Departments = payload.Departments
	res.TeamMembers = setupTeamMemberNames(payload)
	res.CurrentMemberName = payload.CurrentMemberName
	res.Initialized = payload.CurrentMemberName != "" || len(res.TeamMembers) > 0 || len(payload.Departments) > 0 || payload.FeishuBotConfig != nil || len(payload.LinearConfig) > 0

	if payload.FeishuBotConfig != nil {
		cfg := payload.FeishuBotConfig
		res.Feishu.Enabled = cfg.Enabled
		res.Feishu.WebhookCount = len(cfg.Webhooks)
		if len(cfg.Webhooks) > 0 && payload.FeishuWebhookSecrets != nil {
			for _, webhook := range cfg.Webhooks {
				if payload.FeishuWebhookSecrets[webhook.ID] != "" {
					res.Feishu.WebhookSecretConfigured = true
					break
				}
			}
		}
		if len(cfg.SendTimes) > 0 {
			res.Feishu.SendTime = formatScheduleTime(cfg.SendTimes[0])
		}
		res.Feishu.FocusIssueTag = cfg.FocusIssueTag
		res.Feishu.AppID = cfg.AppID
		res.Feishu.AppSecretConfigured = cfg.AppSecret != ""
		res.Feishu.VerificationTokenPresent = cfg.VerificationToken != ""
		res.Feishu.EncryptKeyPresent = cfg.EncryptKey != ""
		res.Feishu.TasklistGUID = cfg.TasklistGUID
	}

	var linear struct {
		Enabled     bool   `json:"enabled"`
		TeamID      string `json:"teamId"`
		TeamName    string `json:"teamName"`
		ProjectID   string `json:"projectId"`
		ProjectName string `json:"projectName"`
	}
	if len(payload.LinearConfig) > 0 && json.Unmarshal(payload.LinearConfig, &linear) == nil {
		res.Linear.Enabled = linear.Enabled
		res.Linear.TeamID = linear.TeamID
		res.Linear.TeamName = linear.TeamName
		res.Linear.ProjectID = linear.ProjectID
		res.Linear.ProjectName = linear.ProjectName
	}
	return res
}

func applySetup(payload *SyncPayload, req SetupRequest) {
	payload.Departments = normalizeStringList(req.Departments)
	payload.BugTeamMembers = normalizeStringList(req.TeamMembers)
	payload.TeamMembers = setupTeamMembersJSON(payload.BugTeamMembers)
	payload.CurrentMemberName = strings.TrimSpace(req.CurrentMemberName)
	payload.CurrentMemberID = currentMemberIDForName(payload.TeamMembers, payload.CurrentMemberName)

	cfg := payload.FeishuBotConfig
	if cfg == nil {
		cfg = defaultFeishuBotConfig()
		payload.FeishuBotConfig = cfg
	}
	cfg.Enabled = req.Feishu.Enabled
	cfg.FocusIssueTag = strings.TrimSpace(req.Feishu.FocusIssueTag)
	if cfg.FocusIssueTag == "" {
		cfg.FocusIssueTag = "今日Bug"
	}
	cfg.MessageFormat = defaultString(cfg.MessageFormat, "消息卡片")
	cfg.CardTitle = defaultString(cfg.CardTitle, "每日工单报告")
	cfg.MaxRetries = 3
	cfg.AppID = strings.TrimSpace(req.Feishu.AppID)
	if trimmed := strings.TrimSpace(req.Feishu.AppSecret); trimmed != "" {
		cfg.AppSecret = trimmed
	}
	cfg.VerificationToken = strings.TrimSpace(req.Feishu.VerificationToken)
	if trimmed := strings.TrimSpace(req.Feishu.EncryptKey); trimmed != "" {
		cfg.EncryptKey = trimmed
	}
	cfg.TasklistGUID = strings.TrimSpace(req.Feishu.TasklistGUID)
	cfg.ShowSupportStats = true
	cfg.ShowOverview = true
	cfg.ShowPending = true
	cfg.ShowObserving = true
	cfg.ShowScheduled = true
	cfg.ShowTesting = true
	cfg.ShowResolved = true
	cfg.ShowDailyNote = true
	cfg.ShowFocusTag = true
	cfg.ShowComments = true
	cfg.FieldType = true
	cfg.FieldDepartment = true
	cfg.FieldJiraKey = true
	cfg.FieldStatus = true

	webhookURL := strings.TrimSpace(req.Feishu.WebhookURL)
	if webhookURL != "" {
		webhook := FeishuWebhook{ID: stableID("webhook"), URL: webhookURL}
		if strings.TrimSpace(req.Feishu.WebhookSecret) != "" {
			webhook.SignEnabled = true
		}
		cfg.Webhooks = []FeishuWebhook{webhook}
		if payload.FeishuWebhookSecrets == nil {
			payload.FeishuWebhookSecrets = make(map[string]string)
		}
		if secret := strings.TrimSpace(req.Feishu.WebhookSecret); secret != "" {
			payload.FeishuWebhookSecrets[webhook.ID] = secret
		}
	}
	hour := req.Feishu.SendHour
	minute := req.Feishu.SendMinute
	if hour < 0 || hour > 23 {
		hour = 18
	}
	if minute < 0 || minute > 59 {
		minute = 0
	}
	cfg.SendTimes = []ScheduleTime{{ID: stableID("schedule"), Hour: hour, Minute: minute, Weekdays: []int{1, 2, 3, 4, 5}}}

	linear := map[string]any{
		"enabled":          req.Linear.Enabled,
		"teamId":           strings.TrimSpace(req.Linear.TeamID),
		"teamName":         strings.TrimSpace(req.Linear.TeamName),
		"projectId":        strings.TrimSpace(req.Linear.ProjectID),
		"projectName":      strings.TrimSpace(req.Linear.ProjectName),
		"pollingInterval":  10,
		"pollingStartHour": 9,
		"pollingEndHour":   18,
		"statusMapping":    map[string]string{},
		"assigneeMapping":  map[string]string{},
		"labelMapping":     map[string]string{},
		"teamMembers":      []any{},
		"teamLabels":       []any{},
	}
	if data, err := json.Marshal(linear); err == nil {
		payload.LinearConfig = data
	}
}

func setupTeamMemberNames(payload *SyncPayload) []string {
	if len(payload.TeamMembers) > 0 {
		var members []struct {
			Name string `json:"name"`
		}
		if json.Unmarshal(payload.TeamMembers, &members) == nil {
			names := make([]string, 0, len(members))
			for _, member := range members {
				if name := strings.TrimSpace(member.Name); name != "" {
					names = append(names, name)
				}
			}
			if len(names) > 0 {
				return names
			}
		}
	}
	return payload.BugTeamMembers
}

func setupTeamMembersJSON(names []string) json.RawMessage {
	type teamMember struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	members := make([]teamMember, 0, len(names))
	for _, name := range names {
		members = append(members, teamMember{ID: stableID("member:" + name), Name: name})
	}
	data, _ := json.Marshal(members)
	return data
}

func currentMemberIDForName(teamMembers json.RawMessage, name string) string {
	if name == "" || len(teamMembers) == 0 {
		return ""
	}
	var members []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if json.Unmarshal(teamMembers, &members) != nil {
		return ""
	}
	for _, member := range members {
		if member.Name == name {
			return member.ID
		}
	}
	return ""
}

func defaultFeishuBotConfig() *FeishuBotConfig {
	return &FeishuBotConfig{
		MessageFormat:    "消息卡片",
		CardTitle:        "每日工单报告",
		FocusIssueTag:    "今日Bug",
		MaxRetries:       3,
		ShowSupportStats: true,
		ShowOverview:     true,
		ShowPending:      true,
		ShowObserving:    true,
		ShowScheduled:    true,
		ShowTesting:      true,
		ShowResolved:     true,
		ShowDailyNote:    true,
		ShowFocusTag:     true,
		ShowComments:     true,
		FieldType:        true,
		FieldDepartment:  true,
		FieldJiraKey:     true,
		FieldStatus:      true,
	}
}

func normalizeStringList(values []string) []string {
	seen := make(map[string]bool, len(values))
	out := make([]string, 0, len(values))
	for _, raw := range values {
		value := strings.TrimSpace(raw)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}

func stableID(seed string) string {
	var b [8]byte
	if seed != "" {
		sum := sha1.Sum([]byte(seed))
		return hexToUUID(sum[:16])
	}
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func hexToUUID(bytes []byte) string {
	if len(bytes) < 16 {
		return ""
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x50
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	hexed := hex.EncodeToString(bytes[:16])
	return hexed[0:8] + "-" + hexed[8:12] + "-" + hexed[12:16] + "-" + hexed[16:20] + "-" + hexed[20:32]
}

func defaultString(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func formatScheduleTime(st ScheduleTime) string {
	when := time.Date(2000, 1, 1, st.Hour, st.Minute, 0, 0, time.Local)
	return when.Format("15:04")
}
