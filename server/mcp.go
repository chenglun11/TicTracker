package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const (
	mcpProtocolVersion = "2024-11-05"
	mcpPermissionRead  = "read"
	mcpPermissionWrite = "write"
)

type MCPServer struct {
	store       PayloadStore
	linear      *LinearClient
	accessKeys  []mcpAccessKey
	serverLabel string
}

type mcpAccessKey struct {
	key         string
	workspaceID string
	permissions map[string]bool
}

type mcpRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type mcpResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *mcpError       `json:"error,omitempty"`
}

type mcpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type mcpTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

type mcpSession struct {
	workspaceID string
	permissions map[string]bool
}

type mcpToolCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

type serverLinearConfig struct {
	Enabled             bool              `json:"enabled"`
	TeamID              string            `json:"teamId"`
	TeamName            string            `json:"teamName"`
	ProjectID           string            `json:"projectId"`
	ProjectName         string            `json:"projectName"`
	DefaultAssigneeID   string            `json:"defaultAssigneeId"`
	DefaultAssigneeName string            `json:"defaultAssigneeName"`
	AssigneeMapping     map[string]string `json:"assigneeMapping"`
	LabelMapping        map[string]string `json:"labelMapping"`
}

func NewMCPServer(cfg *Config, store PayloadStore, linear *LinearClient) *MCPServer {
	return &MCPServer{
		store:       store,
		linear:      linear,
		accessKeys:  mcpAccessKeysFromConfig(cfg),
		serverLabel: "TicTracker",
	}
}

func RegisterMCPRoutes(r *gin.Engine, cfg *Config, store PayloadStore, linear *LinearClient) {
	server := NewMCPServer(cfg, store, linear)
	r.POST("/mcp", server.Handle())
	r.POST("/mcp/v1", server.Handle())
}

func (s *MCPServer) Handle() gin.HandlerFunc {
	return func(c *gin.Context) {
		session, ok := s.authenticate(c)
		if !ok {
			return
		}
		body, err := c.GetRawData()
		if err != nil {
			c.JSON(http.StatusBadRequest, mcpResponse{
				JSONRPC: "2.0",
				Error:   &mcpError{Code: -32700, Message: "failed to read request body"},
			})
			return
		}
		trimmed := bytes.TrimSpace(body)
		if len(trimmed) == 0 {
			c.JSON(http.StatusBadRequest, mcpResponse{
				JSONRPC: "2.0",
				Error:   &mcpError{Code: -32700, Message: "empty request body"},
			})
			return
		}
		if trimmed[0] == '[' {
			var batch []mcpRequest
			if err := json.Unmarshal(trimmed, &batch); err != nil {
				c.JSON(http.StatusBadRequest, mcpResponse{JSONRPC: "2.0", Error: &mcpError{Code: -32700, Message: "parse error"}})
				return
			}
			responses := make([]mcpResponse, 0, len(batch))
			for _, req := range batch {
				if len(req.ID) == 0 {
					continue
				}
				responses = append(responses, s.dispatch(c.Request.Context(), session, req))
			}
			if len(responses) == 0 {
				c.Status(http.StatusAccepted)
				return
			}
			c.JSON(http.StatusOK, responses)
			return
		}

		var req mcpRequest
		if err := json.Unmarshal(trimmed, &req); err != nil {
			c.JSON(http.StatusBadRequest, mcpResponse{JSONRPC: "2.0", Error: &mcpError{Code: -32700, Message: "parse error"}})
			return
		}
		if len(req.ID) == 0 {
			_ = s.dispatch(c.Request.Context(), session, req)
			c.Status(http.StatusAccepted)
			return
		}
		c.JSON(http.StatusOK, s.dispatch(c.Request.Context(), session, req))
	}
}

func (s *MCPServer) authenticate(c *gin.Context) (mcpSession, bool) {
	if len(s.accessKeys) == 0 {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "mcp access key is not configured"})
		return mcpSession{}, false
	}
	got := strings.TrimSpace(c.GetHeader("X-TicTracker-AK"))
	if got == "" {
		got = strings.TrimSpace(c.GetHeader("X-API-Key"))
	}
	if got == "" {
		auth := c.GetHeader("Authorization")
		if strings.HasPrefix(auth, "Bearer ") {
			got = strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
		}
	}
	if got == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "missing mcp access key"})
		return mcpSession{}, false
	}
	for _, accessKey := range s.accessKeys {
		if subtle.ConstantTimeCompare([]byte(got), []byte(accessKey.key)) == 1 {
			workspaceID := accessKey.workspaceID
			if workspaceID == "" {
				workspaceID = defaultWorkspaceID
			}
			return mcpSession{workspaceID: workspaceID, permissions: accessKey.permissions}, true
		}
	}
	c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid mcp access key"})
	return mcpSession{}, false
}

func (s *MCPServer) dispatch(ctx context.Context, session mcpSession, req mcpRequest) mcpResponse {
	resp := mcpResponse{JSONRPC: "2.0", ID: req.ID}
	switch req.Method {
	case "initialize":
		resp.Result = map[string]any{
			"protocolVersion": mcpProtocolVersion,
			"capabilities": map[string]any{
				"tools": map[string]any{},
			},
			"serverInfo": map[string]any{
				"name":    "tictacker-mcp",
				"title":   s.serverLabel,
				"version": "1.0.0",
			},
		}
	case "ping":
		resp.Result = map[string]any{}
	case "notifications/initialized":
		resp.Result = map[string]any{}
	case "tools/list":
		resp.Result = map[string]any{"tools": s.toolsForSession(session)}
	case "tools/call":
		result, err := s.callTool(withWorkspaceID(ctx, session.workspaceID), session, req.Params)
		if err != nil {
			resp.Error = &mcpError{Code: -32000, Message: err.Error()}
			return resp
		}
		resp.Result = result
	default:
		resp.Error = &mcpError{Code: -32601, Message: "method not found"}
	}
	return resp
}

func (s *MCPServer) toolsForSession(session mcpSession) []mcpTool {
	tools := []mcpTool{
		statusTool(),
		listIssuesTool(),
	}
	if session.permissions[mcpPermissionWrite] {
		tools = append(tools,
			createIssueTool(),
			updateIssueStatusTool(),
			addIssueCommentTool(),
			createLinearIssueTool(),
		)
	}
	return tools
}

func (s *MCPServer) callTool(ctx context.Context, session mcpSession, raw json.RawMessage) (map[string]any, error) {
	var params mcpToolCallParams
	if err := json.Unmarshal(raw, &params); err != nil {
		return nil, fmt.Errorf("invalid tools/call params")
	}
	switch params.Name {
	case "tictacker.get_status":
		return s.callGetStatus(ctx)
	case "tictacker.list_issues":
		return s.callListIssues(ctx, params.Arguments)
	case "tictacker.create_issue":
		if !session.permissions[mcpPermissionWrite] {
			return nil, fmt.Errorf("write permission required")
		}
		return s.callCreateIssue(ctx, params.Arguments)
	case "tictacker.update_issue_status":
		if !session.permissions[mcpPermissionWrite] {
			return nil, fmt.Errorf("write permission required")
		}
		return s.callUpdateIssueStatus(ctx, params.Arguments)
	case "tictacker.add_issue_comment":
		if !session.permissions[mcpPermissionWrite] {
			return nil, fmt.Errorf("write permission required")
		}
		return s.callAddIssueComment(ctx, params.Arguments)
	case "tictacker.create_linear_issue":
		if !session.permissions[mcpPermissionWrite] {
			return nil, fmt.Errorf("write permission required")
		}
		return s.callCreateLinearIssue(ctx, params.Arguments)
	default:
		return nil, fmt.Errorf("unknown tool %q", params.Name)
	}
}

func (s *MCPServer) callGetStatus(ctx context.Context) (map[string]any, error) {
	payload, err := s.store.Load(ctx)
	if err != nil {
		return nil, err
	}
	return mcpTextResult(BuildStatusSummary(payload, time.Now()))
}

func (s *MCPServer) callListIssues(ctx context.Context, raw json.RawMessage) (map[string]any, error) {
	var args struct {
		Status string `json:"status"`
		Limit  int    `json:"limit"`
	}
	_ = json.Unmarshal(raw, &args)
	payload, err := s.store.Load(ctx)
	if err != nil {
		return nil, err
	}
	issues := filterIssuesForMCP(payload.TrackedIssues, args.Status)
	sort.SliceStable(issues, func(i, j int) bool {
		return issues[i].IssueNumber > issues[j].IssueNumber
	})
	if args.Limit > 0 && len(issues) > args.Limit {
		issues = issues[:args.Limit]
	}
	return mcpTextResult(map[string]any{"issues": issues})
}

func (s *MCPServer) callCreateIssue(ctx context.Context, raw json.RawMessage) (map[string]any, error) {
	var args struct {
		Title        string   `json:"title"`
		Type         string   `json:"type"`
		Department   *string  `json:"department"`
		TicketURL    *string  `json:"ticketUrl"`
		ReporterID   *string  `json:"reporterId"`
		ReporterName *string  `json:"reporterName"`
		Assignee     *string  `json:"assignee"`
		IssueTags    []string `json:"issueTags"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("invalid create_issue arguments")
	}
	issue, err := CreateTrackedIssue(ctx, s.store, CreateTrackedIssueInput{
		Title:        args.Title,
		Type:         args.Type,
		Department:   args.Department,
		TicketURL:    args.TicketURL,
		ReporterID:   args.ReporterID,
		ReporterName: args.ReporterName,
		Assignee:     args.Assignee,
		Source:       "MCP",
		IssueTags:    args.IssueTags,
	})
	if err != nil {
		return nil, err
	}
	return mcpTextResult(map[string]any{"success": true, "issue": issue})
}

func (s *MCPServer) callUpdateIssueStatus(ctx context.Context, raw json.RawMessage) (map[string]any, error) {
	var args struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("invalid update_issue_status arguments")
	}
	if !issueIDRegexp.MatchString(args.ID) {
		return nil, fmt.Errorf("invalid issue id")
	}
	status := strings.TrimSpace(args.Status)
	if status == "" {
		return nil, fmt.Errorf("status is required")
	}
	found := false
	err := s.store.Update(ctx, func(payload *SyncPayload) error {
		for i := range payload.TrackedIssues {
			issue := &payload.TrackedIssues[i]
			if issue.ID != args.ID {
				continue
			}
			applyIssueStatus(issue, status)
			now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
			issue.UpdatedAt = &now
			found = true
			return nil
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, fmt.Errorf("issue not found")
	}
	return mcpTextResult(map[string]any{"success": true})
}

func (s *MCPServer) callAddIssueComment(ctx context.Context, raw json.RawMessage) (map[string]any, error) {
	var args struct {
		ID   string `json:"id"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("invalid add_issue_comment arguments")
	}
	if !issueIDRegexp.MatchString(args.ID) {
		return nil, fmt.Errorf("invalid issue id")
	}
	text := strings.TrimSpace(args.Text)
	if text == "" {
		return nil, fmt.Errorf("text is required")
	}
	found := false
	err := s.store.Update(ctx, func(payload *SyncPayload) error {
		for i := range payload.TrackedIssues {
			issue := &payload.TrackedIssues[i]
			if issue.ID != args.ID {
				continue
			}
			now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
			issue.Comments = append(issue.Comments, IssueComment{
				ID:        fmt.Sprintf("%d", time.Now().UnixNano()),
				Text:      text,
				CreatedAt: now,
			})
			issue.UpdatedAt = &now
			found = true
			return nil
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, fmt.Errorf("issue not found")
	}
	return mcpTextResult(map[string]any{"success": true})
}

func (s *MCPServer) callCreateLinearIssue(ctx context.Context, raw json.RawMessage) (map[string]any, error) {
	var args struct {
		Title        string   `json:"title"`
		Description  string   `json:"description"`
		Type         string   `json:"type"`
		Department   *string  `json:"department"`
		ReporterID   *string  `json:"reporterId"`
		ReporterName *string  `json:"reporterName"`
		Assignee     *string  `json:"assignee"`
		AssigneeID   string   `json:"assigneeId"`
		TeamID       string   `json:"teamId"`
		ProjectID    string   `json:"projectId"`
		LabelIDs     []string `json:"labelIds"`
		IssueTags    []string `json:"issueTags"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, fmt.Errorf("invalid create_linear_issue arguments")
	}
	payload, err := s.store.Load(ctx)
	if err != nil {
		return nil, err
	}
	linearCfg := parseServerLinearConfig(payload.LinearConfig)
	teamID := firstNonEmpty(args.TeamID, linearCfg.TeamID)
	projectID := firstNonEmpty(args.ProjectID, linearCfg.ProjectID)
	assigneeID := firstNonEmpty(args.AssigneeID, linearCfg.DefaultAssigneeID)
	if assigneeID == "" && args.Assignee != nil && linearCfg.AssigneeMapping != nil {
		assigneeID = linearCfg.AssigneeMapping[strings.TrimSpace(*args.Assignee)]
	}

	remote, err := s.linear.CreateIssue(ctx, LinearCreateIssueInput{
		Title:       args.Title,
		Description: args.Description,
		TeamID:      teamID,
		ProjectID:   projectID,
		AssigneeID:  assigneeID,
		LabelIDs:    args.LabelIDs,
	})
	if err != nil {
		return nil, err
	}

	linearIssueID := remote.ID
	linearKey := remote.Identifier
	linearURL := remote.URL
	linearProjectID := projectID
	linearProjectName := linearCfg.ProjectName
	if remote.Project != nil {
		linearProjectID = remote.Project.ID
		linearProjectName = remote.Project.Name
	}
	var linearAssignee *string
	if remote.Assignee != nil && strings.TrimSpace(remote.Assignee.Name) != "" {
		linearAssignee = &remote.Assignee.Name
	}
	var linearCreator *string
	if remote.Creator != nil && strings.TrimSpace(remote.Creator.Name) != "" {
		linearCreator = &remote.Creator.Name
	}
	linearCreatedAt := remote.CreatedAt
	linearUpdatedAt := remote.UpdatedAt
	ticketURL := linearURL
	issueType := firstNonEmpty(args.Type, "Bug")
	issue, err := CreateTrackedIssue(ctx, s.store, CreateTrackedIssueInput{
		Title:             args.Title,
		Type:              issueType,
		Department:        args.Department,
		TicketURL:         &ticketURL,
		ReporterID:        args.ReporterID,
		ReporterName:      args.ReporterName,
		Assignee:          args.Assignee,
		Source:            "Linear",
		IssueTags:         args.IssueTags,
		LinearIssueID:     &linearIssueID,
		LinearKey:         &linearKey,
		LinearURL:         &linearURL,
		LinearProjectID:   &linearProjectID,
		LinearProjectName: &linearProjectName,
		LinearAssignee:    linearAssignee,
		LinearCreator:     linearCreator,
		LinearCreatedAt:   &linearCreatedAt,
		LinearUpdatedAt:   &linearUpdatedAt,
	})
	if err != nil {
		return nil, err
	}
	return mcpTextResult(map[string]any{"success": true, "linearIssue": remote, "issue": issue})
}

func mcpTextResult(value any) (map[string]any, error) {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"content": []map[string]string{
			{"type": "text", "text": string(data)},
		},
	}, nil
}

func filterIssuesForMCP(issues []TrackedIssue, statusFilter string) []TrackedIssue {
	today := time.Now().Format("2006-01-02")
	filtered := make([]TrackedIssue, 0, len(issues))
	for _, issue := range issues {
		isResolved := isResolvedStatus(issue.Status)
		switch statusFilter {
		case "":
			filtered = append(filtered, issue)
		case "new":
			if issue.DateKey == today && !isResolved {
				filtered = append(filtered, issue)
			}
		case "pending":
			if !isResolved && issue.Status != StatusObserving && issue.Status != StatusScheduled && issue.Status != StatusTesting {
				filtered = append(filtered, issue)
			}
		case "scheduled":
			if issue.Status == StatusScheduled {
				filtered = append(filtered, issue)
			}
		case "testing":
			if issue.Status == StatusTesting {
				filtered = append(filtered, issue)
			}
		case "observing":
			if issue.Status == StatusObserving {
				filtered = append(filtered, issue)
			}
		case "resolved":
			if isResolved {
				filtered = append(filtered, issue)
			}
		}
	}
	return filtered
}

func parseServerLinearConfig(raw json.RawMessage) serverLinearConfig {
	var cfg serverLinearConfig
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &cfg)
	}
	return cfg
}

func mcpAccessKeysFromConfig(cfg *Config) []mcpAccessKey {
	var keys []mcpAccessKey
	for _, item := range cfg.MCPAccessKeys {
		if key := strings.TrimSpace(item.Key); key != "" {
			keys = append(keys, mcpAccessKey{
				key:         key,
				workspaceID: strings.TrimSpace(item.WorkspaceID),
				permissions: normalizeMCPPermissions(item.Permission, item.Permissions),
			})
		}
	}
	if key := strings.TrimSpace(cfg.MCPAccessKey); key != "" {
		keys = append(keys, mcpAccessKey{
			key:         key,
			workspaceID: strings.TrimSpace(cfg.MCPWorkspaceID),
			permissions: normalizeMCPPermissions(cfg.MCPPermissions, nil),
		})
	}
	return keys
}

func normalizeMCPPermissions(single string, list []string) map[string]bool {
	result := map[string]bool{}
	values := append([]string{}, list...)
	if single != "" {
		values = append(values, strings.Split(single, ",")...)
	}
	for _, raw := range values {
		permission := strings.ToLower(strings.TrimSpace(raw))
		switch permission {
		case mcpPermissionRead, mcpPermissionWrite:
			result[permission] = true
		}
	}
	if len(result) == 0 {
		result[mcpPermissionRead] = true
	}
	return result
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func statusTool() mcpTool {
	return mcpTool{
		Name:        "tictacker.get_status",
		Description: "读取今日计数、问题状态统计和部门列表。",
		InputSchema: objectSchema(nil, nil),
	}
}

func listIssuesTool() mcpTool {
	return mcpTool{
		Name:        "tictacker.list_issues",
		Description: "读取问题追踪列表，支持按状态筛选。",
		InputSchema: objectSchema(map[string]any{
			"status": map[string]any{
				"type":        "string",
				"description": "可选：new、pending、scheduled、testing、observing、resolved。",
			},
			"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 200},
		}, nil),
	}
}

func createIssueTool() mcpTool {
	return mcpTool{
		Name:        "tictacker.create_issue",
		Description: "新增本地问题追踪记录。",
		InputSchema: objectSchema(commonIssueCreateProperties(false), []string{"title", "type"}),
	}
}

func updateIssueStatusTool() mcpTool {
	return mcpTool{
		Name:        "tictacker.update_issue_status",
		Description: "更新问题状态，例如待处理、已排期、测试中、观测中、已修复、已忽略。",
		InputSchema: objectSchema(map[string]any{
			"id":     map[string]any{"type": "string"},
			"status": map[string]any{"type": "string"},
		}, []string{"id", "status"}),
	}
}

func addIssueCommentTool() mcpTool {
	return mcpTool{
		Name:        "tictacker.add_issue_comment",
		Description: "给问题追加备注。",
		InputSchema: objectSchema(map[string]any{
			"id":   map[string]any{"type": "string"},
			"text": map[string]any{"type": "string"},
		}, []string{"id", "text"}),
	}
}

func createLinearIssueTool() mcpTool {
	props := commonIssueCreateProperties(true)
	props["description"] = map[string]any{"type": "string"}
	props["teamId"] = map[string]any{"type": "string", "description": "可选；未传时使用 workspace linearConfig.teamId。"}
	props["projectId"] = map[string]any{"type": "string", "description": "可选；未传时使用 workspace linearConfig.projectId。"}
	props["assigneeId"] = map[string]any{"type": "string", "description": "可选；未传时使用默认 Linear 负责人或 assigneeMapping。"}
	props["labelIds"] = map[string]any{"type": "array", "items": map[string]any{"type": "string"}}
	return mcpTool{
		Name:        "tictacker.create_linear_issue",
		Description: "在 Linear 创建问题，并同步生成本地问题追踪记录及 Linear 绑定字段。",
		InputSchema: objectSchema(props, []string{"title"}),
	}
}

func commonIssueCreateProperties(includeOptionalType bool) map[string]any {
	props := map[string]any{
		"title":        map[string]any{"type": "string"},
		"type":         map[string]any{"type": "string", "description": "Bug、Feature、Support 等本地类型。"},
		"department":   map[string]any{"type": "string"},
		"ticketUrl":    map[string]any{"type": "string"},
		"reporterId":   map[string]any{"type": "string"},
		"reporterName": map[string]any{"type": "string"},
		"assignee":     map[string]any{"type": "string"},
		"issueTags":    map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
	}
	if includeOptionalType {
		props["type"] = map[string]any{"type": "string", "description": "可选；默认 Bug。"}
	}
	return props
}

func objectSchema(properties map[string]any, required []string) map[string]any {
	if properties == nil {
		properties = map[string]any{}
	}
	schema := map[string]any{
		"type":                 "object",
		"properties":           properties,
		"additionalProperties": false,
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}
