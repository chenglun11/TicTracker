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
	"sort"
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

func formatIssue(issue TrackedIssue, cfg *FeishuBotConfig, includeTimes ...bool) string {
	parts := []string{}
	if cfg.FieldStatus {
		parts = append(parts, issue.Status)
	}
	title := issue.Title
	if issue.IssueNumber > 0 {
		title = fmt.Sprintf("#%d %s", issue.IssueNumber, issue.Title)
	}
	meta := []string{}
	if len(includeTimes) > 0 && includeTimes[0] {
		meta = append(meta, issueTimelineText(issue))
	}
	if cfg.FieldType && issue.Type != "" {
		meta = append(meta, issue.Type)
	}
	if cfg.FieldDepartment && issue.Department != nil && *issue.Department != "" {
		meta = append(meta, *issue.Department)
	}
	if cfg.FieldJiraKey {
		if linear := formatLinearIssueReference(issue); linear != "" {
			meta = append(meta, linear)
		} else if issue.JiraKey != nil && *issue.JiraKey != "" {
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

func issueTimelineText(issue TrackedIssue) string {
	created := issueTimeText(issue.CreatedAt)
	latest := issueLatestActivityTime(issue)
	if created == "" {
		created = latest.Format("2006-01-02 15:04")
	}
	updated := latest.Format("2006-01-02 15:04")
	return fmt.Sprintf("创建 %s · 更新 %s", created, updated)
}

func issueTimeText(value FlexTime) string {
	if t, ok := parseIssueTime(value.Value); ok {
		return t.Format("2006-01-02 15:04")
	}
	return strings.TrimSpace(value.Value)
}

func issueLatestActivityTime(issue TrackedIssue) time.Time {
	latest := time.Time{}
	if t, ok := parseIssueTime(issue.CreatedAt.Value); ok {
		latest = t
	}
	if issue.ReportedAt != nil {
		if t, ok := parseIssueTime(issue.ReportedAt.Value); ok && t.After(latest) {
			latest = t
		}
	}
	if issue.UpdatedAt != nil {
		if t, ok := parseIssueTime(issue.UpdatedAt.Value); ok && t.After(latest) {
			latest = t
		}
	}
	if issue.ResolvedAt != nil {
		if t, ok := parseIssueTime(issue.ResolvedAt.Value); ok && t.After(latest) {
			latest = t
		}
	}
	for _, comment := range issue.Comments {
		if t, ok := parseIssueTime(comment.CreatedAt.Value); ok && t.After(latest) {
			latest = t
		}
	}
	if latest.IsZero() {
		return time.Now()
	}
	return latest
}

func formatLinearIssueReference(issue TrackedIssue) string {
	key := strings.TrimSpace(ptrValue(issue.LinearKey))
	url := strings.TrimSpace(ptrValue(issue.LinearURL))
	if key == "" && url != "" {
		if idx := strings.LastIndex(strings.TrimRight(url, "/"), "/"); idx >= 0 && idx < len(strings.TrimRight(url, "/"))-1 {
			key = strings.TrimRight(url, "/")[idx+1:]
		}
		if key == "" {
			key = "Linear"
		}
	}
	if key == "" {
		key = strings.TrimSpace(ptrValue(issue.LinearIssueID))
	}
	if key == "" {
		return ""
	}
	if url != "" {
		return fmt.Sprintf("[%s](%s)", key, url)
	}
	return key
}

// reportStats 日报中各状态分组结果
type reportStats struct {
	newIssues     []TrackedIssue
	resolvedToday []TrackedIssue
	pending       []TrackedIssue
	scheduled     []TrackedIssue
	testing       []TrackedIssue
	observing     []TrackedIssue
	focusTagged   []TrackedIssue
	focusTag      string
	todayTotal    int
	todayNote     string
}

func calcStats(payload SyncPayload) reportStats {
	today := time.Now().Format("2006-01-02")
	stats := reportStats{}
	focusTag := strings.TrimSpace(payload.FeishuBotConfig.FocusIssueTag)
	if focusTag == "" {
		focusTag = "今日Bug"
	}
	stats.focusTag = focusTag
	for _, issue := range payload.TrackedIssues {
		isResolved := isResolvedStatus(issue.Status)
		if issue.DateKey == today && !isResolved {
			stats.newIssues = append(stats.newIssues, issue)
		}
		if issueHasTag(issue, focusTag) {
			stats.focusTagged = append(stats.focusTagged, issue)
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

func issueHasTag(issue TrackedIssue, tag string) bool {
	if tag == "" {
		return false
	}
	for _, issueTag := range issue.IssueTags {
		if issueTag == tag {
			return true
		}
	}
	return false
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
		{title: fmt.Sprintf("**今日重点（%s，%d个）**", stats.focusTag, len(stats.focusTagged)), header: fmt.Sprintf("今日重点（%s，%d个）", stats.focusTag, len(stats.focusTagged)), items: stats.focusTagged, shown: cfg.ShowFocusTag && stats.focusTag != ""},
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

	// 日期
	dateLine := fmt.Sprintf("**日期：** %s", today)
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
		if len(issues) == 0 {
			return "无"
		}
		lines := []string{}
		for _, issue := range issues {
			lines = append(lines, formatIssue(issue, cfg))
		}
		return strings.Join(lines, "\n")
	}

	statsStr := buildSupportStats(payload)

	tpl := removeSupportStatsLines(cfg.CustomTemplate)
	replacements := map[string]string{
		"{{日期}}":    today,
		"{{今日总数}}":  fmt.Sprintf("%d", stats.todayTotal),
		"{{项目统计}}":  statsStr,
		"{{新建数量}}":  fmt.Sprintf("%d", len(stats.newIssues)),
		"{{解决数量}}":  fmt.Sprintf("%d", len(stats.resolvedToday)),
		"{{待处理数量}}": fmt.Sprintf("%d", len(stats.pending)),
		"{{观测中数量}}": fmt.Sprintf("%d", len(stats.observing)),
		"{{已排期数量}}": fmt.Sprintf("%d", len(stats.scheduled)),
		"{{测试中数量}}": fmt.Sprintf("%d", len(stats.testing)),
		"{{待处理列表}}": issueLines(stats.pending),
		"{{已解决列表}}": issueLines(stats.resolvedToday),
		"{{观测中列表}}": issueLines(stats.observing),
		"{{已排期列表}}": issueLines(stats.scheduled),
		"{{测试中列表}}": issueLines(stats.testing),
		"{{重点Tag}}": stats.focusTag,
		"{{重点列表}}":  issueLines(stats.focusTagged),
		"{{日报内容}}":  stats.todayNote,
		"{{当前时间}}":  now,
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
	added := 0
	for _, seg := range segments {
		trimmed := strings.TrimSpace(seg)
		if trimmed == "" {
			continue
		}
		if added > 0 {
			elements = append(elements, map[string]interface{}{"tag": "hr"})
		}
		elements = append(elements, map[string]interface{}{
			"tag":  "div",
			"text": map[string]interface{}{"tag": "lark_md", "content": trimmed},
		})
		added++
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

type issueMonthlyReportData struct {
	title                 string
	subtitle              string
	comparisonSubtitle    string
	issues                []TrackedIssue
	openIssues            []TrackedIssue
	resolvedIssues        []TrackedIssue
	updatedTotal          int
	previousCreatedTotal  int
	previousResolvedTotal int
	previousOpenTotal     int
	previousStaleTotal    int
	closureRate           int
	previousClosureRate   int
	staleOpen             []TrackedIssue
	unassignedOpen        []TrackedIssue
	typeTotals            [][2]interface{}
	statusTotals          [][2]interface{}
	assigneeTotals        [][2]interface{}
	analysisNotes         []string
}

func monthRange(period string, now time.Time) (time.Time, time.Time) {
	loc := now.Location()
	currentStart := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, loc)
	if period == "previous" {
		end := currentStart.AddDate(0, 0, -1)
		start := time.Date(end.Year(), end.Month(), 1, 0, 0, 0, 0, loc)
		return start, end
	}
	return currentStart, time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)
}

func parseIssueTime(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, false
	}
	layouts := []string{
		time.RFC3339,
		"2006-01-02 15:04:05",
		"2006-01-02 15:04",
		"2006-01-02",
	}
	for _, layout := range layouts {
		if t, err := time.ParseInLocation(layout, value, time.Local); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

func primaryIssueTime(issue TrackedIssue) (time.Time, bool) {
	if issue.ReportedAt != nil {
		if t, ok := parseIssueTime(issue.ReportedAt.Value); ok {
			return t, true
		}
	}
	if t, ok := parseIssueTime(issue.CreatedAt.Value); ok {
		return t, true
	}
	if strings.TrimSpace(issue.DateKey) != "" {
		if t, ok := parseIssueTime(issue.DateKey); ok {
			return t, true
		}
	}
	return time.Time{}, false
}

func removeSupportStatsLines(text string) string {
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.Contains(trimmed, "项目支持") || strings.Contains(trimmed, "{{项目统计}}") || strings.Contains(trimmed, "{{今日总数}}") {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func issueDateKey(issue TrackedIssue) string {
	if t, ok := primaryIssueTime(issue); ok {
		return t.Format("2006-01-02")
	}
	return ""
}

func issueInMonthRange(issue TrackedIssue, start, endExclusive time.Time) bool {
	if t, ok := primaryIssueTime(issue); ok {
		return !t.Before(start) && t.Before(endExclusive)
	}
	return false
}

func normalizedIssueAssignee(issue TrackedIssue) string {
	if issue.Assignee != nil && strings.TrimSpace(*issue.Assignee) != "" {
		return strings.TrimSpace(*issue.Assignee)
	}
	if issue.LinearAssignee != nil && strings.TrimSpace(*issue.LinearAssignee) != "" {
		return strings.TrimSpace(*issue.LinearAssignee)
	}
	return "未分配"
}

func reportUpdateComment(comment IssueComment) bool {
	text := strings.TrimSpace(comment.Text)
	if text == "" {
		return false
	}
	return !strings.HasPrefix(text, "[Linear] 已导入") && !strings.HasPrefix(text, "[Linear] 已通过链接导入")
}

func hasIssueUpdateInRange(issue TrackedIssue, startKey, endKey string) bool {
	createdKey := issueDateKey(issue)
	resolvedKey := ""
	if issue.ResolvedAt != nil {
		if t, ok := parseIssueTime(issue.ResolvedAt.Value); ok {
			resolvedKey = t.Format("2006-01-02")
		}
	}
	for _, comment := range issue.Comments {
		if !reportUpdateComment(comment) {
			continue
		}
		t, ok := parseIssueTime(comment.CreatedAt.Value)
		if !ok {
			continue
		}
		key := t.Format("2006-01-02")
		if key >= startKey && key <= endKey && key != createdKey && key != resolvedKey {
			return true
		}
	}
	return false
}

func sortedCountPairs(counts map[string]int, preferred []string) [][2]interface{} {
	out := make([][2]interface{}, 0, len(counts))
	used := map[string]bool{}
	for _, key := range preferred {
		if count := counts[key]; count > 0 {
			out = append(out, [2]interface{}{key, count})
			used[key] = true
		}
	}
	rest := make([]string, 0, len(counts))
	for key, count := range counts {
		if count > 0 && !used[key] {
			rest = append(rest, key)
		}
	}
	sort.Slice(rest, func(i, j int) bool {
		if counts[rest[i]] == counts[rest[j]] {
			return rest[i] < rest[j]
		}
		return counts[rest[i]] > counts[rest[j]]
	})
	for _, key := range rest {
		out = append(out, [2]interface{}{key, counts[key]})
	}
	return out
}

func compactCountPairs(pairs [][2]interface{}, limit int) string {
	if limit > 0 && len(pairs) > limit {
		pairs = pairs[:limit]
	}
	parts := make([]string, 0, len(pairs))
	for _, pair := range pairs {
		parts = append(parts, fmt.Sprintf("%s %d", pair[0], pair[1]))
	}
	return strings.Join(parts, "，")
}

func shareText(count, total int) string {
	if total <= 0 {
		return "0%"
	}
	return fmt.Sprintf("%d%%", int(float64(count)/float64(total)*100+0.5))
}

func collectIssueMonthlyReport(payload SyncPayload, period string) issueMonthlyReportData {
	now := time.Now()
	start, end := monthRange(period, now)
	display := func(t time.Time) string { return t.Format("1/2") }

	type periodStats struct {
		issues         []TrackedIssue
		openIssues     []TrackedIssue
		resolvedIssues []TrackedIssue
		updatedTotal   int
		staleOpen      []TrackedIssue
		unassignedOpen []TrackedIssue
		typeTotals     [][2]interface{}
		statusTotals   [][2]interface{}
		assigneeTotals [][2]interface{}
		closureRate    int
	}

	collectStats := func(start, end time.Time) periodStats {
		endExclusive := end.AddDate(0, 0, 1)
		startKey := start.Format("2006-01-02")
		endKey := end.Format("2006-01-02")

		issues := make([]TrackedIssue, 0)
		for _, issue := range payload.TrackedIssues {
			if issueInMonthRange(issue, start, endExclusive) {
				issues = append(issues, issue)
			}
		}
		sort.SliceStable(issues, func(i, j int) bool {
			leftResolved := isResolvedStatus(issues[i].Status)
			rightResolved := isResolvedStatus(issues[j].Status)
			if leftResolved != rightResolved {
				return !leftResolved
			}
			leftTime, leftOK := primaryIssueTime(issues[i])
			rightTime, rightOK := primaryIssueTime(issues[j])
			if leftOK && rightOK {
				return leftTime.After(rightTime)
			}
			return issueDateKey(issues[i]) > issueDateKey(issues[j])
		})

		openIssues := make([]TrackedIssue, 0)
		for _, issue := range payload.TrackedIssues {
			if isResolvedStatus(issue.Status) {
				continue
			}
			if t, ok := primaryIssueTime(issue); ok && t.Before(endExclusive) {
				openIssues = append(openIssues, issue)
			}
		}
		sort.SliceStable(openIssues, func(i, j int) bool {
			if openIssues[i].IsEscalated != openIssues[j].IsEscalated {
				return openIssues[i].IsEscalated
			}
			leftTime, leftOK := primaryIssueTime(openIssues[i])
			rightTime, rightOK := primaryIssueTime(openIssues[j])
			if leftOK && rightOK {
				return leftTime.Before(rightTime)
			}
			return issueDateKey(openIssues[i]) < issueDateKey(openIssues[j])
		})

		resolvedIssues := make([]TrackedIssue, 0)
		typeCounts := map[string]int{}
		statusCounts := map[string]int{}
		assigneeCounts := map[string]int{}
		updatedTotal := 0
		for _, issue := range issues {
			typeCounts[issue.Type]++
			statusCounts[issue.Status]++
			assigneeCounts[normalizedIssueAssignee(issue)]++
			if hasIssueUpdateInRange(issue, startKey, endKey) {
				updatedTotal++
			}
			if isResolvedStatus(issue.Status) {
				resolvedIssues = append(resolvedIssues, issue)
			}
		}

		referenceDate := time.Now()
		if referenceDate.After(endExclusive) {
			referenceDate = endExclusive
		}
		staleThreshold := referenceDate.AddDate(0, 0, -7)
		staleOpen := make([]TrackedIssue, 0)
		unassignedOpen := make([]TrackedIssue, 0)
		for _, issue := range openIssues {
			if normalizedIssueAssignee(issue) == "未分配" {
				unassignedOpen = append(unassignedOpen, issue)
			}
			if t, ok := primaryIssueTime(issue); ok && t.Before(staleThreshold) && issue.Status != StatusObserving {
				staleOpen = append(staleOpen, issue)
			}
		}

		closureRate := 0
		if len(issues) > 0 {
			closureRate = int(float64(len(resolvedIssues))/float64(len(issues))*100 + 0.5)
		}

		return periodStats{
			issues:         issues,
			openIssues:     openIssues,
			resolvedIssues: resolvedIssues,
			updatedTotal:   updatedTotal,
			staleOpen:      staleOpen,
			unassignedOpen: unassignedOpen,
			typeTotals:     sortedCountPairs(typeCounts, []string{"Bug", "Feature", "Support"}),
			statusTotals:   sortedCountPairs(statusCounts, []string{StatusPending, "处理中", StatusTesting, StatusScheduled, StatusObserving, StatusResolved, StatusIgnored}),
			assigneeTotals: sortedCountPairs(assigneeCounts, nil),
			closureRate:    closureRate,
		}
	}

	previousEnd := start.AddDate(0, 0, -1)
	previousStart := time.Date(previousEnd.Year(), previousEnd.Month(), 1, 0, 0, 0, 0, previousEnd.Location())
	current := collectStats(start, end)
	previous := collectStats(previousStart, previousEnd)

	deltaText := func(current, previous int) string {
		delta := current - previous
		switch {
		case delta > 0:
			return fmt.Sprintf("+%d", delta)
		case delta < 0:
			return fmt.Sprintf("%d", delta)
		default:
			return "持平"
		}
	}
	deltaPP := func(current, previous int) string {
		delta := current - previous
		switch {
		case delta > 0:
			return fmt.Sprintf("+%dpp", delta)
		case delta < 0:
			return fmt.Sprintf("%dpp", delta)
		default:
			return "持平"
		}
	}

	analysis := []string{}
	net := len(current.issues) - len(current.resolvedIssues)
	analysis = append(analysis, fmt.Sprintf("较上月：新增 %s，已关闭 %s，未关闭 %s，积压 %s。",
		deltaText(len(current.issues), len(previous.issues)),
		deltaText(len(current.resolvedIssues), len(previous.resolvedIssues)),
		deltaText(len(current.openIssues), len(previous.openIssues)),
		deltaText(len(current.staleOpen), len(previous.staleOpen)),
	))
	analysis = append(analysis, fmt.Sprintf("本期新增 %d 个，已关闭 %d 个，关闭率 %d%%（较上月 %s）。",
		len(current.issues), len(current.resolvedIssues), current.closureRate, deltaPP(current.closureRate, previous.closureRate)))
	if net > 0 {
		analysis = append(analysis, fmt.Sprintf("月末未关闭 %d 个，净增加 %d 个，积压压力上升。", len(current.openIssues), net))
	} else if net < 0 {
		analysis = append(analysis, fmt.Sprintf("月末未关闭 %d 个，净减少 %d 个，问题消化速度较好。", len(current.openIssues), -net))
	} else {
		analysis = append(analysis, fmt.Sprintf("新增与关闭持平，月末未关闭 %d 个。", len(current.openIssues)))
	}
	if len(current.typeTotals) > 0 {
		analysis = append(analysis, fmt.Sprintf("%s 是本期最高频类型，占 %s。", current.typeTotals[0][0], shareText(current.typeTotals[0][1].(int), len(current.issues))))
	}
	if len(current.assigneeTotals) > 0 && current.assigneeTotals[0][0] != "未分配" {
		analysis = append(analysis, fmt.Sprintf("%s 承接最多问题，共 %d 个。", current.assigneeTotals[0][0], current.assigneeTotals[0][1]))
	}
	if len(current.staleOpen) > 0 {
		analysis = append(analysis, fmt.Sprintf("%d 个未关闭问题已超过 7 天，建议优先复盘。", len(current.staleOpen)))
	}
	if len(current.unassignedOpen) > 0 {
		analysis = append(analysis, fmt.Sprintf("%d 个未关闭问题未分配负责人。", len(current.unassignedOpen)))
	}

	return issueMonthlyReportData{
		title:                 "问题追踪月报",
		subtitle:              fmt.Sprintf("%s - %s", display(start), display(end)),
		comparisonSubtitle:    fmt.Sprintf("%s - %s", display(previousStart), display(previousEnd)),
		issues:                current.issues,
		openIssues:            current.openIssues,
		resolvedIssues:        current.resolvedIssues,
		updatedTotal:          current.updatedTotal,
		previousCreatedTotal:  len(previous.issues),
		previousResolvedTotal: len(previous.resolvedIssues),
		previousOpenTotal:     len(previous.openIssues),
		previousStaleTotal:    len(previous.staleOpen),
		closureRate:           current.closureRate,
		previousClosureRate:   previous.closureRate,
		staleOpen:             current.staleOpen,
		unassignedOpen:        current.unassignedOpen,
		typeTotals:            current.typeTotals,
		statusTotals:          current.statusTotals,
		assigneeTotals:        current.assigneeTotals,
		analysisNotes:         analysis,
	}
}

func prioritizedIssueMonthlyFocusIssues(data issueMonthlyReportData) []TrackedIssue {
	out := []TrackedIssue{}
	seen := map[string]bool{}
	stale := map[string]bool{}
	for _, issue := range data.staleOpen {
		stale[issue.ID] = true
	}
	appendIssues := func(issues []TrackedIssue) {
		for _, issue := range issues {
			if stale[issue.ID] || seen[issue.ID] {
				continue
			}
			seen[issue.ID] = true
			out = append(out, issue)
		}
	}
	appendIssues(data.unassignedOpen)
	appendIssues(data.openIssues)
	return out
}

func buildIssueMonthlyCardMessage(payload SyncPayload, cfg *FeishuBotConfig, period string) map[string]interface{} {
	data := collectIssueMonthlyReport(payload, period)
	elements := []map[string]interface{}{
		{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": fmt.Sprintf("**周期：** %s\n**对比上月：** %s", data.subtitle, data.comparisonSubtitle)}},
		{"tag": "hr"},
		{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": fmt.Sprintf("🟦 **本期新增** %d 个（上月 %d）  ·  ✅ **已关闭** %d 个（上月 %d）\n🔶 **未关闭** %d 个（上月 %d）  ·  🟣 **积压** %d 个（上月 %d）  ·  🟢 **更新** %d 个",
			len(data.issues), data.previousCreatedTotal, len(data.resolvedIssues), data.previousResolvedTotal, len(data.openIssues), data.previousOpenTotal, len(data.staleOpen), data.previousStaleTotal, data.updatedTotal)}},
	}

	if len(data.analysisNotes) > 0 {
		lines := make([]string, 0, len(data.analysisNotes))
		for _, note := range data.analysisNotes {
			lines = append(lines, "- "+note)
		}
		elements = append(elements,
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": "**分析摘要：**\n" + strings.Join(lines, "\n")}},
		)
	}

	distLines := []string{}
	if s := compactCountPairs(data.typeTotals, 0); s != "" {
		distLines = append(distLines, "**类型分布：** "+s)
	}
	if s := compactCountPairs(data.statusTotals, 0); s != "" {
		distLines = append(distLines, "**状态分布：** "+s)
	}
	if s := compactCountPairs(data.assigneeTotals, 8); s != "" {
		distLines = append(distLines, "**负责人 Top 8：** "+s)
	}
	if len(distLines) > 0 {
		elements = append(elements,
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": strings.Join(distLines, "\n")}},
		)
	}

	focusIssues := prioritizedIssueMonthlyFocusIssues(data)
	if len(focusIssues) > 0 {
		lines := []string{"**重点问题（最多 8 条）：**"}
		limit := len(focusIssues)
		if limit > 8 {
			limit = 8
		}
		for _, issue := range focusIssues[:limit] {
			lines = append(lines, formatIssue(issue, cfg, true))
		}
		if len(focusIssues) > limit {
			lines = append(lines, fmt.Sprintf("_其余 %d 条重点问题已省略，请打开问题月报查看详情。_", len(focusIssues)-limit))
		}
		elements = append(elements,
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": strings.Join(lines, "\n")}},
		)
	}

	if len(data.staleOpen) > 0 {
		lines := []string{"**积压问题（超过 7 天未关闭，最多 8 条）：**"}
		limit := len(data.staleOpen)
		if limit > 8 {
			limit = 8
		}
		for _, issue := range data.staleOpen[:limit] {
			lines = append(lines, formatIssue(issue, cfg, true))
		}
		if len(data.staleOpen) > limit {
			lines = append(lines, fmt.Sprintf("_其余 %d 条积压问题已省略，请打开问题月报查看详情。_", len(data.staleOpen)-limit))
		}
		elements = append(elements,
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": strings.Join(lines, "\n")}},
		)
	}

	if len(data.issues) == 0 {
		elements = append(elements,
			map[string]interface{}{"tag": "hr"},
			map[string]interface{}{"tag": "div", "text": map[string]interface{}{"tag": "lark_md", "content": "本期暂无问题记录"}},
		)
	}

	noteText := "由 TicTracker 自动生成 | " + time.Now().Format("2006-01-02 15:04")
	if cfg.WebPortalURL != "" {
		noteText += " | 查看详情: " + cfg.WebPortalURL
	}
	elements = append(elements, map[string]interface{}{"tag": "note", "elements": []map[string]interface{}{{"tag": "plain_text", "content": noteText}}})

	return map[string]interface{}{
		"msg_type": "interactive",
		"card": map[string]interface{}{
			"config": map[string]interface{}{"wide_screen_mode": true},
			"header": map[string]interface{}{
				"title":    map[string]interface{}{"tag": "plain_text", "content": data.title},
				"template": "purple",
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
	return sendFeishuBody(ctx, payload, cfg, body)
}

func sendFeishuIssueMonthlyReport(ctx context.Context, payload SyncPayload, period string) error {
	cfg := payload.FeishuBotConfig
	if cfg == nil || !cfg.Enabled {
		return fmt.Errorf("feishu bot not configured or disabled")
	}
	return sendFeishuBody(ctx, payload, cfg, buildIssueMonthlyCardMessage(payload, cfg, period))
}

func sendFeishuBody(ctx context.Context, payload SyncPayload, cfg *FeishuBotConfig, body map[string]interface{}) error {
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
