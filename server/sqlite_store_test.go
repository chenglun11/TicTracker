package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func newTestSQLiteStore(t *testing.T) (*SQLiteStore, *Config) {
	t.Helper()
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 binary not available")
	}
	dir := t.TempDir()
	cfg := &Config{
		DataDir:              dir,
		DatabasePath:         filepath.Join(dir, "test.sqlite3"),
		SQLiteBin:            "sqlite3",
		Token:                "legacy",
		SyncToken:            "sync-token",
		WebToken:             "web-token",
		DefaultWorkspaceName: "Test Workspace",
	}
	store, err := NewSQLiteStore(context.Background(), cfg)
	if err != nil {
		t.Fatalf("NewSQLiteStore: %v", err)
	}
	return store, cfg
}

func TestSQLiteStoreLegacyImportAndIdempotentNormalize(t *testing.T) {
	dir := t.TempDir()
	if _, err := exec.LookPath("sqlite3"); err != nil {
		t.Skip("sqlite3 binary not available")
	}
	payload := SyncPayload{
		LastModified: 1,
		Records:      map[string]map[string]int{"2026-05-19": {"Support": 3}},
		DailyNotes:   map[string]string{"2026-05-19": "note"},
		TrackedIssues: []TrackedIssue{{
			ID:           "issue-1",
			IssueNumber:  7,
			Type:         "Bug",
			Title:        "legacy issue",
			DateKey:      "2026-05-19",
			CreatedAt:    FlexTime{Value: "2026-05-19 09:00:00"},
			Status:       StatusPending,
			Source:       "Web",
			ReporterName: strPtr("Max"),
			IssueTags:    []string{"今日Bug", "今日Bug"},
			Comments:     []IssueComment{{ID: "c1", Text: "hello", CreatedAt: FlexTime{Value: "2026-05-19 10:00:00"}}},
		}},
	}
	data, _ := json.Marshal(payload)
	if err := os.WriteFile(filepath.Join(dir, "sync.json"), data, 0o600); err != nil {
		t.Fatalf("write legacy sync: %v", err)
	}
	cfg := &Config{DataDir: dir, DatabasePath: filepath.Join(dir, "test.sqlite3"), SQLiteBin: "sqlite3", SyncToken: "sync", WebToken: "web"}
	store, err := NewSQLiteStore(context.Background(), cfg)
	if err != nil {
		t.Fatalf("NewSQLiteStore: %v", err)
	}

	got, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.TrackedIssues) != 1 || got.TrackedIssues[0].Title != "legacy issue" {
		t.Fatalf("legacy payload not imported: %+v", got)
	}
	if got.TrackedIssues[0].ReporterName == nil || *got.TrackedIssues[0].ReporterName != "Max" {
		t.Fatalf("reporter was not preserved: %+v", got.TrackedIssues[0])
	}

	if err := store.savePayload(context.Background(), defaultWorkspaceID, got); err != nil {
		t.Fatalf("repeat save: %v", err)
	}
	out, err := store.query(context.Background(), "SELECT count(*) FROM issue_tags WHERE workspace_id='default' AND issue_id='issue-1';")
	if err != nil {
		t.Fatalf("query tags: %v", err)
	}
	if strings.TrimSpace(string(out)) != "1" {
		t.Fatalf("expected idempotent tag normalization, got %q", out)
	}

	payload.TrackedIssues[0].Title = "legacy issue changed"
	changed, _ := json.Marshal(payload)
	if err := os.WriteFile(filepath.Join(dir, "sync.json"), changed, 0o600); err != nil {
		t.Fatalf("rewrite legacy sync: %v", err)
	}
	if err := store.importLegacySyncFile(context.Background()); err != nil {
		t.Fatalf("repeat changed legacy import: %v", err)
	}
	got, err = store.Load(context.Background())
	if err != nil {
		t.Fatalf("Load after changed import: %v", err)
	}
	if got.TrackedIssues[0].Title != "legacy issue changed" {
		t.Fatalf("changed legacy sync was not re-imported: %+v", got.TrackedIssues[0])
	}
}

func TestSQLiteWorkspaceTokenIsolation(t *testing.T) {
	store, _ := newTestSQLiteStore(t)
	ctx := context.Background()

	if err := store.savePayload(ctx, "team-a", &SyncPayload{
		LastModified:  1,
		TrackedIssues: []TrackedIssue{{ID: "a", Title: "team a", CreatedAt: FlexTime{Value: "2026-05-19 09:00:00"}}},
	}); err != nil {
		t.Fatalf("save team-a: %v", err)
	}
	if err := store.savePayload(ctx, "team-b", &SyncPayload{
		LastModified:  1,
		TrackedIssues: []TrackedIssue{{ID: "b", Title: "team b", CreatedAt: FlexTime{Value: "2026-05-19 09:00:00"}}},
	}); err != nil {
		t.Fatalf("save team-b: %v", err)
	}
	_, err := store.exec(ctx, "UPDATE workspaces SET sync_token='sync-a', web_token='web-a' WHERE id='team-a'; UPDATE workspaces SET sync_token='sync-b', web_token='web-b' WHERE id='team-b';")
	if err != nil {
		t.Fatalf("set tokens: %v", err)
	}

	workspace, err := store.ResolveWorkspace(ctx, "sync", "sync-a")
	if err != nil {
		t.Fatalf("resolve sync-a: %v", err)
	}
	got, err := store.Load(withWorkspaceID(ctx, workspace.ID))
	if err != nil {
		t.Fatalf("load team-a: %v", err)
	}
	if len(got.TrackedIssues) != 1 || got.TrackedIssues[0].ID != "a" {
		t.Fatalf("wrong workspace data: %+v", got.TrackedIssues)
	}
	if _, err := store.ResolveWorkspace(ctx, "web", "sync-a"); err == nil {
		t.Fatal("sync token should not resolve as web token")
	}
}

func TestSQLiteSyncPostThenAPIReadsSameWorkspace(t *testing.T) {
	store, cfg := newTestSQLiteStore(t)
	r := gin.New()
	syncGroup := r.Group("/", WorkspaceAuthMiddleware(store, "sync", cfg.SyncAccessToken()))
	syncGroup.POST("/sync", HandlePostSync(store))
	apiGroup := r.Group("/api", WorkspaceAuthMiddleware(store, "web", cfg.WebAccessToken()))
	apiGroup.GET("/issues", HandleGetIssues(store))

	body := `{"lastModified":1,"trackedIssues":[{"id":"sync-1","issueNumber":1,"type":"Bug","title":"from sync","dateKey":"2026-05-19","createdAt":"2026-05-19 09:00:00","status":"待处理","source":"macOS","comments":[],"reporterName":"Max","issueTags":["今日Bug"]}]}`
	post := httptest.NewRequest(http.MethodPost, "/sync", strings.NewReader(body))
	post.Header.Set("Authorization", "Bearer "+cfg.SyncAccessToken())
	w := httptest.NewRecorder()
	r.ServeHTTP(w, post)
	if w.Code != http.StatusOK {
		t.Fatalf("POST /sync status=%d body=%s", w.Code, w.Body.String())
	}

	get := httptest.NewRequest(http.MethodGet, "/api/issues", nil)
	get.Header.Set("Authorization", "Bearer "+cfg.WebAccessToken())
	w = httptest.NewRecorder()
	r.ServeHTTP(w, get)
	if w.Code != http.StatusOK {
		t.Fatalf("GET /api/issues status=%d body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "from sync") || !strings.Contains(w.Body.String(), "今日Bug") {
		t.Fatalf("API did not read sqlite-imported sync payload: %s", w.Body.String())
	}
}

func TestWebAccountInitLoginAndSessionAuth(t *testing.T) {
	store, cfg := newTestSQLiteStore(t)
	r := gin.New()
	r.GET("/api/v1/auth/status", HandleAuthStatus(store))
	r.POST("/api/v1/auth/init", HandleAuthInit(store))
	r.POST("/api/v1/auth/login", HandleAuthLogin(store))
	apiGroup := r.Group("/api/v1", WorkspaceAuthMiddleware(store, "web", cfg.WebAccessToken()))
	apiGroup.GET("/setup", HandleGetSetup(store))

	status := httptest.NewRequest(http.MethodGet, "/api/v1/auth/status", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, status)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"initialized":false`) {
		t.Fatalf("unexpected auth status: code=%d body=%s", w.Code, w.Body.String())
	}

	initBody := `{"username":"admin","password":"password123","setup":{"departments":["Support"],"teamMembers":["Max"],"currentMemberName":"Max","feishu":{"enabled":false,"webhookURL":"","webhookSecret":"","sendHour":18,"sendMinute":0,"focusIssueTag":"今日Bug","appID":"","appSecret":"","verificationToken":"","encryptKey":"","tasklistGUID":""},"linear":{"enabled":false,"teamId":"","teamName":"","projectId":"","projectName":""}}}`
	initReq := httptest.NewRequest(http.MethodPost, "/api/v1/auth/init", strings.NewReader(initBody))
	initReq.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	r.ServeHTTP(w, initReq)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"token"`) {
		t.Fatalf("init failed: code=%d body=%s", w.Code, w.Body.String())
	}
	var initResp LoginResponse
	if err := json.Unmarshal(w.Body.Bytes(), &initResp); err != nil {
		t.Fatalf("decode init response: %v", err)
	}

	setupReq := httptest.NewRequest(http.MethodGet, "/api/v1/setup", nil)
	setupReq.Header.Set("Authorization", "Bearer "+initResp.Token)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, setupReq)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"currentMemberName":"Max"`) {
		t.Fatalf("session could not access setup: code=%d body=%s", w.Code, w.Body.String())
	}

	badLogin := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"username":"admin","password":"wrong-password"}`))
	badLogin.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	r.ServeHTTP(w, badLogin)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("bad login should be rejected: code=%d body=%s", w.Code, w.Body.String())
	}

	goodLogin := httptest.NewRequest(http.MethodPost, "/api/v1/auth/login", strings.NewReader(`{"username":"admin","password":"password123"}`))
	goodLogin.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	r.ServeHTTP(w, goodLogin)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"token"`) {
		t.Fatalf("good login failed: code=%d body=%s", w.Code, w.Body.String())
	}
}

func TestFeishuCardActionResolvesWorkspaceByIssue(t *testing.T) {
	store, _ := newTestSQLiteStore(t)
	ctx := context.Background()
	if err := store.savePayload(ctx, "team-a", &SyncPayload{
		LastModified: 1,
		TrackedIssues: []TrackedIssue{{
			ID:        "card-issue",
			Title:     "card issue",
			Status:    StatusPending,
			CreatedAt: FlexTime{Value: "2026-05-19 09:00:00"},
		}},
	}); err != nil {
		t.Fatalf("save team-a: %v", err)
	}

	r := gin.New()
	r.POST("/feishu/card", HandleCardAction(nil, store))
	body := `{"action":{"value":{"issue_id":"card-issue","action":"update_status"},"option":"测试中"}}`
	req := httptest.NewRequest(http.MethodPost, "/feishu/card", strings.NewReader(body))
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("card action status=%d body=%s", w.Code, w.Body.String())
	}

	got, err := store.Load(withWorkspaceID(ctx, "team-a"))
	if err != nil {
		t.Fatalf("load team-a: %v", err)
	}
	if got.TrackedIssues[0].Status != StatusTesting {
		t.Fatalf("card action did not update resolved workspace, got %q", got.TrackedIssues[0].Status)
	}
	defaultPayload, err := store.Load(ctx)
	if err != nil {
		t.Fatalf("load default: %v", err)
	}
	for _, issue := range defaultPayload.TrackedIssues {
		if issue.ID == "card-issue" {
			t.Fatalf("card issue leaked into default workspace: %+v", issue)
		}
	}
}

func TestSQLiteFeishuRunSuccessLookup(t *testing.T) {
	store, _ := newTestSQLiteStore(t)
	ctx := context.Background()
	sent, err := store.HasSuccessfulFeishuRun(ctx, "team-a", "18:00", "2026-05-19")
	if err != nil {
		t.Fatalf("initial lookup: %v", err)
	}
	if sent {
		t.Fatal("unexpected sent run before insert")
	}
	if err := store.SaveFeishuRun(ctx, "team-a", "18:00", "2026-05-19", "2026-05-19 18:00:00", true, ""); err != nil {
		t.Fatalf("save run: %v", err)
	}
	sent, err = store.HasSuccessfulFeishuRun(ctx, "team-a", "18:00", "2026-05-19")
	if err != nil {
		t.Fatalf("lookup after save: %v", err)
	}
	if !sent {
		t.Fatal("expected successful run lookup to participate in scheduler dedupe")
	}
}

func strPtr(v string) *string {
	return &v
}
