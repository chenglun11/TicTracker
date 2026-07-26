package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestCollaborationEventsPersistAndResumeByCursor(t *testing.T) {
	store, cfg := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "web:alice")
	created, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: "event issue", Type: "Bug", Source: "Web"})
	if err != nil {
		t.Fatalf("create issue: %v", err)
	}

	events, err := store.ListCollaborationEvents(ctx, defaultWorkspaceID, 0, 100)
	if err != nil {
		t.Fatalf("list create events: %v", err)
	}
	if len(events) != 1 || events[0].Type != "issue.upserted" || events[0].EntityRevision != 1 || events[0].Actor != "web:alice" {
		t.Fatalf("unexpected create events: %+v", events)
	}
	firstCursor := events[0].Cursor

	if err := store.Update(ctx, func(payload *SyncPayload) error {
		payload.TrackedIssues[0].Assignee = strPtr("Bob")
		return nil
	}); err != nil {
		t.Fatalf("update issue: %v", err)
	}
	events, err = store.ListCollaborationEvents(ctx, defaultWorkspaceID, firstCursor, 100)
	if err != nil {
		t.Fatalf("resume events: %v", err)
	}
	if len(events) != 1 || events[0].EntityID != created.ID || events[0].EntityRevision != 2 || events[0].Cursor <= firstCursor {
		t.Fatalf("unexpected resumed events: %+v", events)
	}

	reopened, err := NewSQLiteStore(context.Background(), cfg)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	persisted, err := reopened.ListCollaborationEvents(context.Background(), defaultWorkspaceID, firstCursor, 100)
	if err != nil || len(persisted) != 1 || persisted[0].Cursor != events[0].Cursor {
		t.Fatalf("events did not persist across restart: events=%+v err=%v", persisted, err)
	}
}

func TestStreamCollaborationEventsEmitsAndClosesOnDisconnect(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, _ := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "web:stream")
	if _, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: "stream issue", Type: "Bug"}); err != nil {
		t.Fatalf("create issue: %v", err)
	}

	requestContext, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/events/stream?after=0", nil).WithContext(requestContext)
	writer := httptest.NewRecorder()
	ginContext, _ := gin.CreateTestContext(writer)
	ginContext.Request = req
	done := make(chan struct{})
	go func() {
		HandleStreamCollaborationEvents(store)(ginContext)
		close(done)
	}()

	select {
	case <-done:
		t.Fatalf("stream closed before client disconnect")
	case <-time.After(50 * time.Millisecond):
		cancel()
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("stream did not close after client disconnect")
	}
	body := writer.Body.String()
	if !strings.Contains(body, "event: issue.upserted") || !strings.Contains(body, `"entityId"`) {
		t.Fatalf("stream did not emit issue event: %s", body)
	}
}

func TestStreamCollaborationEventsWakesAfterCommit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, _ := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "web:stream")
	if _, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: "first issue", Type: "Bug"}); err != nil {
		t.Fatalf("create first issue: %v", err)
	}

	requestContext, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/events/stream?after=1", nil).WithContext(requestContext)
	writer := httptest.NewRecorder()
	ginContext, _ := gin.CreateTestContext(writer)
	ginContext.Request = req
	done := make(chan struct{})
	go func() {
		HandleStreamCollaborationEvents(store)(ginContext)
		close(done)
	}()

	// Give the stream time to complete its initial empty query and wait. The
	// old one-second polling loop cannot observe the following commit within
	// this window; the commit signal should wake it immediately.
	time.Sleep(100 * time.Millisecond)
	if _, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: "wakeup issue", Type: "Bug"}); err != nil {
		cancel()
		t.Fatalf("create wakeup issue: %v", err)
	}
	time.Sleep(250 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("stream did not close after client disconnect")
	}
	if body := writer.Body.String(); !strings.Contains(body, `"title":"wakeup issue"`) {
		t.Fatalf("stream did not wake after commit: %s", body)
	}
}

func TestGetCollaborationEventsUsesWorkspaceAuthAndCursor(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, cfg := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "web:alice")
	if _, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: "api event", Type: "Bug"}); err != nil {
		t.Fatalf("create issue: %v", err)
	}

	router := gin.New()
	api := router.Group("/api/v1", WorkspaceAuthMiddleware(store, "web", cfg.WebAccessToken()))
	api.GET("/events", HandleGetCollaborationEvents(store))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/events?after=0", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.WebAccessToken())
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"type":"issue.upserted"`) || !strings.Contains(w.Body.String(), `"nextCursor":1`) {
		t.Fatalf("unexpected events response: code=%d body=%s", w.Code, w.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/events?after=bad", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.WebAccessToken())
	w = httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("invalid cursor status=%d body=%s", w.Code, w.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/events?after=999999", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.WebAccessToken())
	w = httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"cursorReset":true`) || !strings.Contains(w.Body.String(), `"nextCursor":1`) {
		t.Fatalf("future cursor was not reset: status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestRecentActivityReturnsNewestEventsAndValidatesLimit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, cfg := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "web:alice")
	for _, title := range []string{"first activity", "second activity", "latest activity"} {
		if _, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: title, Type: "Bug"}); err != nil {
			t.Fatalf("create %q: %v", title, err)
		}
	}

	router := gin.New()
	api := router.Group("/api/v1", WorkspaceAuthMiddleware(store, "web", cfg.WebAccessToken()))
	api.GET("/activity", HandleGetRecentActivity(store))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/activity?limit=2", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.WebAccessToken())
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("recent activity status=%d body=%s", w.Code, w.Body.String())
	}
	var response struct {
		Events []CollaborationEvent `json:"events"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode recent activity: %v", err)
	}
	if len(response.Events) != 2 || response.Events[0].Cursor <= response.Events[1].Cursor {
		t.Fatalf("recent activity not newest-first: %+v", response.Events)
	}
	var latest TrackedIssue
	if err := json.Unmarshal(response.Events[0].Payload, &latest); err != nil || latest.Title != "latest activity" {
		t.Fatalf("unexpected latest activity: issue=%+v err=%v", latest, err)
	}

	req = httptest.NewRequest(http.MethodGet, "/api/v1/activity?limit=100", nil)
	req.Header.Set("Authorization", "Bearer "+cfg.WebAccessToken())
	w = httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("invalid activity limit status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestLegacyWholeSyncStillAdvancesIssueRevisionAndEmitsEvent(t *testing.T) {
	store, _ := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "macOS:laptop-a")
	first := []byte(`{"lastModified":1,"trackedIssues":[{"id":"legacy-1","issueNumber":1,"type":"Bug","title":"before","dateKey":"2026-07-13","createdAt":"2026-07-13 09:00:00","status":"待处理","source":"macOS","comments":[]}]}`)
	if err := store.ReplaceRaw(ctx, first); err != nil {
		t.Fatalf("first ReplaceRaw: %v", err)
	}
	second := []byte(`{"lastModified":2,"trackedIssues":[{"id":"legacy-1","issueNumber":1,"type":"Bug","title":"after","dateKey":"2026-07-13","createdAt":"2026-07-13 09:00:00","status":"待处理","source":"macOS","comments":[]}]}`)
	if err := store.ReplaceRaw(ctx, second); err != nil {
		t.Fatalf("second ReplaceRaw: %v", err)
	}

	payload, err := store.Load(ctx)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(payload.TrackedIssues) != 1 || payload.TrackedIssues[0].Revision != 2 || payload.TrackedIssues[0].Title != "after" {
		t.Fatalf("whole sync did not preserve revision semantics: %+v", payload.TrackedIssues)
	}
	events, err := store.ListCollaborationEvents(ctx, defaultWorkspaceID, 0, 100)
	if err != nil || len(events) != 2 || events[1].EntityRevision != 2 || events[1].Actor != "macOS:laptop-a" {
		t.Fatalf("whole sync events=%+v err=%v", events, err)
	}
}

func TestWholeSnapshotRemovalEmitsIssueTombstone(t *testing.T) {
	store, _ := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "macOS:laptop-a")
	first := []byte(`{"lastModified":1,"trackedIssues":[{"id":"legacy-1","issueNumber":1,"type":"Bug","title":"before","dateKey":"2026-07-13","createdAt":"2026-07-13 09:00:00","status":"待处理","source":"macOS","comments":[]}]}`)
	if err := store.ReplaceRaw(ctx, first); err != nil {
		t.Fatalf("first ReplaceRaw: %v", err)
	}
	if err := store.ReplaceRaw(ctx, []byte(`{"lastModified":2,"trackedIssues":[]}`)); err != nil {
		t.Fatalf("remove ReplaceRaw: %v", err)
	}

	events, err := store.ListCollaborationEvents(ctx, defaultWorkspaceID, 1, 100)
	if err != nil || len(events) != 1 {
		t.Fatalf("delete events=%+v err=%v", events, err)
	}
	if events[0].Type != "issue.deleted" || events[0].EntityID != "legacy-1" || events[0].EntityRevision != 2 {
		t.Fatalf("unexpected delete event: %+v", events[0])
	}
	var tombstone TrackedIssue
	if err := json.Unmarshal(events[0].Payload, &tombstone); err != nil {
		t.Fatalf("decode tombstone: %v", err)
	}
	if tombstone.DeletedAt == nil || tombstone.UpdatedAt == nil || tombstone.UpdatedBy == nil || *tombstone.UpdatedBy != "macOS:laptop-a" {
		t.Fatalf("incomplete tombstone: %+v", tombstone)
	}
	stored, err := store.Load(ctx)
	if err != nil || len(stored.TrackedIssues) != 1 || stored.TrackedIssues[0].DeletedAt == nil || stored.TrackedIssues[0].Revision != 2 {
		t.Fatalf("server did not retain tombstone: issues=%+v err=%v", stored.TrackedIssues, err)
	}
}
