package main

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

var feishuSendMu sync.Mutex

var issueIDRegexp = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

var (
	errIssueRevisionConflict = errors.New("issue revision conflict")
	errIssueDeleted          = errors.New("issue deleted")
	errIssueAlreadyClaimed   = errors.New("issue already claimed")
)

func requireIssueRevision(c *gin.Context) (int64, bool) {
	raw := strings.TrimSpace(c.GetHeader("If-Match"))
	if raw == "" {
		c.JSON(http.StatusPreconditionRequired, gin.H{
			"error": "If-Match issue revision is required",
			"code":  "issue_revision_required",
		})
		return 0, false
	}
	raw = strings.TrimPrefix(raw, "W/")
	raw = strings.Trim(raw, "\"")
	revision, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || revision < 1 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid If-Match issue revision", "code": "invalid_issue_revision"})
		return 0, false
	}
	return revision, true
}

func HandleClaimIssue(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if !issueIDRegexp.MatchString(issueID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid issue id"})
			return
		}
		expectedRevision, ok := requireIssueRevision(c)
		if !ok {
			return
		}
		identity, ok := identityFromContext(c.Request.Context())
		if !ok || strings.TrimSpace(identity.DisplayName) == "" {
			c.JSON(http.StatusForbidden, gin.H{"error": "a named workspace member is required", "code": "member_identity_required"})
			return
		}

		found := false
		var current *TrackedIssue
		err := store.Update(c.Request.Context(), func(payload *SyncPayload) error {
			for i := range payload.TrackedIssues {
				issue := &payload.TrackedIssues[i]
				if issue.ID != issueID {
					continue
				}
				if err := prepareIssueMutation(issue, expectedRevision, &current); err != nil {
					return err
				}
				if issue.Assignee != nil && strings.TrimSpace(*issue.Assignee) != "" {
					return errIssueAlreadyClaimed
				}
				assignee := identity.DisplayName
				issue.Assignee = &assignee
				now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
				issue.UpdatedAt = &now
				found = true
				return nil
			}
			return nil
		})
		switch {
		case errors.Is(err, errIssueAlreadyClaimed):
			c.JSON(http.StatusConflict, gin.H{"error": err.Error(), "code": "issue_already_claimed", "current": current})
			return
		case err != nil:
			if writeIssueMutationError(c, err, current) {
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to claim issue"})
			return
		case !found:
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}

		var claimed TrackedIssue
		if payload, loadErr := store.Load(c.Request.Context()); loadErr == nil {
			for _, issue := range payload.TrackedIssues {
				if issue.ID == issueID {
					claimed = issue
					break
				}
			}
		}
		c.Header("ETag", fmt.Sprintf("\"%d\"", claimed.Revision))
		c.JSON(http.StatusOK, gin.H{"success": true, "issue": claimed})
	}
}

func writeIssueMutationError(c *gin.Context, err error, current *TrackedIssue) bool {
	switch {
	case errors.Is(err, errIssueRevisionConflict):
		c.JSON(http.StatusConflict, gin.H{
			"error":   "issue was changed by another client",
			"code":    "issue_revision_conflict",
			"current": current,
		})
		return true
	case errors.Is(err, errIssueDeleted):
		c.JSON(http.StatusGone, gin.H{"error": "issue was deleted", "code": "issue_deleted", "current": current})
		return true
	default:
		return false
	}
}

func prepareIssueMutation(issue *TrackedIssue, expectedRevision int64, current **TrackedIssue) error {
	normalizeIssueMetadata(issue)
	copyOfCurrent := *issue
	*current = &copyOfCurrent
	if issue.DeletedAt != nil {
		return errIssueDeleted
	}
	if issue.Revision != expectedRevision {
		return errIssueRevisionConflict
	}
	return nil
}

func canSendFeishu(payload *SyncPayload, cooldown time.Duration) (bool, int) {
	if payload.FeishuBotConfig == nil || payload.FeishuBotConfig.LastSentDateTime == "" {
		return true, 0
	}
	lastSent, err := time.Parse("2006-01-02 15:04:05", payload.FeishuBotConfig.LastSentDateTime)
	if err != nil {
		return true, 0
	}
	elapsed := time.Since(lastSent)
	if elapsed >= cooldown {
		return true, 0
	}
	remain := int((cooldown - elapsed).Seconds())
	if remain < 0 {
		remain = 0
	}
	return false, remain
}

func isResolvedStatus(status string) bool {
	return status == StatusResolved || status == StatusIgnored
}

func applyIssueStatus(issue *TrackedIssue, status string) {
	issue.Status = status
	if isResolvedStatus(status) {
		now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
		issue.ResolvedAt = &now
		return
	}
	issue.ResolvedAt = nil
}

// trimPtr 把指针字符串 trim 后返回；空串返回 nil（用于表示"清除字段"）
func trimPtr(in *string) *string {
	if in == nil {
		return nil
	}
	v := strings.TrimSpace(*in)
	if v == "" {
		return nil
	}
	return &v
}

func normalizeIssueTags(tags []string) []string {
	seen := make(map[string]bool, len(tags))
	out := make([]string, 0, len(tags))
	for _, raw := range tags {
		tag := strings.TrimSpace(raw)
		if tag == "" || seen[tag] {
			continue
		}
		seen[tag] = true
		out = append(out, tag)
	}
	return out
}

func HandleGetStatus(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := store.Load(c.Request.Context())
		if err != nil {
			slog.Error("status load error", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync data"})
			return
		}

		summary := BuildStatusSummary(payload, time.Now())

		lastSentTime := ""
		feishuEnabled := false
		if payload.FeishuBotConfig != nil {
			lastSentTime = payload.FeishuBotConfig.LastSentDateTime
			feishuEnabled = payload.FeishuBotConfig.Enabled
		}

		_, cooldownSec := canSendFeishu(payload, 5*time.Minute)

		c.JSON(http.StatusOK, gin.H{
			"statistics":     summary["statistics"],
			"lastSentTime":   lastSentTime,
			"cooldownRemain": cooldownSec,
			"feishuEnabled":  feishuEnabled,
			"todayTotal":     summary["todayTotal"],
			"departments":    summary["departments"],
		})
	}
}

func HandleGetIssues(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := store.Load(c.Request.Context())
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync data"})
			return
		}

		statusFilter := c.Query("status")
		today := time.Now().Format("2006-01-02")
		filtered := make([]TrackedIssue, 0, len(payload.TrackedIssues))

		for _, issue := range payload.TrackedIssues {
			normalizeIssueMetadata(&issue)
			if issue.DeletedAt != nil && c.Query("includeDeleted") != "true" {
				continue
			}
			isResolved := isResolvedStatus(issue.Status)
			if statusFilter == "" {
				filtered = append(filtered, issue)
				continue
			}

			switch statusFilter {
			case "new":
				if issue.DateKey == today && !isResolved {
					filtered = append(filtered, issue)
				}
			case "pending":
				if !isResolved && issue.Status != StatusObserving && issue.Status != StatusScheduled && issue.Status != StatusTesting {
					filtered = append(filtered, issue)
				}
			case "scheduled":
				if issue.Status == StatusScheduled {
					filtered = append(filtered, issue)
				}
			case "testing":
				if issue.Status == StatusTesting {
					filtered = append(filtered, issue)
				}
			case "observing":
				if issue.Status == StatusObserving {
					filtered = append(filtered, issue)
				}
			case "resolved":
				if isResolved {
					filtered = append(filtered, issue)
				}
			}
		}

		c.JSON(http.StatusOK, gin.H{"issues": filtered})
	}
}

func HandleUpdateIssue(store PayloadStore, feishuTask *FeishuTaskClient) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if !issueIDRegexp.MatchString(issueID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid issue id"})
			return
		}
		expectedRevision, ok := requireIssueRevision(c)
		if !ok {
			return
		}

		var body struct {
			Status         *string  `json:"status"`
			Assignee       *string  `json:"assignee"`
			Department     *string  `json:"department"`
			TicketURL      *string  `json:"ticketURL"`
			FeishuTaskGUID *string  `json:"feishuTaskGuid"`
			ReporterID     *string  `json:"reporterId"`
			ReporterName   *string  `json:"reporterName"`
			IssueTags      []string `json:"issueTags"`
		}
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}

		ctx := c.Request.Context()
		found := false
		var current *TrackedIssue
		var updated TrackedIssue
		var feishuTaskGUID string
		var refreshBoundTask bool
		err := store.Update(ctx, func(payload *SyncPayload) error {
			for i := range payload.TrackedIssues {
				issue := &payload.TrackedIssues[i]
				if issue.ID != issueID {
					continue
				}
				if err := prepareIssueMutation(issue, expectedRevision, &current); err != nil {
					return err
				}

				now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
				if body.FeishuTaskGUID != nil {
					trimmed := strings.TrimSpace(*body.FeishuTaskGUID)
					if trimmed == "" {
						issue.FeishuTaskGUID = nil
					} else {
						issue.FeishuTaskGUID = &trimmed
						issue.Source = "飞书任务"
						issue.FeishuTaskSummary = nil
						issue.FeishuTaskCompletedAt = nil
						issue.FeishuTasklistGUIDs = nil
						issue.FeishuTaskAssigneeIDs = nil
						issue.JiraKey = nil
						issue.TicketURL = nil
						issue.IsEscalated = false
						issue.LinearIssueID = nil
						issue.LinearKey = nil
						issue.LinearURL = nil
						issue.LinearProjectID = nil
						issue.LinearProjectName = nil
						issue.LinearAssignee = nil
						issue.LinearCreator = nil
						issue.LinearCreatedAt = nil
						issue.LinearUpdatedAt = nil
						feishuTaskGUID = trimmed
						refreshBoundTask = true
					}
				}

				if body.Status != nil {
					applyIssueStatus(issue, strings.TrimSpace(*body.Status))
				}
				if body.Assignee != nil {
					issue.Assignee = trimPtr(body.Assignee)
				}
				if body.Department != nil {
					issue.Department = trimPtr(body.Department)
				}
				if body.TicketURL != nil {
					issue.TicketURL = trimPtr(body.TicketURL)
				}
				if body.ReporterID != nil {
					issue.ReporterID = trimPtr(body.ReporterID)
				}
				if body.ReporterName != nil {
					issue.ReporterName = trimPtr(body.ReporterName)
					if issue.ReporterName != nil && issue.ReportedAt == nil {
						issue.ReportedAt = &now
					}
				}
				if body.IssueTags != nil {
					issue.IssueTags = normalizeIssueTags(body.IssueTags)
				}
				issue.UpdatedAt = &now
				if issue.FeishuTaskGUID != nil {
					feishuTaskGUID = *issue.FeishuTaskGUID
				}
				found = true
				updated = *issue
				return nil
			}
			return nil
		})
		if err != nil {
			if errors.Is(err, errOperationAlreadyApplied) {
				matches, matchErr := operationReplayMatches(store, c.Request.Context(), issueID)
				if matchErr != nil {
					c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to verify idempotent replay"})
					return
				}
				if !matches {
					c.JSON(http.StatusConflict, gin.H{"error": "Idempotency-Key was already used for another entity", "code": "idempotency_key_reused"})
					return
				}
				if issue, exists := loadIssueByID(store, c, issueID); exists {
					c.Header("X-Idempotent-Replay", "true")
					c.Header("ETag", fmt.Sprintf("\"%d\"", issue.Revision))
					c.JSON(http.StatusOK, gin.H{"success": true, "issue": issue, "replayed": true})
					return
				}
			}
			if writeIssueMutationError(c, err, current) {
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}

		if refreshBoundTask && feishuTaskGUID != "" && feishuTask != nil {
			if detail, err := feishuTask.getTaskDetail(ctx, feishuTaskGUID); err == nil && detail != nil {
				completed := detail.CompletedAt != "" && detail.CompletedAt != "0"
				UpsertIssueFromFeishuTask(ctx, store, feishuTaskGUID,
					strings.TrimSpace(detail.Summary), detail.Description, detail.CompletedAt, completed)
			}
		}

		// Store.Update may have assigned the next revision after the callback.
		if payload, loadErr := store.Load(ctx); loadErr == nil {
			for _, issue := range payload.TrackedIssues {
				if issue.ID == issueID {
					updated = issue
					break
				}
			}
		}
		c.Header("ETag", fmt.Sprintf("\"%d\"", updated.Revision))
		c.JSON(http.StatusOK, gin.H{"success": true, "issue": updated})
	}
}

func HandleAddComment(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if !issueIDRegexp.MatchString(issueID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid issue id"})
			return
		}
		expectedRevision, ok := requireIssueRevision(c)
		if !ok {
			return
		}

		var body struct {
			Text string `json:"text"`
		}
		if err := c.ShouldBindJSON(&body); err != nil || strings.TrimSpace(body.Text) == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "text is required"})
			return
		}

		found := false
		var current *TrackedIssue
		err := store.Update(c.Request.Context(), func(payload *SyncPayload) error {
			for i := range payload.TrackedIssues {
				issue := &payload.TrackedIssues[i]
				if issue.ID != issueID {
					continue
				}
				if err := prepareIssueMutation(issue, expectedRevision, &current); err != nil {
					return err
				}

				now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
				issue.Comments = append(issue.Comments, IssueComment{
					ID:        newIssueUUID(),
					Text:      strings.TrimSpace(body.Text),
					CreatedAt: now,
				})
				issue.UpdatedAt = &now
				found = true
				return nil
			}
			return nil
		})
		if err != nil {
			if errors.Is(err, errOperationAlreadyApplied) {
				matches, matchErr := operationReplayMatches(store, c.Request.Context(), issueID)
				if matchErr != nil {
					c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to verify idempotent replay"})
					return
				}
				if !matches {
					c.JSON(http.StatusConflict, gin.H{"error": "Idempotency-Key was already used for another entity", "code": "idempotency_key_reused"})
					return
				}
				if issue, exists := loadIssueByID(store, c, issueID); exists {
					c.Header("X-Idempotent-Replay", "true")
					c.Header("ETag", fmt.Sprintf("\"%d\"", issue.Revision))
					c.JSON(http.StatusOK, gin.H{"success": true, "issue": issue, "replayed": true})
					return
				}
			}
			if writeIssueMutationError(c, err, current) {
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}

		var updated TrackedIssue
		if payload, loadErr := store.Load(c.Request.Context()); loadErr == nil {
			for _, issue := range payload.TrackedIssues {
				if issue.ID == issueID {
					updated = issue
					break
				}
			}
		}
		c.Header("ETag", fmt.Sprintf("\"%d\"", updated.Revision))
		c.JSON(http.StatusOK, gin.H{"success": true, "issue": updated})
	}
}

func HandleCreateIssue(store PayloadStore, feishuTask *FeishuTaskClient) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body struct {
			Title        string   `json:"title"`
			Type         string   `json:"type"`
			Department   *string  `json:"department"`
			TicketURL    *string  `json:"ticketURL"`
			ReporterID   *string  `json:"reporterId"`
			ReporterName *string  `json:"reporterName"`
			IssueTags    []string `json:"issueTags"`
		}
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}

		createdIssue, err := CreateTrackedIssue(c.Request.Context(), store, CreateTrackedIssueInput{
			Title:        body.Title,
			Type:         body.Type,
			Department:   body.Department,
			TicketURL:    body.TicketURL,
			ReporterID:   body.ReporterID,
			ReporterName: body.ReporterName,
			Source:       "Web",
			IssueTags:    body.IssueTags,
		})
		if err != nil && strings.Contains(err.Error(), "required") {
			c.JSON(http.StatusBadRequest, gin.H{"error": "title and type are required"})
			return
		}
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}

		_ = feishuTask // 飞书任务由事件回调驱动，平台不再主动创建

		c.JSON(http.StatusOK, gin.H{"success": true, "issue": createdIssue})
	}
}

func HandleDeleteIssue(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if !issueIDRegexp.MatchString(issueID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid issue id"})
			return
		}
		expectedRevision, ok := requireIssueRevision(c)
		if !ok {
			return
		}

		found := false
		var current *TrackedIssue
		var deleted TrackedIssue
		err := store.Update(c.Request.Context(), func(payload *SyncPayload) error {
			for i := range payload.TrackedIssues {
				issue := &payload.TrackedIssues[i]
				if issue.ID != issueID {
					continue
				}
				if err := prepareIssueMutation(issue, expectedRevision, &current); err != nil {
					return err
				}
				now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
				issue.DeletedAt = &now
				issue.UpdatedAt = &now
				deleted = *issue
				found = true
				break
			}
			return nil
		})
		if err != nil {
			if writeIssueMutationError(c, err, current) {
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}

		if payload, loadErr := store.Load(c.Request.Context()); loadErr == nil {
			for _, issue := range payload.TrackedIssues {
				if issue.ID == issueID {
					deleted = issue
					break
				}
			}
		}
		c.Header("ETag", fmt.Sprintf("\"%d\"", deleted.Revision))
		c.JSON(http.StatusOK, gin.H{"success": true, "issue": deleted})
	}
}

func HandleListFeishuTasks(store PayloadStore, feishuTask *FeishuTaskClient) gin.HandlerFunc {
	return func(c *gin.Context) {
		_ = store
		_ = feishuTask
		c.JSON(http.StatusGone, gin.H{"error": "飞书任务列表仅支持 macOS 客户端用户授权后访问"})
	}
}

func HandleTestFeishuTasks(store PayloadStore, feishuTask *FeishuTaskClient) gin.HandlerFunc {
	return func(c *gin.Context) {
		_ = store
		_ = feishuTask
		c.JSON(http.StatusGone, gin.H{"error": "飞书任务测试仅支持 macOS 客户端用户授权后访问"})
	}
}

func HandleSendFeishu(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		feishuSendMu.Lock()
		defer feishuSendMu.Unlock()

		ctx := c.Request.Context()
		payload, err := store.Load(ctx)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync data"})
			return
		}

		canSend, cooldownSec := canSendFeishu(payload, 5*time.Minute)
		if !canSend {
			c.JSON(http.StatusTooManyRequests, gin.H{
				"success":        false,
				"message":        fmt.Sprintf("请等待 %d 秒后再试", cooldownSec),
				"cooldownRemain": cooldownSec,
			})
			return
		}

		if err := sendFeishuReport(ctx, *payload); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"success": false,
				"message": fmt.Sprintf("发送失败: %v", err),
			})
			return
		}

		now := time.Now().Format("2006-01-02 15:04:05")
		if err := store.Update(ctx, func(payload *SyncPayload) error {
			if payload.FeishuBotConfig == nil {
				return nil
			}
			payload.FeishuBotConfig.LastSentDateTime = now
			return nil
		}); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}

		nextAvailable := time.Now().Add(5 * time.Minute).Format("15:04:05")
		c.JSON(http.StatusOK, gin.H{
			"success":       true,
			"message":       "发送成功",
			"nextAvailable": nextAvailable,
		})
	}
}

func HandleSendIssueMonthlyFeishu(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		feishuSendMu.Lock()
		defer feishuSendMu.Unlock()

		ctx := c.Request.Context()
		payload, err := store.Load(ctx)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync data"})
			return
		}

		period := strings.TrimSpace(c.Query("period"))
		if period != "previous" {
			period = "current"
		}

		if err := sendFeishuIssueMonthlyReport(ctx, *payload, period); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"success": false,
				"message": fmt.Sprintf("发送失败: %v", err),
			})
			return
		}

		now := time.Now().Format("2006-01-02 15:04:05")
		if err := store.Update(ctx, func(payload *SyncPayload) error {
			if payload.FeishuBotConfig == nil {
				return nil
			}
			payload.FeishuBotConfig.LastSentDateTime = now
			return nil
		}); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}

		c.JSON(http.StatusOK, gin.H{
			"success": true,
			"message": "问题月报发送成功",
		})
	}
}
