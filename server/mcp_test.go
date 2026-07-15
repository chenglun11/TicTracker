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

func TestMCPReadKeyCannotWriteAndWriteKeyCreatesIssue(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	cfg := &Config{
		MCPAccessKeys: []MCPAccessKeyConfig{
			{Key: "read-ak", Permissions: []string{"read"}},
			{Key: "write-ak", Permissions: []string{"read", "write"}},
		},
	}
	r := gin.New()
	r.POST("/mcp", NewMCPServer(cfg, store, nil).Handle())

	readList := mcpPost(t, r, "read-ak", `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}`)
	if readList.Code != http.StatusOK || strings.Contains(readList.Body.String(), "tictacker.create_issue") {
		t.Fatalf("read-only tools should not include write tools: code=%d body=%s", readList.Code, readList.Body.String())
	}

	readCreate := mcpPost(t, r, "read-ak", `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tictacker.create_issue","arguments":{"title":"blocked","type":"Bug"}}}`)
	if readCreate.Code != http.StatusOK || !strings.Contains(readCreate.Body.String(), "write permission required") {
		t.Fatalf("read key should be denied write: code=%d body=%s", readCreate.Code, readCreate.Body.String())
	}

	writeCreate := mcpPost(t, r, "write-ak", `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tictacker.create_issue","arguments":{"title":"created from mcp","type":"Bug","issueTags":["今日Bug"]}}}`)
	if writeCreate.Code != http.StatusOK || !strings.Contains(writeCreate.Body.String(), "created from mcp") {
		t.Fatalf("write key should create issue: code=%d body=%s", writeCreate.Code, writeCreate.Body.String())
	}
	got, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.TrackedIssues) != 1 || got.TrackedIssues[0].Title != "created from mcp" || got.TrackedIssues[0].Source != "MCP" {
		t.Fatalf("unexpected created issue: %+v", got.TrackedIssues)
	}
}

func TestMCPCreateLinearIssueCreatesRemoteAndLocalBinding(t *testing.T) {
	var received struct {
		Variables struct {
			Input LinearCreateIssueInput `json:"input"`
		} `json:"variables"`
	}
	linearAPI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "linear-token" {
			t.Fatalf("missing linear token: %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatalf("decode linear request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"issueCreate":{"success":true,"issue":{"id":"lin-id","identifier":"LIN-42","title":"Linear title","url":"https://linear.app/acme/issue/LIN-42","project":{"id":"project-1","name":"Support"},"assignee":{"id":"user-1","name":"Max"}}}}}`))
	}))
	defer linearAPI.Close()

	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	if err := store.Update(context.Background(), func(payload *SyncPayload) error {
		payload.LinearConfig = json.RawMessage(`{"enabled":true,"teamId":"team-1","projectId":"project-1","projectName":"Support","defaultAssigneeId":"user-1"}`)
		return nil
	}); err != nil {
		t.Fatalf("seed store: %v", err)
	}

	cfg := &Config{
		MCPAccessKey:   "write-ak",
		MCPPermissions: "read,write",
		LinearAPIToken: "linear-token",
		LinearAPIURL:   linearAPI.URL,
	}
	r := gin.New()
	r.POST("/mcp", NewMCPServer(cfg, store, NewLinearClient(cfg)).Handle())

	resp := mcpPost(t, r, "write-ak", `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tictacker.create_linear_issue","arguments":{"title":"Linear title","description":"from test","type":"Bug","issueTags":["MCP"]}}}`)
	if resp.Code != http.StatusOK || !strings.Contains(resp.Body.String(), "LIN-42") {
		t.Fatalf("create_linear_issue failed: code=%d body=%s", resp.Code, resp.Body.String())
	}
	if received.Variables.Input.TeamID != "team-1" || received.Variables.Input.ProjectID != "project-1" || received.Variables.Input.AssigneeID != "user-1" {
		t.Fatalf("linear input did not use configured defaults: %+v", received.Variables.Input)
	}

	got, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.TrackedIssues) != 1 {
		t.Fatalf("expected one local issue, got %+v", got.TrackedIssues)
	}
	issue := got.TrackedIssues[0]
	if issue.Source != "Linear" || issue.LinearKey == nil || *issue.LinearKey != "LIN-42" || issue.LinearURL == nil || *issue.LinearURL == "" {
		t.Fatalf("linear binding missing from local issue: %+v", issue)
	}
}

func mcpPost(t *testing.T, r http.Handler, ak string, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-TicTracker-AK", ak)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}
