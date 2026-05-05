package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestFlexTimeUnmarshalString(t *testing.T) {
	var f FlexTime
	if err := json.Unmarshal([]byte(`"2024-01-02 03:04:05"`), &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if f.Value != "2024-01-02 03:04:05" {
		t.Errorf("Value=%q", f.Value)
	}
}

func TestFlexTimeUnmarshalNumber(t *testing.T) {
	// Apple epoch: seconds since 2001-01-01 UTC
	var f FlexTime
	if err := json.Unmarshal([]byte(`0`), &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	// 2001-01-01 00:00:00 UTC，本地时区会换算
	if f.Value == "" {
		t.Error("expected non-empty Value for number input")
	}
}

func TestFlexTimeMarshalRoundtripPreservesRaw(t *testing.T) {
	cases := []string{
		`"2024-05-01 12:00:00"`,
		`12345`,
	}
	for _, in := range cases {
		var f FlexTime
		if err := json.Unmarshal([]byte(in), &f); err != nil {
			t.Fatalf("unmarshal %s: %v", in, err)
		}
		out, err := json.Marshal(f)
		if err != nil {
			t.Fatalf("marshal %s: %v", in, err)
		}
		if string(out) != in {
			t.Errorf("roundtrip differs: in=%s out=%s", in, string(out))
		}
	}
}

func TestFlexTimeUnmarshalFallback(t *testing.T) {
	// 不期望的输入应被宽容处理（保留 raw，不 panic）
	var f FlexTime
	if err := json.Unmarshal([]byte(`{"weird":"object"}`), &f); err != nil {
		t.Fatalf("should not error, got %v", err)
	}
	if f.Value == "" {
		t.Error("Value should fall back to string repr")
	}
}

func TestFlexTimeMarshalEmpty(t *testing.T) {
	var f FlexTime
	out, err := json.Marshal(f)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if string(out) != `""` {
		t.Errorf("empty FlexTime should marshal as empty string, got %s", string(out))
	}
}

func TestFeishuWebhookSendEnabled(t *testing.T) {
	yes := true
	no := false
	cases := []struct {
		w    FeishuWebhook
		want bool
	}{
		{FeishuWebhook{Enabled: nil}, true},
		{FeishuWebhook{Enabled: &yes}, true},
		{FeishuWebhook{Enabled: &no}, false},
	}
	for _, tc := range cases {
		if got := tc.w.SendEnabled(); got != tc.want {
			t.Errorf("SendEnabled(%+v)=%v, want %v", tc.w, got, tc.want)
		}
	}
}

func TestStatusConstants(t *testing.T) {
	// 防止有人不小心改了状态字符串导致客户端不兼容
	expected := map[string]string{
		"StatusPending":   "待处理",
		"StatusScheduled": "已排期",
		"StatusTesting":   "测试中",
		"StatusObserving": "观测中",
		"StatusResolved":  "已修复",
		"StatusIgnored":   "已忽略",
	}
	got := map[string]string{
		"StatusPending":   StatusPending,
		"StatusScheduled": StatusScheduled,
		"StatusTesting":   StatusTesting,
		"StatusObserving": StatusObserving,
		"StatusResolved":  StatusResolved,
		"StatusIgnored":   StatusIgnored,
	}
	for k, want := range expected {
		if got[k] != want {
			t.Errorf("%s changed: got %q, want %q (Swift 客户端依赖该字面量)", k, got[k], want)
		}
	}
}

func TestIsResolvedStatus(t *testing.T) {
	cases := map[string]bool{
		StatusResolved:  true,
		StatusIgnored:   true,
		StatusPending:   false,
		StatusScheduled: false,
		StatusTesting:   false,
		StatusObserving: false,
		"":              false,
	}
	for status, want := range cases {
		if got := isResolvedStatus(status); got != want {
			t.Errorf("isResolvedStatus(%q)=%v, want %v", status, got, want)
		}
	}
}

func TestApplyIssueStatusSetsResolvedAt(t *testing.T) {
	issue := &TrackedIssue{Status: StatusPending}
	applyIssueStatus(issue, StatusResolved)
	if issue.ResolvedAt == nil {
		t.Error("ResolvedAt should be set when status -> resolved")
	}
	applyIssueStatus(issue, StatusPending)
	if issue.ResolvedAt != nil {
		t.Error("ResolvedAt should be cleared when status -> pending")
	}
}

func TestFeishuBotConfigDecodeNewFields(t *testing.T) {
	in := []byte(`{
		"enabled": true,
		"appID": "cli_xxx",
		"appSecret": "ssss",
		"verificationToken": "vvvv",
		"encryptKey": "kkkk",
		"allowedChatIDs": ["oc_a","oc_b"]
	}`)
	var cfg FeishuBotConfig
	if err := json.Unmarshal(in, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if cfg.AppSecret != "ssss" || cfg.VerificationToken != "vvvv" || cfg.EncryptKey != "kkkk" {
		t.Errorf("new fields lost: %+v", cfg)
	}
	if len(cfg.AllowedChatIDs) != 2 || cfg.AllowedChatIDs[0] != "oc_a" {
		t.Errorf("AllowedChatIDs decode failed: %+v", cfg.AllowedChatIDs)
	}
}

func TestSyncPayloadOmitsNilOptional(t *testing.T) {
	p := SyncPayload{LastModified: 1}
	data, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), "feishuBotConfig") {
		t.Error("nil FeishuBotConfig should be omitted")
	}
}
