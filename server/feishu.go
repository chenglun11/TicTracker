package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net/http"
	"strings"
	"time"
)

// feishuHTTPClient 出站 HTTP 客户端（带超时）
var feishuHTTPClient = &http.Client{Timeout: 15 * time.Second}

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
	if issue.IssueNumber > 0 {
		title = fmt.Sprintf("#%d %s", issue.IssueNumber, issue.Title)
	}
	meta := []string{}
	if cfg.FieldType && issue.Type != "" {
		meta = append(meta, issue.Type)
	}
	if cfg.FieldDepartment && issue.Department != nil && *issue.Department != "" {
		meta = append(meta, *issue.Department)
	}
	if cfg.FieldJiraKey {
		if issue.JiraKey != nil && *issue.JiraKey != "" {
			meta = append(meta, *issue.JiraKey)
		} else if issue.TicketURL != nil && *issue.TicketURL != "" {
			meta = append(meta, *issue.TicketURL)
		}
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

// reportStats 日报中各状态分组结果
type reportStats struct {
	newIssues     []TrackedIssue
	resolvedToday []TrackedIssue
	pending       []TrackedIssue
	scheduled     []TrackedIssue
	testing       []TrackedIssue
	observing     []TrackedIssue
	todayTotal    int
	todayNote     string
}

func calcStats(payload SyncPayload) reportStats {
	today := time.Now().Format("2006-01-02")
	stats := reportStats{}
	for _, issue := range payload.TrackedIssues {
		isResolved := isResolvedStatus(issue.Status)
		if issue.DateKey == today && !isResolved {
			stats.newIssues = append(stats.newIssues, issue)
		}
		if issue.ResolvedAt != nil && strings.HasPrefix(issue.ResolvedAt.Value, today) {
			stats.resolvedToday = append(stats.resolvedToday, issue)
		}
		switch issue.Status {
		case StatusScheduled:
			stats.scheduled = append(stats.scheduled, issue)
		case StatusTesting:
			stats.testing = append(stats.testing, issue)
		case StatusObserving:
			stats.observing = append(stats.observing, issue)
		default:
			if !isResolved {
				stats.pending = append(stats.pending, issue)
			}
		}
	}
	if payload.Records != nil {
		if rec, ok := payload.Records[today]; ok {
			for _, v := range rec {
				stats.todayTotal += v
			}
		}
	}
	if payload.DailyNotes != nil {
		stats.todayNote = payload.DailyNotes[today]
	}
	return stats
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

// reportSection 日报中的一个可选段
type reportSection struct {
	title  string
	items  []TrackedIssue
	shown  bool
	header string // 用于 rich text 的纯文本标题；空则使用 title 去掉 markdown
}

// collectSections 按配置生成各段（仅保留 shown=true 且 items 非空的段）
func collectSections(stats reportStats, cfg *FeishuBotConfig) []reportSection {
	raw := []reportSection{
		{title: fmt.Sprintf("**待处理问题（%d个）**", len(stats.pending)), header: fmt.Sprintf("待处理问题（%d个）", len(stats.pending)), items: stats.pending, shown: cfg.ShowPending},
		{title: fmt.Sprintf("**👁 观测中（%d个）**", len(stats.observing)), header: fmt.Sprintf("观测中（%d个）", len(stats.observing)), items: stats.observing, shown: cfg.ShowObserving},
		{title: fmt.Sprintf("**📅 已排期问题（%d个）**", len(stats.scheduled)), header: fmt.Sprintf("已排期问题（%d个）", len(stats.scheduled)), items: stats.scheduled, shown: cfg.ShowScheduled},
		{title: fmt.Sprintf("**🧪 测试中问题（%d个）**", len(stats.testing)), header: fmt.Sprintf("测试中问题（%d个）", len(stats.testing)), items: stats.testing, shown: cfg.ShowTesting},
		{title: fmt.Sprintf("**今日解决（%d个）**", len(stats.resolvedToday)), header: fmt.Sprintf("今日解决（%d个）", len(stats.resolvedToday)), items: stats.resolvedToday, shown: cfg.ShowResolved},
	}
	out := make([]reportSection, 0, len(raw))
	for _, s := range raw {
		if s.shown && len(s.items) > 0 {
			out = append(out, s)
		}
	}
	return out
}

func buildCardElements(payload SyncPayload, cfg *FeishuBotConfig) []map[string]interface{} {
	today := time.Now().Format("2006-01-02")
	now := time.Now().Format("2006-01-02 15:04")
	stats := calcStats(payload)

	elements := []map[string]interface{}{}

	// 日期 + 项目支持
	dateLine := fmt.Sprintf("**日期：** %s", today)
	if cfg.ShowSupportStats {
		if supportStats := buildSupportStats(payload); supportStats != "" {
			dateLine += "\n" + supportStats
		}
	}
	elements = append(elements, map[string]interface{}{
		"tag":  "div",
		"text": map[string]interface{}{"tag": "lark_md", "content": dateLine},
	})
	elements = append(elements, map[string]interface{}{"tag": "hr"})

	// 概览
	if cfg.ShowOverview {
		overview := fmt.Sprintf("🟢 **今日新建** %d 个  ·  ✅ **今日解决** %d 个  ·  🔶 **待处理** %d 个",
			len(stats.newIssues), len(stats.resolvedToday), len(stats.pending))
		if len(stats.observing) > 0 {
			overview += fmt.Sprintf("  ·  👁 **观测中** %d 个", len(stats.observing))
		}
		elements = append(elements, map[string]interface{}{
			"tag":  "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": overview},
		})
	}

	// 各分组段
	for _, sec := range collectSections(stats, cfg) {
		elements = append(elements, map[string]interface{}{"tag": "hr"})
		lines := []string{sec.title}
		for _, issue := range sec.items {
			lines = append(lines, formatIssue(issue, cfg))
		}
		elements = append(elements, map[string]interface{}{
			"tag":  "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": strings.Join(lines, "\n")},
		})
	}

	// 日报备注
	if cfg.ShowDailyNote && stats.todayNote != "" {
		elements = append(elements, map[string]interface{}{"tag": "hr"})
		elements = append(elements, map[string]interface{}{
			"tag":  "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": "**日报备注：**\n" + stats.todayNote},
		})
	}

	noteText := "由 TicTracker 自动生成 | " + now
	if cfg.WebPortalURL != "" {
		noteText += " | 查看详情: " + cfg.WebPortalURL
	}
	noteElements := []map[string]interface{}{
		{"tag": "plain_text", "content": noteText},
	}

	elements = append(elements, map[string]interface{}{"tag": "hr"})
	elements = append(elements, map[string]interface{}{
		"tag":      "note",
		"elements": noteElements,
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
	stats := calcStats(payload)

	rows := [][]map[string]interface{}{}
	addRow := func(text string) {
		rows = append(rows, []map[string]interface{}{{"tag": "text", "text": text}})
	}

	if cfg.ShowOverview {
		addRow(fmt.Sprintf("今日新建 %d 个 · 今日解决 %d 个 · 待处理 %d 个",
			len(stats.newIssues), len(stats.resolvedToday), len(stats.pending)))
	}
	for _, sec := range collectSections(stats, cfg) {
		addRow(sec.header)
		for _, issue := range sec.items {
			addRow(formatIssue(issue, cfg))
		}
	}
	if cfg.ShowDailyNote && stats.todayNote != "" {
		addRow("日报备注：" + stats.todayNote)
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
	stats := calcStats(payload)

	issueLines := func(issues []TrackedIssue) string {
		lines := []string{}
		for _, issue := range issues {
			lines = append(lines, formatIssue(issue, cfg))
		}
		return strings.Join(lines, "\n")
	}

	statsStr := buildSupportStats(payload)

	tpl := cfg.CustomTemplate
	replacements := map[string]string{
		"{{日期}}":     today,
		"{{今日总数}}":   fmt.Sprintf("%d", stats.todayTotal),
		"{{项目统计}}":   statsStr,
		"{{新建数量}}":   fmt.Sprintf("%d", len(stats.newIssues)),
		"{{解决数量}}":   fmt.Sprintf("%d", len(stats.resolvedToday)),
		"{{待处理数量}}":  fmt.Sprintf("%d", len(stats.pending)),
		"{{观测中数量}}":  fmt.Sprintf("%d", len(stats.observing)),
		"{{已排期数量}}":  fmt.Sprintf("%d", len(stats.scheduled)),
		"{{测试中数量}}":  fmt.Sprintf("%d", len(stats.testing)),
		"{{待处理列表}}":  issueLines(stats.pending),
		"{{已解决列表}}":  issueLines(stats.resolvedToday),
		"{{观测中列表}}":  issueLines(stats.observing),
		"{{已排期列表}}":  issueLines(stats.scheduled),
		"{{测试中列表}}":  issueLines(stats.testing),
		"{{日报内容}}":   stats.todayNote,
		"{{当前时间}}":   now,
	}
	for k, v := range replacements {
		tpl = strings.ReplaceAll(tpl, k, v)
	}

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
			"tag":  "div",
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

// 飞书群机器人常见不可重试错误码
// 参考 https://open.feishu.cn/document/uAjLw4CM/ukTMukTMukTM/bot-v2/im-v1/message/create
var nonRetriableFeishuCodes = map[int]bool{
	19021: true, // 签名校验失败
	19022: true, // 时间戳过期
	19024: true, // IP 不在白名单
	9499:  true, // 参数错误
}

func sendOneWebhook(ctx context.Context, webhook FeishuWebhook, body map[string]interface{}, secret string, maxRetries int) error {
	// 每个 webhook 独立深拷贝 body，避免共享子层引用污染
	webhookBody := make(map[string]interface{}, len(body)+2)
	for k, v := range body {
		webhookBody[k] = v
	}

	if webhook.SignEnabled {
		if strings.TrimSpace(secret) == "" {
			return fmt.Errorf("sign enabled but secret missing for webhook %s", webhook.ID)
		}
		ts := fmt.Sprintf("%d", time.Now().Unix())
		webhookBody["timestamp"] = ts
		webhookBody["sign"] = generateSign(ts, secret)
	}

	data, err := json.Marshal(webhookBody)
	if err != nil {
		return fmt.Errorf("marshal body: %w", err)
	}

	if maxRetries < 1 {
		maxRetries = 1
	}

	const baseDelay = 2 * time.Second
	const maxDelay = 30 * time.Second

	var lastErr error
	for attempt := 0; attempt < maxRetries; attempt++ {
		if attempt > 0 {
			delay := baseDelay * time.Duration(1<<attempt)
			if delay > maxDelay {
				delay = maxDelay
			}
			jitter := time.Duration(rand.Intn(500)) * time.Millisecond
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay + jitter):
			}
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhook.URL, bytes.NewReader(data))
		if err != nil {
			return fmt.Errorf("build request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := feishuHTTPClient.Do(req)
		if err != nil {
			lastErr = err
			continue
		}

		var result struct {
			Code int    `json:"code"`
			Msg  string `json:"msg"`
		}
		decErr := json.NewDecoder(resp.Body).Decode(&result)
		// 完整排干 body 便于 keep-alive 连接复用
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()

		if decErr != nil && result.Code == 0 && resp.StatusCode == http.StatusOK {
			return nil
		}
		if resp.StatusCode == http.StatusOK && result.Code == 0 {
			return nil
		}

		lastErr = fmt.Errorf("feishu error: status=%d code=%d msg=%s",
			resp.StatusCode, result.Code, result.Msg)

		// 鉴权/参数类错误不要重试
		if resp.StatusCode == http.StatusUnauthorized ||
			resp.StatusCode == http.StatusForbidden ||
			resp.StatusCode == http.StatusBadRequest ||
			nonRetriableFeishuCodes[result.Code] {
			return lastErr
		}
		// 其它错误（含 429 / 5xx / 99991663 rate limit）继续退避重试
	}
	return lastErr
}

func sendFeishuReport(ctx context.Context, payload SyncPayload) error {
	cfg := payload.FeishuBotConfig
	if cfg == nil || !cfg.Enabled {
		return fmt.Errorf("feishu bot not configured or disabled")
	}

	// 获取 webhook 列表（支持新旧格式）
	webhooks := cfg.Webhooks
	if len(webhooks) == 0 && cfg.WebhookURL != "" {
		webhooks = []FeishuWebhook{
			{ID: "default", URL: cfg.WebhookURL, SignEnabled: cfg.SignEnabled},
		}
	}

	activeWebhooks := make([]FeishuWebhook, 0, len(webhooks))
	for _, webhook := range webhooks {
		if webhook.SendEnabled() && strings.TrimSpace(webhook.URL) != "" {
			activeWebhooks = append(activeWebhooks, webhook)
		}
	}
	if len(activeWebhooks) == 0 {
		return fmt.Errorf("no enabled webhooks configured")
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

	successCount := 0
	failCount := 0
	for _, webhook := range activeWebhooks {
		secret := ""
		if webhook.SignEnabled && payload.FeishuWebhookSecrets != nil {
			secret = payload.FeishuWebhookSecrets[webhook.ID]
		}
		if err := sendOneWebhook(ctx, webhook, body, secret, maxRetries); err != nil {
			failCount++
			slog.Warn("feishu webhook send failed", "webhook_id", webhook.ID, "err", err)
		} else {
			successCount++
		}
	}

	if successCount == 0 {
		return fmt.Errorf("all webhooks failed")
	}
	if failCount > 0 {
		slog.Warn("feishu partial webhook failures", "failed", failCount, "total", len(activeWebhooks))
	}
	return nil
}
