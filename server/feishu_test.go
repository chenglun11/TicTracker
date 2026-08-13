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

func TestFeishuIssueFormattingIncludesLinearReference(t *testing.T) {
	linearKey := "LIN-139"
	linearURL := "https://linear.app/acme/issue/LIN-139/senddirectly-auth-failure"
	jiraKey := "JIRA-1"
	issue := TrackedIssue{
		IssueNumber: 139,
		Type:        "Feature",
		Title:       "[SendDirectly] 增加授信失败API发信拦截",
		Status:      StatusPending,
		LinearKey:   &linearKey,
		LinearURL:   &linearURL,
		JiraKey:     &jiraKey,
	}

	got := formatIssue(issue, &FeishuBotConfig{
		FieldStatus:  true,
		FieldType:    true,
		FieldJiraKey: true,
	})
	if !strings.Contains(got, "[LIN-139](https://linear.app/acme/issue/LIN-139/senddirectly-auth-failure)") {
		t.Fatalf("Linear reference missing from formatted issue: %s", got)
	}
	if strings.Contains(got, "JIRA-1") {
		t.Fatalf("Linear should take precedence over Jira in formatted issue: %s", got)
	}
}

func TestFeishuReportSeparatesPendingAcceptanceInEveryMessageFormat(t *testing.T) {
	today := time.Now().Format("2006-01-02")
	cfg := &FeishuBotConfig{
		ShowOverview:          true,
		ShowPending:           true,
		ShowPendingAcceptance: true,
		FieldStatus:           true,
		CustomTemplate: "待处理 {{待处理数量}} 个\n{{待处理列表}}\n---\n" +
			"待验收 {{待验收数量}} 个\n{{待验收列表}}",
	}
	payload := SyncPayload{
		FeishuBotConfig: cfg,
		TrackedIssues: []TrackedIssue{
			{
				ID:          "pending",
				IssueNumber: 1,
				Title:       "pending only",
				DateKey:     today,
				CreatedAt:   FlexTime{Value: today + " 09:00:00"},
				Status:      StatusPending,
			},
			{
				ID:          "pending-acceptance",
				IssueNumber: 2,
				Title:       "acceptance only",
				DateKey:     today,
				CreatedAt:   FlexTime{Value: today + " 10:00:00"},
				Status:      StatusPendingAcceptance,
			},
		},
	}

	stats := calcStats(payload)
	if len(stats.pending) != 1 || stats.pending[0].ID != "pending" {
		t.Fatalf("pending bucket should exclude pending acceptance: %+v", stats.pending)
	}
	if len(stats.pendingAcceptance) != 1 || stats.pendingAcceptance[0].ID != "pending-acceptance" {
		t.Fatalf("pending acceptance bucket mismatch: %+v", stats.pendingAcceptance)
	}

	assertMessageContains := func(name string, body map[string]interface{}, values ...string) {
		t.Helper()
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal %s message: %v", name, err)
		}
		text := string(data)
		for _, value := range values {
			if !strings.Contains(text, value) {
				t.Errorf("%s message missing %q: %s", name, value, text)
			}
		}
	}

	assertMessageContains("card", buildCardMessage(payload, cfg),
		"待处理问题（1个）", "待验收问题（1个）", "acceptance only")
	assertMessageContains("post", buildPostMessage(payload, cfg),
		"待处理问题（1个）", "待验收问题（1个）", "acceptance only")
	assertMessageContains("template", buildTemplateMessage(payload, cfg),
		"待处理 1 个", "pending only", "待验收 1 个", "acceptance only")

	summaryStats := BuildStatusSummary(&payload, time.Now())["statistics"].(map[string]int)
	if summaryStats["pending"] != 1 || summaryStats["pendingAcceptance"] != 1 {
		t.Fatalf("status summary did not separate pending acceptance: %+v", summaryStats)
	}
	if got := filterIssuesForMCP(payload.TrackedIssues, "pending"); len(got) != 1 || got[0].ID != "pending" {
		t.Fatalf("MCP pending filter included pending acceptance: %+v", got)
	}
	if got := filterIssuesForMCP(payload.TrackedIssues, "pendingAcceptance"); len(got) != 1 || got[0].ID != "pending-acceptance" {
		t.Fatalf("MCP pendingAcceptance filter mismatch: %+v", got)
	}
}
