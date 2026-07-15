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

func TestSyncAdminStatusAndTokenRotationSurviveRestart(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, cfg := newTestSQLiteStore(t)
	ctx := withActor(withWorkspaceID(context.Background(), defaultWorkspaceID), "web:admin")
	if _, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: "sync status", Type: "Bug"}); err != nil {
		t.Fatalf("create issue: %v", err)
	}

	router := gin.New()
	api := router.Group("/api/v1", WorkspaceAuthMiddleware(store, "web", cfg.WebAccessToken()))
	api.GET("/sync/status", RequireRoles(RoleAdmin, RoleMember, RoleViewer), HandleGetSyncAdminStatus(store))
	api.POST("/sync/token/rotate", RequireRoles(RoleAdmin), HandleRotateSyncToken(store))

	do := func(method, path, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+cfg.WebAccessToken())
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w
	}

	status := do(http.MethodGet, "/api/v1/sync/status", "")
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"syncTokenConfigured":true`) || !strings.Contains(status.Body.String(), `"revision":1`) {
		t.Fatalf("unexpected sync status: code=%d body=%s", status.Code, status.Body.String())
	}

	rotated := do(http.MethodPost, "/api/v1/sync/token/rotate", "{}")
	if rotated.Code != http.StatusOK {
		t.Fatalf("rotate status=%d body=%s", rotated.Code, rotated.Body.String())
	}
	var response RotateSyncTokenResponse
	if err := json.Unmarshal(rotated.Body.Bytes(), &response); err != nil || len(response.Token) < 32 {
		t.Fatalf("invalid rotated token response: %s", rotated.Body.String())
	}
	if _, err := store.ResolveWorkspace(context.Background(), "sync", response.Token); err != nil {
		t.Fatalf("rotated token does not authenticate: %v", err)
	}
	if _, err := store.ResolveWorkspace(context.Background(), "sync", cfg.SyncAccessToken()); err == nil {
		t.Fatal("old sync token still authenticates after rotation")
	}

	reopened, err := NewSQLiteStore(context.Background(), cfg)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	if _, err := reopened.ResolveWorkspace(context.Background(), "sync", response.Token); err != nil {
		t.Fatalf("rotated token lost after restart: %v", err)
	}
}
