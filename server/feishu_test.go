package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestFeishuReportExcludesCurrentMemberIssues(t *testing.T) {
	today := time.Now().Format("2006-01-02")
	reporterID := "member-max"
	reporterName := "Max"
	otherReporter := "Alice"
	payload := SyncPayload{
		CurrentMemberID:   reporterID,
		CurrentMemberName: reporterName,
		FeishuBotConfig: &FeishuBotConfig{
			MessageFormat:    "消息卡片",
			FocusIssueTag:    "今日Bug",
			ShowOverview:     true,
			ShowPending:      true,
			ShowResolved:     true,
			ShowMyReported:   true,
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
				ID:           "mine-by-id",
				IssueNumber:  1,
				Type:         "Bug",
				Title:        "my private bug",
				DateKey:      today,
				CreatedAt:    FlexTime{Value: today + " 09:00:00"},
				Status:       StatusPending,
				ReporterID:   &reporterID,
				ReporterName: &otherReporter,
				IssueTags:    []string{"今日Bug"},
			},
			{
				ID:           "mine-by-name",
				IssueNumber:  2,
				Type:         "Bug",
				Title:        "my name bug",
				DateKey:      today,
				CreatedAt:    FlexTime{Value: today + " 10:00:00"},
				Status:       StatusTesting,
				ReporterName: &reporterName,
				IssueTags:    []string{"今日Bug"},
			},
			{
				ID:           "team-bug",
				IssueNumber:  3,
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
	if len(stats.newIssues) != 1 || stats.newIssues[0].ID != "team-bug" {
		t.Fatalf("expected only team issue in new issues, got %+v", stats.newIssues)
	}
	if len(stats.myReported) != 0 {
		t.Fatalf("current member issues should not be pushed as myReported, got %+v", stats.myReported)
	}
	if len(stats.focusTagged) != 1 || stats.focusTagged[0].ID != "team-bug" {
		t.Fatalf("expected only team issue in focus tag section, got %+v", stats.focusTagged)
	}

	body := buildCardMessage(payload, payload.FeishuBotConfig)
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal card: %v", err)
	}
	text := string(data)
	if strings.Contains(text, "my private bug") || strings.Contains(text, "my name bug") {
		t.Fatalf("current member issues leaked into feishu card: %s", text)
	}
	if !strings.Contains(text, "team visible bug") {
		t.Fatalf("team issue missing from feishu card: %s", text)
	}
	if strings.Contains(text, "我今日提交") {
		t.Fatalf("my reported section should not be present in feishu card: %s", text)
	}
}
