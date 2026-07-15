package main

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

func requireIssueBaseRevision(c *gin.Context) (int64, bool) {
	raw := strings.TrimSpace(c.GetHeader("If-Match"))
	if raw == "" {
		c.JSON(http.StatusPreconditionRequired, gin.H{"error": "If-Match issue revision is required", "code": "issue_revision_required"})
		return 0, false
	}
	raw = strings.TrimPrefix(raw, "W/")
	raw = strings.Trim(raw, "\"")
	revision, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || revision < 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid If-Match issue revision", "code": "invalid_issue_revision"})
		return 0, false
	}
	return revision, true
}

func loadIssueByID(store PayloadStore, c *gin.Context, issueID string) (TrackedIssue, bool) {
	payload, err := store.Load(c.Request.Context())
	if err != nil {
		return TrackedIssue{}, false
	}
	for _, issue := range payload.TrackedIssues {
		if issue.ID == issueID {
			return issue, true
		}
	}
	return TrackedIssue{}, false
}

func writeSyncIssueSuccess(c *gin.Context, issue TrackedIssue, replay bool) {
	c.Header("ETag", fmt.Sprintf("\"%d\"", issue.Revision))
	if replay {
		c.Header("X-Idempotent-Replay", "true")
	}
	c.JSON(http.StatusOK, gin.H{"success": true, "issue": issue, "replayed": replay})
}

// HandleSyncUpsertIssue is the macOS/Tauri delta endpoint. The body is a full
// Issue projection, but the write is guarded by its base revision and operation ID.
func HandleSyncUpsertIssue(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if !issueIDRegexp.MatchString(issueID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid issue id"})
			return
		}
		baseRevision, ok := requireIssueBaseRevision(c)
		if !ok {
			return
		}
		var incoming TrackedIssue
		if err := c.ShouldBindJSON(&incoming); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid issue body"})
			return
		}
		if incoming.ID == "" {
			incoming.ID = issueID
		}
		if incoming.ID != issueID || strings.TrimSpace(incoming.Title) == "" || strings.TrimSpace(incoming.Type) == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "issue id, title, and type are required"})
			return
		}
		if incoming.DeletedAt != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "use DELETE to create a tombstone"})
			return
		}

		found := false
		var current *TrackedIssue
		err := store.Update(c.Request.Context(), func(payload *SyncPayload) error {
			maxNumber := 0
			for i := range payload.TrackedIssues {
				issue := &payload.TrackedIssues[i]
				if issue.IssueNumber > maxNumber {
					maxNumber = issue.IssueNumber
				}
				if issue.ID != issueID {
					continue
				}
				found = true
				if err := prepareIssueMutation(issue, baseRevision, &current); err != nil {
					return err
				}
				if incoming.IssueNumber == 0 {
					incoming.IssueNumber = issue.IssueNumber
				}
				if incoming.CreatedAt.Value == "" {
					incoming.CreatedAt = issue.CreatedAt
				}
				if strings.TrimSpace(incoming.Source) == "" {
					incoming.Source = issue.Source
				}
				incoming.Revision = issue.Revision
				incoming.UpdatedBy = nil
				now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
				incoming.UpdatedAt = &now
				*issue = incoming
				return nil
			}
			if baseRevision != 0 {
				return errIssueRevisionConflict
			}
			if incoming.IssueNumber == 0 {
				incoming.IssueNumber = maxNumber + 1
			}
			if incoming.CreatedAt.Value == "" {
				incoming.CreatedAt = FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
			}
			if strings.TrimSpace(incoming.Source) == "" {
				incoming.Source = "macOS"
			}
			incoming.Revision = 1
			incoming.UpdatedBy = nil
			payload.TrackedIssues = append(payload.TrackedIssues, incoming)
			return nil
		})
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
				writeSyncIssueSuccess(c, issue, true)
				return
			}
		}
		if err != nil {
			if writeIssueMutationError(c, err, current) {
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save issue delta"})
			return
		}
		if !found && baseRevision != 0 {
			c.JSON(http.StatusConflict, gin.H{"error": "issue no longer exists", "code": "issue_revision_conflict"})
			return
		}
		issue, exists := loadIssueByID(store, c, issueID)
		if !exists {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "saved issue could not be reloaded"})
			return
		}
		writeSyncIssueSuccess(c, issue, false)
	}
}

func HandleSyncDeleteIssue(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		issueID := c.Param("id")
		if !issueIDRegexp.MatchString(issueID) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid issue id"})
			return
		}
		baseRevision, ok := requireIssueBaseRevision(c)
		if !ok {
			return
		}
		if baseRevision == 0 {
			c.JSON(http.StatusConflict, gin.H{"error": "cannot delete an issue without an online revision", "code": "issue_revision_conflict"})
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
				if err := prepareIssueMutation(issue, baseRevision, &current); err != nil {
					return err
				}
				now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
				issue.DeletedAt = &now
				issue.UpdatedAt = &now
				found = true
				return nil
			}
			return errIssueRevisionConflict
		})
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
				writeSyncIssueSuccess(c, issue, true)
				return
			}
		}
		if err != nil {
			if writeIssueMutationError(c, err, current) {
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete issue delta"})
			return
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"error": "issue not found"})
			return
		}
		issue, exists := loadIssueByID(store, c, issueID)
		if !exists {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "deleted issue could not be reloaded"})
			return
		}
		writeSyncIssueSuccess(c, issue, false)
	}
}
