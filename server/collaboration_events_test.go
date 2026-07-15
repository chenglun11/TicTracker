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
