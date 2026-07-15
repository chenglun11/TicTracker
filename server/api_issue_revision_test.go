package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestIssueConditionalWritesAndSoftDelete(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	created, err := CreateTrackedIssue(withActor(context.Background(), "web:alice"), store, CreateTrackedIssueInput{
		Title: "concurrent issue", Type: "Bug", Source: "Web",
	})
	if err != nil {
		t.Fatalf("CreateTrackedIssue: %v", err)
	}
	if created.Revision != 1 {
		t.Fatalf("initial revision = %d, want 1", created.Revision)
	}

	router := gin.New()
	router.GET("/issues", HandleGetIssues(store))
	router.PATCH("/issues/:id", HandleUpdateIssue(store, nil))
	router.POST("/issues/:id/comments", HandleAddComment(store))
	router.DELETE("/issues/:id", HandleDeleteIssue(store))

	do := func(method, path, body, ifMatch string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		if ifMatch != "" {
			req.Header.Set("If-Match", ifMatch)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w
	}

	if w := do(http.MethodPatch, "/issues/"+created.ID, `{"status":"测试中"}`, ""); w.Code != http.StatusPreconditionRequired {
		t.Fatalf("missing If-Match status=%d body=%s", w.Code, w.Body.String())
	}

	w := do(http.MethodPatch, "/issues/"+created.ID, `{"status":"测试中"}`, `"1"`)
	if w.Code != http.StatusOK {
		t.Fatalf("first update status=%d body=%s", w.Code, w.Body.String())
	}
	var updateResponse struct {
		Issue TrackedIssue `json:"issue"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &updateResponse); err != nil {
		t.Fatalf("decode update: %v", err)
	}
	if updateResponse.Issue.Revision != 2 || updateResponse.Issue.Status != StatusTesting {
		t.Fatalf("unexpected updated issue: %+v", updateResponse.Issue)
	}

	w = do(http.MethodPost, "/issues/"+created.ID+"/comments", `{"text":"stale"}`, `"1"`)
	if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), `"revision":2`) {
		t.Fatalf("stale update status=%d body=%s", w.Code, w.Body.String())
	}

	w = do(http.MethodDelete, "/issues/"+created.ID, "", `W/"2"`)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"revision":3`) || !strings.Contains(w.Body.String(), `"deletedAt"`) {
		t.Fatalf("delete status=%d body=%s", w.Code, w.Body.String())
	}

	w = do(http.MethodGet, "/issues", "", "")
	if w.Code != http.StatusOK || w.Body.String() != `{"issues":[]}` {
		t.Fatalf("deleted issue leaked from default list: %s", w.Body.String())
	}
	w = do(http.MethodGet, "/issues?includeDeleted=true", "", "")
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), created.ID) {
		t.Fatalf("tombstone missing from incremental list: %s", w.Body.String())
	}
}

func TestAdvanceIssueRevisionsCoversBackgroundMutations(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	created, err := CreateTrackedIssue(context.Background(), store, CreateTrackedIssueInput{Title: "background", Type: "Bug"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	ctx := withActor(context.Background(), "scheduler")
	if err := store.Update(ctx, func(payload *SyncPayload) error {
		payload.TrackedIssues[0].FeishuTaskSummary = strPtr("updated by integration")
		return nil
	}); err != nil {
		t.Fatalf("background update: %v", err)
	}
	payload, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	issue := payload.TrackedIssues[0]
	if issue.Revision != created.Revision+1 || issue.UpdatedBy == nil || *issue.UpdatedBy != "scheduler" {
		t.Fatalf("background mutation metadata not advanced: %+v", issue)
	}
}
