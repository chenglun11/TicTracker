package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type CollaborationEvent struct {
	Cursor         int64           `json:"cursor"`
	Type           string          `json:"type"`
	EntityID       string          `json:"entityId"`
	EntityRevision int64           `json:"entityRevision"`
	Payload        json.RawMessage `json:"payload"`
	Actor          string          `json:"actor,omitempty"`
	CreatedAt      string          `json:"createdAt"`
	OperationID    string          `json:"operationId,omitempty"`
}

// collaborationEventSignal returns the current one-shot broadcast channel for
// a workspace. Callers subscribe before querying so a commit between the query
// and the wait cannot be missed.
func (s *SQLiteStore) collaborationEventSignal(workspaceID string) <-chan struct{} {
	if workspaceID == "" {
		workspaceID = defaultWorkspaceID
	}
	s.eventMu.Lock()
	defer s.eventMu.Unlock()
	signal := s.eventSignals[workspaceID]
	if signal == nil {
		signal = make(chan struct{})
		s.eventSignals[workspaceID] = signal
	}
	return signal
}

func (s *SQLiteStore) notifyCollaborationEvents(workspaceID string) {
	if workspaceID == "" {
		workspaceID = defaultWorkspaceID
	}
	s.eventMu.Lock()
	defer s.eventMu.Unlock()
	if signal := s.eventSignals[workspaceID]; signal != nil {
		close(signal)
	}
	s.eventSignals[workspaceID] = make(chan struct{})
}

func buildIssueEvents(before, after *SyncPayload, actor string) []CollaborationEvent {
	previous := make(map[string]TrackedIssue, len(before.TrackedIssues))
	for _, issue := range before.TrackedIssues {
		previous[issue.ID] = issue
	}
	current := make(map[string]struct{}, len(after.TrackedIssues))
	events := make([]CollaborationEvent, 0)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	for _, issue := range after.TrackedIssues {
		current[issue.ID] = struct{}{}
		old, existed := previous[issue.ID]
		if existed && issueComparableJSON(old) == issueComparableJSON(issue) {
			continue
		}
		eventType := "issue.upserted"
		if issue.DeletedAt != nil {
			eventType = "issue.deleted"
		}
		payload, _ := json.Marshal(issue)
		events = append(events, CollaborationEvent{
			Type: eventType, EntityID: issue.ID, EntityRevision: issue.Revision,
			Payload: payload, Actor: actor, CreatedAt: now,
		})
	}
	// A whole-snapshot client can physically omit an issue. Delta clients never
	// replace their issue list from that snapshot, so turn the omission into a
	// tombstone event or they would keep the removed issue forever.
	for _, old := range before.TrackedIssues {
		if _, exists := current[old.ID]; exists {
			continue
		}
		deletedAt := FlexTime{Value: now}
		tombstone := old
		tombstone.Revision = max(old.Revision+1, 1)
		tombstone.UpdatedAt = &deletedAt
		tombstone.DeletedAt = &deletedAt
		if actor != "" {
			tombstone.UpdatedBy = &actor
		}
		payload, _ := json.Marshal(tombstone)
		events = append(events, CollaborationEvent{
			Type: "issue.deleted", EntityID: tombstone.ID, EntityRevision: tombstone.Revision,
			Payload: payload, Actor: actor, CreatedAt: now,
		})
	}
	return events
}

func (s *SQLiteStore) ListCollaborationEvents(ctx context.Context, workspaceID string, after int64, limit int) ([]CollaborationEvent, error) {
	if limit < 1 || limit > 500 {
		limit = 100
	}
	sql := fmt.Sprintf(`SELECT json_object(
'cursor',cursor,'type',event_type,'entityId',entity_id,'entityRevision',entity_revision,
'payload',json(payload_json),'actor',coalesce(actor,''),'createdAt',created_at,'operationId',coalesce(operation_id,''))
FROM collaboration_events
WHERE workspace_id=%s AND cursor>%d
ORDER BY cursor ASC LIMIT %d;`, sqlQuote(workspaceID), after, limit)
	out, err := s.query(ctx, sql)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	events := make([]CollaborationEvent, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var event CollaborationEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			return nil, fmt.Errorf("decode collaboration event: %w", err)
		}
		events = append(events, event)
	}
	return events, nil
}

func (s *SQLiteStore) ListRecentCollaborationEvents(ctx context.Context, workspaceID string, limit int) ([]CollaborationEvent, error) {
	if limit < 1 || limit > 50 {
		limit = 12
	}
	sql := fmt.Sprintf(`SELECT json_object(
'cursor',cursor,'type',event_type,'entityId',entity_id,'entityRevision',entity_revision,
'payload',json(payload_json),'actor',coalesce(actor,''),'createdAt',created_at,'operationId',coalesce(operation_id,''))
FROM collaboration_events
WHERE workspace_id=%s
ORDER BY cursor DESC LIMIT %d;`, sqlQuote(workspaceID), limit)
	out, err := s.query(ctx, sql)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	events := make([]CollaborationEvent, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var event CollaborationEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			return nil, fmt.Errorf("decode recent collaboration event: %w", err)
		}
		events = append(events, event)
	}
	return events, nil
}

func (s *SQLiteStore) CollaborationEventBounds(ctx context.Context, workspaceID string) (int64, int64, error) {
	out, err := s.query(ctx, `SELECT coalesce(min(cursor),0) || char(9) || coalesce(max(cursor),0)
FROM collaboration_events WHERE workspace_id=`+sqlQuote(workspaceID)+`;`)
	if err != nil {
		return 0, 0, err
	}
	parts := strings.Split(strings.TrimSpace(string(out)), "\t")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("invalid collaboration event bounds")
	}
	oldest, oldestErr := strconv.ParseInt(parts[0], 10, 64)
	latest, latestErr := strconv.ParseInt(parts[1], 10, 64)
	if oldestErr != nil || latestErr != nil {
		return 0, 0, fmt.Errorf("invalid collaboration event bounds")
	}
	return oldest, latest, nil
}

func normalizeEventCursor(ctx context.Context, store *SQLiteStore, requested int64) (cursor, oldest, latest int64, reset bool, err error) {
	oldest, latest, err = store.CollaborationEventBounds(ctx, workspaceIDFromContext(ctx))
	if err != nil {
		return 0, 0, 0, false, err
	}
	cursor = requested
	switch {
	case latest == 0 && requested != 0:
		cursor, reset = 0, true
	case latest > 0 && requested > latest:
		cursor, reset = latest, true
	case oldest > 0 && requested < oldest-1:
		cursor, reset = oldest-1, true
	}
	return cursor, oldest, latest, reset, nil
}

func eventCursorFromRequest(c *gin.Context) (int64, error) {
	raw := strings.TrimSpace(c.Query("after"))
	if raw == "" {
		raw = strings.TrimSpace(c.GetHeader("Last-Event-ID"))
	}
	if raw == "" {
		return 0, nil
	}
	cursor, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || cursor < 0 {
		return 0, fmt.Errorf("invalid event cursor")
	}
	return cursor, nil
}

func HandleGetCollaborationEvents(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		cursor, err := eventCursorFromRequest(c)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "code": "invalid_event_cursor"})
			return
		}
		requested := cursor
		cursor, oldest, latest, reset, err := normalizeEventCursor(c.Request.Context(), store, requested)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read collaboration event bounds"})
			return
		}
		events, err := store.ListCollaborationEvents(c.Request.Context(), workspaceIDFromContext(c.Request.Context()), cursor, 200)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read collaboration events"})
			return
		}
		next := cursor
		if len(events) > 0 {
			next = events[len(events)-1].Cursor
		}
		c.JSON(http.StatusOK, gin.H{
			"events": events, "nextCursor": next, "cursorReset": reset,
			"oldestCursor": oldest, "latestCursor": latest, "requestedCursor": requested,
		})
	}
}

func HandleGetRecentActivity(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		limit := 12
		if raw := strings.TrimSpace(c.Query("limit")); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil || parsed < 1 || parsed > 50 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "limit must be between 1 and 50", "code": "invalid_activity_limit"})
				return
			}
			limit = parsed
		}
		events, err := store.ListRecentCollaborationEvents(c.Request.Context(), workspaceIDFromContext(c.Request.Context()), limit)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read recent activity"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"events": events})
	}
}

func HandleStreamCollaborationEvents(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		cursor, err := eventCursorFromRequest(c)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "code": "invalid_event_cursor"})
			return
		}
		requested := cursor
		cursor, _, _, reset, err := normalizeEventCursor(c.Request.Context(), store, requested)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read collaboration event bounds"})
			return
		}
		c.Header("Content-Type", "text/event-stream")
		c.Header("Cache-Control", "no-cache")
		c.Header("Connection", "keep-alive")
		c.Header("X-Accel-Buffering", "no")
		_ = http.NewResponseController(c.Writer).SetWriteDeadline(time.Time{})
		flusher, ok := c.Writer.(http.Flusher)
		if !ok {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "streaming unsupported"})
			return
		}
		flusher.Flush()
		if reset {
			data, _ := json.Marshal(gin.H{"cursor": cursor, "type": "sync.reset", "entityId": "workspace", "entityRevision": 0, "payload": gin.H{"reason": "cursor_out_of_range", "requestedCursor": requested}, "createdAt": time.Now().UTC().Format(time.RFC3339Nano)})
			_, _ = fmt.Fprintf(c.Writer, "id: %d\nevent: sync.reset\ndata: %s\n\n", cursor, data)
			flusher.Flush()
		}

		// The fallback also catches writes made by another server process and
		// periodically revalidates workspace membership. Local commits wake the
		// stream immediately through the per-workspace signal.
		fallback := time.NewTicker(5 * time.Second)
		heartbeat := time.NewTicker(15 * time.Second)
		defer fallback.Stop()
		defer heartbeat.Stop()
		workspaceID := workspaceIDFromContext(c.Request.Context())
		for {
			if identity, hasIdentity := identityFromContext(c.Request.Context()); hasIdentity && !strings.HasSuffix(identity.Username, "-token") {
				active, activeErr := store.IsWorkspaceMemberActive(c.Request.Context(), workspaceID, identity.Username)
				if activeErr != nil || !active {
					_, _ = fmt.Fprint(c.Writer, "event: session.revoked\ndata: {\"code\":\"session_revoked\"}\n\n")
					flusher.Flush()
					return
				}
			}
			eventSignal := store.collaborationEventSignal(workspaceID)
			events, listErr := store.ListCollaborationEvents(c.Request.Context(), workspaceID, cursor, 100)
			if listErr != nil {
				_, _ = fmt.Fprintf(c.Writer, "event: error\ndata: {\"code\":\"event_read_failed\"}\n\n")
				flusher.Flush()
				return
			}
			for _, event := range events {
				data, _ := json.Marshal(event)
				_, _ = fmt.Fprintf(c.Writer, "id: %d\nevent: %s\ndata: %s\n\n", event.Cursor, event.Type, data)
				cursor = event.Cursor
			}
			if len(events) > 0 {
				flusher.Flush()
			}
			if len(events) == 100 {
				continue
			}
			select {
			case <-c.Request.Context().Done():
				return
			case <-eventSignal:
			case <-heartbeat.C:
				_, _ = fmt.Fprint(c.Writer, ": heartbeat\n\n")
				flusher.Flush()
			case <-fallback.C:
			}
		}
	}
}
