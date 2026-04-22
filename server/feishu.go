package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

func generateSign(timestamp string, secret string) string {
	stringToSign := timestamp + "\n" + secret
	mac := hmac.New(sha256.New, []byte(stringToSign))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func formatIssue(issue TrackedIssue, cfg *FeishuBotConfig) string {
	parts := []string{}
	if cfg.FieldStatus {
		parts = append(parts, issue.Status)
	}
	title := issue.Title
	meta := []string{}
	if cfg.FieldType && issue.Type != "" {
		meta = append(meta, issue.Type)
	}
	if cfg.FieldDepartment && issue.Department != nil && *issue.Department != "" {
		meta = append(meta, *issue.Department)
	}
	if cfg.FieldJiraKey && issue.JiraKey != nil && *issue.JiraKey != "" {
		meta = append(meta, *issue.JiraKey)
	}
	if cfg.FieldAssignee && issue.Assignee != nil && *issue.Assignee != "" {
		meta = append(meta, *issue.Assignee)
	}
	line := "- "
	if len(parts) > 0 {
		line += "[" + strings.Join(parts, "/") + "] "
	}
	line += title
	if len(meta) > 0 {
		line += " (" + strings.Join(meta, " · ") + ")"
	}
	return line
}

func calcStats(payload SyncPayload) (newIssues, resolvedToday, pending, observing []TrackedIssue, todayTotal int, todayNote string) {
	today := time.Now().Format("2006-01-02")
	for _, issue := range payload.TrackedIssues {
		isResolved := issue.Status == "已修复" || issue.Status == "已忽略"
		if issue.DateKey == today && !isResolved {
			newIssues = append(newIssues, issue)
		}
		if issue.ResolvedAt != nil && strings.HasPrefix(*issue.ResolvedAt, today) {
			resolvedToday = append(resolvedToday, issue)
		}
		if !isResolved && issue.Status != "观测中" {
			pending = append(pending, issue)
		}
		if issue.Status == "观测中" {
			observing = append(observing, issue)
		}
	}
	if payload.Records != nil {
		if rec, ok := payload.Records[today]; ok {
			for _, v := range rec {
				todayTotal += v
			}
		}
	}
	if payload.DailyNotes != nil {
		todayNote = payload.DailyNotes[today]
	}
	return
}

func buildSupportStats(payload SyncPayload) string {
	today := time.Now().Format("2006-01-02")
	if payload.Records == nil {
		return ""
	}
	rec, ok := payload.Records[today]
	if !ok || len(rec) == 0 {
		return ""
	}
	total := 0
	parts := []string{}
	for dept, cnt := range rec {
		parts = append(parts, fmt.Sprintf("%s %d次", dept, cnt))
		total += cnt
	}
	return fmt.Sprintf("**项目支持：** %s（共%d次）", strings.Join(parts, "，"), total)
}

func buildCardElements(payload SyncPayload, cfg *FeishuBotConfig) []map[string]interface{} {
	today := time.Now().Format("2006-01-02")
	now := time.Now().Format("2006-01-02 15:04")
	newIssues, resolvedToday, pending, observing, todayTotal, todayNote := calcStats(payload)

	elements := []map[string]interface{}{}

	// 日期 + 项目支持
	dateLine := fmt.Sprintf("**日期：** %s", today)
	if cfg.ShowSupportStats {
		if stats := buildSupportStats(payload); stats != "" {
			dateLine += "\n" + stats
		}
	}
	elements = append(elements, map[string]interface{}{
		"tag": "div",
		"text": map[string]interface{}{"tag": "lark_md", "content": dateLine},
	})
	elements = append(elements, map[string]interface{}{"tag": "hr"})

	// 概览
	if cfg.ShowOverview {
		overview := fmt.Sprintf("🟢 **今日新建** %d 个  ·  ✅ **今日解决** %d 个  ·  🔶 **待处理** %d 个", len(newIssues), len(resolvedToday), len(pending))
		elements = append(elements, map[string]interface{}{
			"tag": "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": overview},
		})
	}

	// 待处理
	if cfg.ShowPending && len(pending) > 0 {
		elements = append(elements, map[string]interface{}{"tag": "hr"})
		lines := []string{fmt.Sprintf("**待处理问题（%d个）**", len(pending))}
		for _, issue := range pending {
			lines = append(lines, formatIssue(issue, cfg))
		}
		elements = append(elements, map[string]interface{}{
			"tag": "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": strings.Join(lines, "\n")},
		})
	}

	// 观测中
	if cfg.ShowObserving && len(observing) > 0 {
		elements = append(elements, map[string]interface{}{"tag": "hr"})
		lines := []string{fmt.Sprintf("**观测中（%d个）**", len(observing))}
		for _, issue := range observing {
			lines = append(lines, formatIssue(issue, cfg))
		}
		elements = append(elements, map[string]interface{}{
			"tag": "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": strings.Join(lines, "\n")},
		})
	}

	// 已解决
	if cfg.ShowResolved && len(resolvedToday) > 0 {
		elements = append(elements, map[string]interface{}{"tag": "hr"})
		lines := []string{fmt.Sprintf("**今日解决（%d个）**", len(resolvedToday))}
		for _, issue := range resolvedToday {
			lines = append(lines, formatIssue(issue, cfg))
		}
		elements = append(elements, map[string]interface{}{
			"tag": "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": strings.Join(lines, "\n")},
		})
	}

	// 日报备注
	if cfg.ShowDailyNote && todayNote != "" {
		elements = append(elements, map[string]interface{}{"tag": "hr"})
		elements = append(elements, map[string]interface{}{
			"tag": "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": "**日报备注：**\n" + todayNote},
		})
	}

	_ = todayTotal

	elements = append(elements, map[string]interface{}{"tag": "hr"})
	elements = append(elements, map[string]interface{}{
		"tag": "note",
		"elements": []map[string]interface{}{
			{"tag": "plain_text", "content": "由 TicTracker 自动生成 | " + now},
		},
	})
	return elements
}

func buildCardMessage(payload SyncPayload, cfg *FeishuBotConfig) map[string]interface{} {
	title := cfg.CardTitle
	if title == "" {
		title = "技术支持日报"
	}
	return map[string]interface{}{
		"msg_type": "interactive",
		"card": map[string]interface{}{
			"config": map[string]interface{}{"wide_screen_mode": true},
			"header": map[string]interface{}{
				"title":    map[string]interface{}{"tag": "plain_text", "content": title},
				"template": "blue",
			},
			"elements": buildCardElements(payload, cfg),
		},
	}
}

func buildPostMessage(payload SyncPayload, cfg *FeishuBotConfig) map[string]interface{} {
	today := time.Now().Format("2006-01-02")
	title := cfg.CardTitle
	if title == "" {
		title = "技术支持日报"
	}
	newIssues, resolvedToday, pending, observing, _, todayNote := calcStats(payload)

	rows := [][]map[string]interface{}{}
	addRow := func(text string) {
		rows = append(rows, []map[string]interface{}{{"tag": "text", "text": text}})
	}

	if cfg.ShowOverview {
		addRow(fmt.Sprintf("今日新建 %d 个 · 今日解决 %d 个 · 待处理 %d 个", len(newIssues), len(resolvedToday), len(pending)))
	}
	if cfg.ShowPending && len(pending) > 0 {
		addRow(fmt.Sprintf("待处理问题（%d个）", len(pending)))
		for _, issue := range pending {
			addRow(formatIssue(issue, cfg))
		}
	}
	if cfg.ShowObserving && len(observing) > 0 {
		addRow(fmt.Sprintf("观测中（%d个）", len(observing)))
		for _, issue := range observing {
			addRow(formatIssue(issue, cfg))
		}
	}
	if cfg.ShowResolved && len(resolvedToday) > 0 {
		addRow(fmt.Sprintf("今日解决（%d个）", len(resolvedToday)))
		for _, issue := range resolvedToday {
			addRow(formatIssue(issue, cfg))
		}
	}
	if cfg.ShowDailyNote && todayNote != "" {
		addRow("日报备注：" + todayNote)
	}

	return map[string]interface{}{
		"msg_type": "post",
		"content": map[string]interface{}{
			"post": map[string]interface{}{
				"zh_cn": map[string]interface{}{
					"title":   fmt.Sprintf("%s（%s）", title, today),
					"content": rows,
				},
			},
		},
	}
}

func buildTemplateMessage(payload SyncPayload, cfg *FeishuBotConfig) map[string]interface{} {
	today := time.Now().Format("2006-01-02")
	now := time.Now().Format("2006-01-02 15:04")
	newIssues, resolvedToday, pending, observing, todayTotal, todayNote := calcStats(payload)

	issueLines := func(issues []TrackedIssue) string {
		lines := []string{}
		for _, issue := range issues {
			lines = append(lines, formatIssue(issue, cfg))
		}
		return strings.Join(lines, "\n")
	}

	statsStr := buildSupportStats(payload)

	tpl := cfg.CustomTemplate
	tpl = strings.ReplaceAll(tpl, "{{日期}}", today)
	tpl = strings.ReplaceAll(tpl, "{{今日总数}}", fmt.Sprintf("%d", todayTotal))
	tpl = strings.ReplaceAll(tpl, "{{项目统计}}", statsStr)
	tpl = strings.ReplaceAll(tpl, "{{新建数量}}", fmt.Sprintf("%d", len(newIssues)))
	tpl = strings.ReplaceAll(tpl, "{{解决数量}}", fmt.Sprintf("%d", len(resolvedToday)))
	tpl = strings.ReplaceAll(tpl, "{{待处理数量}}", fmt.Sprintf("%d", len(pending)))
	tpl = strings.ReplaceAll(tpl, "{{观测中数量}}", fmt.Sprintf("%d", len(observing)))
	tpl = strings.ReplaceAll(tpl, "{{待处理列表}}", issueLines(pending))
	tpl = strings.ReplaceAll(tpl, "{{已解决列表}}", issueLines(resolvedToday))
	tpl = strings.ReplaceAll(tpl, "{{观测中列表}}", issueLines(observing))
	tpl = strings.ReplaceAll(tpl, "{{日报内容}}", todayNote)
	tpl = strings.ReplaceAll(tpl, "{{当前时间}}", now)

	title := cfg.CustomTemplateTitle
	if title == "" {
		title = cfg.CardTitle
	}
	if title == "" {
		title = "技术支持日报"
	}

	segments := strings.Split(tpl, "\n---\n")
	elements := []map[string]interface{}{}
	for i, seg := range segments {
		if i > 0 {
			elements = append(elements, map[string]interface{}{"tag": "hr"})
		}
		elements = append(elements, map[string]interface{}{
			"tag": "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": seg},
		})
	}

	return map[string]interface{}{
		"msg_type": "interactive",
		"card": map[string]interface{}{
			"config": map[string]interface{}{"wide_screen_mode": true},
			"header": map[string]interface{}{
				"title":    map[string]interface{}{"tag": "plain_text", "content": title},
				"template": "blue",
			},
			"elements": elements,
		},
	}
}

func sendFeishuReport(payload SyncPayload) error {
	cfg := payload.FeishuBotConfig
	if cfg == nil || !cfg.Enabled {
		return fmt.Errorf("feishu bot not configured or disabled")
	}

	// 获取 webhook 列表（支持新旧格式）
	webhooks := cfg.Webhooks
	if len(webhooks) == 0 && cfg.WebhookURL != "" {
		// 向后兼容：使用旧的 WebhookURL
		webhooks = []FeishuWebhook{
			{
				ID:          "default",
				URL:         cfg.WebhookURL,
				SignEnabled: cfg.SignEnabled,
			},
		}
	}

	if len(webhooks) == 0 {
		return fmt.Errorf("no webhooks configured")
	}

	// 构建消息体
	var body map[string]interface{}
	switch cfg.MessageFormat {
	case "富文本":
		body = buildPostMessage(payload, cfg)
	case "自定义模板":
		body = buildTemplateMessage(payload, cfg)
	default:
		body = buildCardMessage(payload, cfg)
	}

	maxRetries := cfg.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 1
	}

	client := &http.Client{Timeout: 15 * time.Second}
	successCount := 0
	failCount := 0

	// 遍历每个 webhook 发送
	for _, webhook := range webhooks {
		// 为每个 webhook 准备独立的消息体（需要独立签名）
		webhookBody := make(map[string]interface{})
		for k, v := range body {
			webhookBody[k] = v
		}

		// 如果该 webhook 启用签名，添加签名
		if webhook.SignEnabled {
			secret := ""
			if payload.FeishuWebhookSecrets != nil {
				secret = payload.FeishuWebhookSecrets[webhook.ID]
			}
			if secret != "" {
				ts := fmt.Sprintf("%d", time.Now().Unix())
				webhookBody["timestamp"] = ts
				webhookBody["sign"] = generateSign(ts, secret)
			}
			// 如果找不到 secret，跳过签名但不阻止发送
		}

		data, err := json.Marshal(webhookBody)
		if err != nil {
			failCount++
			continue
		}

		// 重试逻辑
		var lastErr error
		sent := false
		for i := 0; i < maxRetries; i++ {
			if i > 0 {
				time.Sleep(5 * time.Second)
			}
			resp, err := client.Post(webhook.URL, "application/json", bytes.NewReader(data))
			if err != nil {
				lastErr = err
				continue
			}
			var result struct {
				Code int    `json:"code"`
				Msg  string `json:"msg"`
			}
			json.NewDecoder(resp.Body).Decode(&result)
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK || result.Code != 0 {
				lastErr = fmt.Errorf("feishu error: status=%d code=%d msg=%s", resp.StatusCode, result.Code, result.Msg)
				continue
			}
			sent = true
			break
		}

		if sent {
			successCount++
		} else {
			failCount++
			fmt.Printf("[feishu] failed to send to webhook %s: %v\n", webhook.ID, lastErr)
		}
	}

	// 返回结果
	if successCount == 0 {
		return fmt.Errorf("all webhooks failed")
	}
	if failCount > 0 {
		fmt.Printf("[feishu] warning: %d/%d webhooks failed\n", failCount, len(webhooks))
	}
	return nil
}
