package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestSyncV2ConditionalUpsertDeleteAndIdempotentReplay(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, cfg := newTestSQLiteStore(t)
	router := gin.New()
	syncV2 := router.Group("/sync/v2", WorkspaceAuthMiddleware(store, "sync", cfg.SyncAccessToken()))
	syncV2.GET("/events", HandleGetCollaborationEvents(store))
	syncV2.PUT("/issues/:id", RequireIdempotencyKey(), HandleSyncUpsertIssue(store))
	syncV2.DELETE("/issues/:id", RequireIdempotencyKey(), HandleSyncDeleteIssue(store))

	do := func(method, path, body, revision, operationID string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+cfg.SyncAccessToken())
		req.Header.Set("X-Client-ID", "mac-a")
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		if revision != "" {
			req.Header.Set("If-Match", revision)
		}
		if operationID != "" {
			req.Header.Set("Idempotency-Key", operationID)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w
	}

	issue := `{"id":"delta-1","issueNumber":1,"type":"Bug","title":"first","dateKey":"2026-07-13","createdAt":"2026-07-13 10:00:00","status":"待处理","source":"macOS","comments":[]}`
	if w := do(http.MethodPut, "/sync/v2/issues/delta-1", issue, `"0"`, "operation-create-1"); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"revision":1`) {
		t.Fatalf("create delta status=%d body=%s", w.Code, w.Body.String())
	}
	replayBody := strings.Replace(issue, `"title":"first"`, `"title":"must-not-apply"`, 1)
	if w := do(http.MethodPut, "/sync/v2/issues/delta-1", replayBody, `"0"`, "operation-create-1"); w.Code != http.StatusOK || w.Header().Get("X-Idempotent-Replay") != "true" || strings.Contains(w.Body.String(), "must-not-apply") {
		t.Fatalf("replay status=%d headers=%v body=%s", w.Code, w.Header(), w.Body.String())
	}
	other := strings.Replace(issue, "delta-1", "delta-2", 1)
	if w := do(http.MethodPut, "/sync/v2/issues/delta-2", other, `"0"`, "operation-create-1"); w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "idempotency_key_reused") {
		t.Fatalf("reused key status=%d body=%s", w.Code, w.Body.String())
	}

	updated := strings.Replace(issue, `"title":"first"`, `"title":"second"`, 1)
	if w := do(http.MethodPut, "/sync/v2/issues/delta-1", updated, `"0"`, "operation-stale-1"); w.Code != http.StatusConflict {
		t.Fatalf("stale update status=%d body=%s", w.Code, w.Body.String())
	}
	if w := do(http.MethodPut, "/sync/v2/issues/delta-1", updated, `"1"`, "operation-update-1"); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"revision":2`) || !strings.Contains(w.Body.String(), `"title":"second"`) {
		t.Fatalf("update delta status=%d body=%s", w.Code, w.Body.String())
	}
	if w := do(http.MethodDelete, "/sync/v2/issues/delta-1", "", `"2"`, "operation-delete-1"); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"revision":3`) || !strings.Contains(w.Body.String(), `"deletedAt"`) {
		t.Fatalf("delete delta status=%d body=%s", w.Code, w.Body.String())
	}
	if w := do(http.MethodDelete, "/sync/v2/issues/delta-1", "", `"2"`, "operation-delete-1"); w.Code != http.StatusOK || w.Header().Get("X-Idempotent-Replay") != "true" {
		t.Fatalf("delete replay status=%d headers=%v body=%s", w.Code, w.Header(), w.Body.String())
	}

	w := do(http.MethodGet, "/sync/v2/events?after=0", "", "", "")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"operationId":"operation-create-1"`) || !strings.Contains(w.Body.String(), `"type":"issue.deleted"`) {
		t.Fatalf("event delta response status=%d body=%s", w.Code, w.Body.String())
	}
	if w := do(http.MethodPut, "/sync/v2/issues/delta-3", other, `"0"`, ""); w.Code != http.StatusBadRequest {
		t.Fatalf("missing idempotency key status=%d body=%s", w.Code, w.Body.String())
	}
}
