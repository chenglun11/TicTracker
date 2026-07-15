package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestWorkspaceRBACAtomicClaimAndAdminInvariants(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store, cfg := newTestSQLiteStore(t)
	ctx := withWorkspaceID(context.Background(), defaultWorkspaceID)
	for _, member := range []CreateMemberRequest{
		{Username: "admin", DisplayName: "Alice Admin", Role: RoleAdmin, Password: "password-admin"},
		{Username: "bob", DisplayName: "Bob", Role: RoleMember, Password: "password-bob"},
		{Username: "carol", DisplayName: "Carol", Role: RoleMember, Password: "password-carol"},
		{Username: "viewer", DisplayName: "View Only", Role: RoleViewer, Password: "password-viewer"},
	} {
		if err := store.CreateWorkspaceMember(ctx, defaultWorkspaceID, member.Username, member.DisplayName, member.Role, member.Password); err != nil {
			t.Fatalf("create member %s: %v", member.Username, err)
		}
	}
	tokens := make(map[string]string)
	for _, username := range []string{"admin", "bob", "carol", "viewer"} {
		token, err := store.CreateWebSession(ctx, defaultWorkspaceID, username)
		if err != nil {
			t.Fatalf("create session %s: %v", username, err)
		}
		tokens[username] = token
	}
	storedToken, err := store.query(ctx, "SELECT token FROM web_sessions WHERE username='bob' LIMIT 1;")
	if err != nil || strings.TrimSpace(string(storedToken)) == tokens["bob"] || !strings.HasPrefix(strings.TrimSpace(string(storedToken)), "sha256:") {
		t.Fatalf("session token must be stored as a hash: stored=%q err=%v", storedToken, err)
	}
	created, err := CreateTrackedIssue(ctx, store, CreateTrackedIssueInput{Title: "claim me", Type: "Bug", Source: "Web"})
	if err != nil {
		t.Fatalf("create issue: %v", err)
	}

	router := gin.New()
	api := router.Group("/api/v1", WorkspaceAuthMiddleware(store, "web", cfg.WebAccessToken()))
	read := RequireRoles(RoleAdmin, RoleMember, RoleViewer)
	write := RequireRoles(RoleAdmin, RoleMember)
	admin := RequireRoles(RoleAdmin)
	api.GET("/members", read, HandleListMembers(store))
	api.PATCH("/members/:username", admin, HandleUpdateMember(store))
	api.POST("/issues/:id/claim", write, HandleClaimIssue(store))

	do := func(method, path, body, username, revision string) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tokens[username])
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		if revision != "" {
			req.Header.Set("If-Match", revision)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w
	}

	if w := do(http.MethodGet, "/api/v1/members", "", "viewer", ""); w.Code != http.StatusOK || !strings.Contains(w.Body.String(), `"role":"viewer"`) {
		t.Fatalf("viewer list members: code=%d body=%s", w.Code, w.Body.String())
	}
	if w := do(http.MethodPost, "/api/v1/issues/"+created.ID+"/claim", "", "viewer", `"1"`); w.Code != http.StatusForbidden {
		t.Fatalf("viewer mutation status=%d body=%s", w.Code, w.Body.String())
	}

	first := do(http.MethodPost, "/api/v1/issues/"+created.ID+"/claim", "", "bob", `"1"`)
	if first.Code != http.StatusOK || !strings.Contains(first.Body.String(), `"assignee":"Bob"`) || !strings.Contains(first.Body.String(), `"revision":2`) {
		t.Fatalf("first claim status=%d body=%s", first.Code, first.Body.String())
	}
	second := do(http.MethodPost, "/api/v1/issues/"+created.ID+"/claim", "", "carol", `"1"`)
	if second.Code != http.StatusConflict {
		t.Fatalf("second claim status=%d body=%s", second.Code, second.Body.String())
	}
	payload, err := store.Load(ctx)
	if err != nil || payload.TrackedIssues[0].Assignee == nil || *payload.TrackedIssues[0].Assignee != "Bob" {
		t.Fatalf("claim winner not preserved: issue=%+v err=%v", payload.TrackedIssues[0], err)
	}

	selfDemote := do(http.MethodPatch, "/api/v1/members/admin", `{"role":"viewer"}`, "admin", "")
	if selfDemote.Code != http.StatusConflict || !strings.Contains(selfDemote.Body.String(), "admin_invariant") {
		t.Fatalf("self demote status=%d body=%s", selfDemote.Code, selfDemote.Body.String())
	}
	disableBob := do(http.MethodPatch, "/api/v1/members/bob", `{"disabled":true}`, "admin", "")
	if disableBob.Code != http.StatusOK {
		t.Fatalf("disable bob status=%d body=%s", disableBob.Code, disableBob.Body.String())
	}
	if w := do(http.MethodGet, "/api/v1/members", "", "bob", ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("disabled session still authorized: code=%d body=%s", w.Code, w.Body.String())
	}
	active, err := store.IsWorkspaceMemberActive(ctx, defaultWorkspaceID, "bob")
	if err != nil || active {
		t.Fatalf("disabled member remains active: active=%v err=%v", active, err)
	}
	events, err := store.ListCollaborationEvents(ctx, defaultWorkspaceID, 0, 100)
	if err != nil {
		t.Fatalf("list member events: %v", err)
	}
	foundDisabled := false
	for _, event := range events {
		if event.Type == "member.disabled" && event.EntityID == "bob" {
			foundDisabled = true
		}
	}
	if !foundDisabled {
		t.Fatalf("member.disabled event missing: %+v", events)
	}
}

func TestLegacyPasswordHashUpgradesToBcrypt(t *testing.T) {
	store, _ := newTestSQLiteStore(t)
	ctx := context.Background()
	salt := "legacy-salt"
	legacy := hashPassword(salt, "legacy-password")
	now := "2026-07-13 12:00:00"
	_, err := store.exec(ctx, `INSERT INTO users(workspace_id,id,name,role,created_at,updated_at) VALUES('default','legacy','Legacy','member','`+now+`','`+now+`');
INSERT INTO web_accounts(workspace_id,username,password_salt,password_hash,created_at,updated_at) VALUES('default','legacy','`+salt+`','`+legacy+`','`+now+`','`+now+`');`)
	if err != nil {
		t.Fatalf("seed legacy account: %v", err)
	}
	ok, err := store.CheckWebAccount(ctx, defaultWorkspaceID, "legacy", "legacy-password")
	if err != nil || !ok {
		t.Fatalf("legacy login: ok=%v err=%v", ok, err)
	}
	out, err := store.query(ctx, "SELECT password_hash FROM web_accounts WHERE workspace_id='default' AND username='legacy';")
	if err != nil || !strings.HasPrefix(strings.TrimSpace(string(out)), "$2") {
		t.Fatalf("password was not upgraded to bcrypt: hash=%q err=%v", out, err)
	}
}
