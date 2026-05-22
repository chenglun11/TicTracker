package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestFeishuReportIncludesAllIssues(t *testing.T) {
	today := time.Now().Format("2006-01-02")
	reporterName := "Max"
	otherReporter := "Alice"
	payload := SyncPayload{
		CurrentMemberID:   "member-max",
		CurrentMemberName: reporterName,
		FeishuBotConfig: &FeishuBotConfig{
			MessageFormat:    "消息卡片",
			FocusIssueTag:    "今日Bug",
			ShowOverview:     true,
			ShowPending:      true,
			ShowResolved:     true,
			ShowFocusTag:     true,
			FieldStatus:      true,
			FieldType:        true,
			FieldDepartment:  true,
			FieldJiraKey:     true,
			FieldAssignee:    true,
			ShowSupportStats: true,
		},
		TrackedIssues: []TrackedIssue{
			{
				ID:           "mine-by-name",
				IssueNumber:  1,
				Type:         "Bug",
				Title:        "my own bug",
				DateKey:      today,
				CreatedAt:    FlexTime{Value: today + " 09:00:00"},
				Status:       StatusPending,
				ReporterName: &reporterName,
				IssueTags:    []string{"今日Bug"},
			},
			{
				ID:           "team-bug",
				IssueNumber:  2,
				Type:         "Bug",
				Title:        "team visible bug",
				DateKey:      today,
				CreatedAt:    FlexTime{Value: today + " 11:00:00"},
				Status:       StatusPending,
				ReporterName: &otherReporter,
				IssueTags:    []string{"今日Bug"},
			},
		},
	}

	stats := calcStats(payload)
	if len(stats.newIssues) != 2 {
		t.Fatalf("expected 2 new issues (including self-reported), got %d: %+v", len(stats.newIssues), stats.newIssues)
	}
	if len(stats.focusTagged) != 2 {
		t.Fatalf("expected 2 focus tagged issues, got %d: %+v", len(stats.focusTagged), stats.focusTagged)
	}

	body := buildCardMessage(payload, payload.FeishuBotConfig)
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal card: %v", err)
	}
	text := string(data)
	if !strings.Contains(text, "my own bug") {
		t.Fatalf("self-reported issue should appear in feishu card: %s", text)
	}
	if !strings.Contains(text, "team visible bug") {
		t.Fatalf("team issue missing from feishu card: %s", text)
	}
}
