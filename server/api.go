package main

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

var feishuSendMu sync.Mutex

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
	return status == "已修复" || status == "已忽略"
}

func applyIssueStatus(issue *TrackedIssue, status string) {
	issue.Status = status
	if isResolvedStatus(status) {
		now := time.Now().Format("2006-01-02 15:04:05")
		issue.ResolvedAt = &now
		return
	}
	issue.ResolvedAt = nil
}

func HandleGetStatus(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := store.Load()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync data"})
			return
		}

		today := time.Now().Format("2006-01-02")
		newToday := 0
		resolvedToday := 0
		pending := 0
		observing := 0
		todayTotal := 0

		for _, issue := range payload.TrackedIssues {
			isResolved := isResolvedStatus(issue.Status)
			if issue.DateKey == today && !isResolved {
				newToday++
			}
			if issue.ResolvedAt != nil && strings.HasPrefix(*issue.ResolvedAt, today) {
				resolvedToday++
			}
			if !isResolved && issue.Status != "观测中" {
				pending++
			}
			if issue.Status == "观测中" {
				observing++
			}
		}

		if payload.Records != nil {
			if rec, ok := payload.Records[today]; ok {
				for _, v := range rec {
					todayTotal += v
				}
			}
		}

		lastSentTime := ""
		feishuEnabled := false
		if payload.FeishuBotConfig != nil {
			lastSentTime = payload.FeishuBotConfig.LastSentDateTime
			feishuEnabled = payload.FeishuBotConfig.Enabled
		}

		_, cooldownSec := canSendFeishu(payload, 5*time.Minute)

		c.JSON(http.StatusOK, gin.H{
			"statistics": gin.H{
				"newToday":      newToday,
				"resolvedToday": resolvedToday,
				"pending":       pending,
				"observing":     observing,
			},
			"lastSentTime":   lastSentTime,
			"cooldownRemain": cooldownSec,
			"feishuEnabled":  feishuEnabled,
			"todayTotal":     todayTotal,
			"departments":    payload.Departments,
		})
	}
}

func HandleGetIssues(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := store.Load()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync data"})
			return
		}

		statusFilter := c.Query("status")
		today := time.Now().Format("2006-01-02")
		filtered := make([]TrackedIssue, 0, len(payload.TrackedIssues))

		for _, issue := range payload.TrackedIssues {
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
				if !isResolved && issue.Status != "观测中" {
					filtered = append(filtered, issue)
				}
			case "observing":
				if issue.Status == "观测中" {
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

func HandleUpdateIssue(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if issueID == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "issue id is required"})
			return
		}

		var body struct {
			Status     *string `json:"status"`
			Assignee   *string `json:"assignee"`
			Department *string `json:"department"`
		}
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}

		found := false
		err := store.Update(func(payload *SyncPayload) error {
			for i := range payload.TrackedIssues {
				issue := &payload.TrackedIssues[i]
				if issue.ID != issueID {
					continue
				}

				now := time.Now().Format("2006-01-02 15:04:05")
				if body.Status != nil {
					applyIssueStatus(issue, strings.TrimSpace(*body.Status))
				}
				if body.Assignee != nil {
					trimmed := strings.TrimSpace(*body.Assignee)
					issue.Assignee = &trimmed
					if trimmed == "" {
						issue.Assignee = nil
					}
				}
				if body.Department != nil {
					trimmed := strings.TrimSpace(*body.Department)
					issue.Department = &trimmed
					if trimmed == "" {
						issue.Department = nil
					}
				}
				issue.UpdatedAt = &now
				found = true
				return nil
			}
			return nil
		})
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}

		c.JSON(http.StatusOK, gin.H{"success": true})
	}
}

func HandleAddComment(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if issueID == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "issue id is required"})
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
		err := store.Update(func(payload *SyncPayload) error {
			for i := range payload.TrackedIssues {
				issue := &payload.TrackedIssues[i]
				if issue.ID != issueID {
					continue
				}

				now := time.Now().Format("2006-01-02 15:04:05")
				issue.Comments = append(issue.Comments, IssueComment{
					ID:        fmt.Sprintf("%d", time.Now().UnixNano()),
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
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}

		c.JSON(http.StatusOK, gin.H{"success": true})
	}
}

func HandleCreateIssue(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body struct {
			Title      string  `json:"title"`
			Type       string  `json:"type"`
			Department *string `json:"department"`
		}
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}

		title := strings.TrimSpace(body.Title)
		issueType := strings.TrimSpace(body.Type)
		if title == "" || issueType == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "title and type are required"})
			return
		}

		var createdIssue TrackedIssue
		err := store.Update(func(payload *SyncPayload) error {
			maxNumber := 0
			for _, issue := range payload.TrackedIssues {
				if issue.IssueNumber > maxNumber {
					maxNumber = issue.IssueNumber
				}
			}

			today := time.Now().Format("2006-01-02")
			now := time.Now().Format("2006-01-02 15:04:05")
			createdIssue = TrackedIssue{
				ID:          fmt.Sprintf("%d", time.Now().UnixNano()),
				IssueNumber: maxNumber + 1,
				Type:        issueType,
				Title:       title,
				DateKey:     today,
				CreatedAt:   now,
				Status:      "待处理",
				Source:      "Web",
				Comments:    []IssueComment{},
			}
			if body.Department != nil {
				trimmed := strings.TrimSpace(*body.Department)
				if trimmed != "" {
					createdIssue.Department = &trimmed
				}
			}

			payload.TrackedIssues = append(payload.TrackedIssues, createdIssue)
			return nil
		})
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}

		c.JSON(http.StatusOK, gin.H{"success": true, "issue": createdIssue})
	}
}

func HandleDeleteIssue(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if issueID == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "issue id is required"})
			return
		}

		found := false
		err := store.Update(func(payload *SyncPayload) error {
			filtered := payload.TrackedIssues[:0]
			for _, issue := range payload.TrackedIssues {
				if issue.ID == issueID {
					found = true
					continue
				}
				filtered = append(filtered, issue)
			}
			payload.TrackedIssues = filtered
			return nil
		})
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save sync data"})
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}

		c.JSON(http.StatusOK, gin.H{"success": true})
	}
}

func HandleSendFeishu(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		feishuSendMu.Lock()
		defer feishuSendMu.Unlock()

		payload, err := store.Load()
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

		if err := sendFeishuReport(*payload); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{
				"success": false,
				"message": fmt.Sprintf("发送失败: %v", err),
			})
			return
		}

		now := time.Now().Format("2006-01-02 15:04:05")
		if err := store.Update(func(payload *SyncPayload) error {
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
