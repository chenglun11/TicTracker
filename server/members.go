package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

var (
	memberUsernameRegexp = regexp.MustCompile(`^[A-Za-z0-9._-]{2,64}$`)
	errMemberExists      = errors.New("member already exists")
	errMemberNotFound    = errors.New("member not found")
	errLastAdmin         = errors.New("workspace must keep one active admin")
	errSelfAdminChange   = errors.New("admin cannot demote or disable self")
)

type WorkspaceMember struct {
	Username    string  `json:"username"`
	DisplayName string  `json:"displayName"`
	Role        string  `json:"role"`
	DisabledAt  *string `json:"disabledAt,omitempty"`
}

type CreateMemberRequest struct {
	Username    string `json:"username"`
	DisplayName string `json:"displayName"`
	Role        string `json:"role"`
	Password    string `json:"password"`
}

type UpdateMemberRequest struct {
	DisplayName *string `json:"displayName"`
	Role        *string `json:"role"`
	Disabled    *bool   `json:"disabled"`
	Password    *string `json:"password"`
}

func normalizeMemberInput(username, displayName, role, password string) (string, string, string, error) {
	username = strings.TrimSpace(username)
	displayName = strings.TrimSpace(displayName)
	role = strings.TrimSpace(role)
	if !memberUsernameRegexp.MatchString(username) {
		return "", "", "", fmt.Errorf("username must be 2-64 letters, numbers, dot, dash, or underscore")
	}
	if displayName == "" || len([]rune(displayName)) > 80 || strings.ContainsAny(displayName, "\t\r\n") {
		return "", "", "", fmt.Errorf("displayName is required and must be at most 80 characters")
	}
	if !validRole(role) {
		return "", "", "", fmt.Errorf("invalid role")
	}
	if len(password) < 8 || len(password) > 200 {
		return "", "", "", fmt.Errorf("password must be 8-200 characters")
	}
	return username, displayName, role, nil
}

func (s *SQLiteStore) CreateWorkspaceMember(ctx context.Context, workspaceID, username, displayName, role, password string) error {
	username, displayName, role, err := normalizeMemberInput(username, displayName, role, password)
	if err != nil {
		return err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	now := time.Now().Format("2006-01-02 15:04:05")
	eventTime := time.Now().UTC().Format(time.RFC3339Nano)
	payload, _ := json.Marshal(WorkspaceMember{Username: username, DisplayName: displayName, Role: role})
	s.mu.Lock()
	defer s.mu.Unlock()
	exists, err := s.query(ctx, "SELECT 1 FROM web_accounts WHERE workspace_id="+sqlQuote(workspaceID)+" AND username="+sqlQuote(username)+" LIMIT 1;")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(exists)) == "1" {
		return errMemberExists
	}
	sql := fmt.Sprintf(`BEGIN IMMEDIATE;
INSERT INTO users(workspace_id,id,name,role,disabled_at,created_at,updated_at) VALUES(%s,%s,%s,%s,NULL,%s,%s);
INSERT INTO web_accounts(workspace_id,username,password_salt,password_hash,created_at,updated_at) VALUES(%s,%s,'',%s,%s,%s);
INSERT INTO collaboration_events(workspace_id,event_type,entity_id,entity_revision,payload_json,actor,created_at) VALUES(%s,'member.created',%s,1,%s,%s,%s);
COMMIT;
`, sqlQuote(workspaceID), sqlQuote(username), sqlQuote(displayName), sqlQuote(role), sqlQuote(now), sqlQuote(now),
		sqlQuote(workspaceID), sqlQuote(username), sqlQuote(string(hash)), sqlQuote(now), sqlQuote(now),
		sqlQuote(workspaceID), sqlQuote(username), sqlQuote(string(payload)), sqlQuote(actorFromContext(ctx)), sqlQuote(eventTime))
	if _, err = s.exec(ctx, sql); err != nil {
		return err
	}
	s.notifyCollaborationEvents(workspaceID)
	return nil
}

func (s *SQLiteStore) ListWorkspaceMembers(ctx context.Context, workspaceID string) ([]WorkspaceMember, error) {
	out, err := s.query(ctx, `SELECT id || char(9) || name || char(9) || role || char(9) || coalesce(disabled_at,'')
FROM users WHERE workspace_id=`+sqlQuote(workspaceID)+" ORDER BY disabled_at IS NOT NULL, name COLLATE NOCASE;")
	if err != nil {
		return nil, err
	}
	members := make([]WorkspaceMember, 0)
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		for len(parts) < 4 {
			parts = append(parts, "")
		}
		member := WorkspaceMember{Username: parts[0], DisplayName: parts[1], Role: parts[2]}
		if parts[3] != "" {
			member.DisabledAt = &parts[3]
		}
		members = append(members, member)
	}
	return members, nil
}

func (s *SQLiteStore) UpdateWorkspaceMember(ctx context.Context, workspaceID, targetUsername, actingUsername string, req UpdateMemberRequest) error {
	targetUsername = strings.TrimSpace(targetUsername)
	s.mu.Lock()
	defer s.mu.Unlock()
	out, err := s.query(ctx, "SELECT name || char(9) || role || char(9) || coalesce(disabled_at,'') FROM users WHERE workspace_id="+sqlQuote(workspaceID)+" AND id="+sqlQuote(targetUsername)+" LIMIT 1;")
	if err != nil {
		return err
	}
	parts := strings.Split(strings.TrimSpace(string(out)), "\t")
	if len(parts) < 2 {
		return errMemberNotFound
	}
	currentRole := parts[1]
	nextRole := currentRole
	if req.Role != nil {
		nextRole = strings.TrimSpace(*req.Role)
		if !validRole(nextRole) {
			return fmt.Errorf("invalid role")
		}
	}
	disable := len(parts) >= 3 && parts[2] != ""
	if req.Disabled != nil {
		disable = *req.Disabled
	}
	if targetUsername == actingUsername && (nextRole != RoleAdmin || disable) {
		return errSelfAdminChange
	}
	if currentRole == RoleAdmin && (nextRole != RoleAdmin || disable) {
		countOut, countErr := s.query(ctx, "SELECT count(*) FROM users WHERE workspace_id="+sqlQuote(workspaceID)+" AND role='admin' AND disabled_at IS NULL;")
		if countErr != nil {
			return countErr
		}
		if strings.TrimSpace(string(countOut)) == "1" {
			return errLastAdmin
		}
	}

	updates := []string{"role=" + sqlQuote(nextRole), "updated_at=" + sqlQuote(time.Now().Format("2006-01-02 15:04:05"))}
	if req.DisplayName != nil {
		name := strings.TrimSpace(*req.DisplayName)
		if name == "" || len([]rune(name)) > 80 || strings.ContainsAny(name, "\t\r\n") {
			return fmt.Errorf("invalid displayName")
		}
		updates = append(updates, "name="+sqlQuote(name))
	}
	if req.Disabled != nil {
		if disable {
			updates = append(updates, "disabled_at="+sqlQuote(time.Now().Format(time.RFC3339)))
		} else {
			updates = append(updates, "disabled_at=NULL")
		}
	}
	statements := []string{"BEGIN IMMEDIATE", "UPDATE users SET " + strings.Join(updates, ",") + " WHERE workspace_id=" + sqlQuote(workspaceID) + " AND id=" + sqlQuote(targetUsername)}
	if req.Password != nil {
		if len(*req.Password) < 8 || len(*req.Password) > 200 {
			return fmt.Errorf("password must be 8-200 characters")
		}
		hash, hashErr := bcrypt.GenerateFromPassword([]byte(*req.Password), bcrypt.DefaultCost)
		if hashErr != nil {
			return hashErr
		}
		statements = append(statements, "UPDATE web_accounts SET password_salt='',password_hash="+sqlQuote(string(hash))+",updated_at="+sqlQuote(time.Now().Format("2006-01-02 15:04:05"))+" WHERE workspace_id="+sqlQuote(workspaceID)+" AND username="+sqlQuote(targetUsername))
	}
	if disable {
		statements = append(statements, "DELETE FROM web_sessions WHERE workspace_id="+sqlQuote(workspaceID)+" AND username="+sqlQuote(targetUsername))
	}
	eventType := "member.updated"
	if disable {
		eventType = "member.disabled"
	}
	statements = append(statements, `INSERT INTO collaboration_events(workspace_id,event_type,entity_id,entity_revision,payload_json,actor,created_at)
SELECT workspace_id,`+sqlQuote(eventType)+`,id,1,json_object('username',id,'displayName',name,'role',role,'disabledAt',disabled_at),`+sqlQuote(actorFromContext(ctx))+`,`+sqlQuote(time.Now().UTC().Format(time.RFC3339Nano))+` FROM users
WHERE workspace_id=`+sqlQuote(workspaceID)+` AND id=`+sqlQuote(targetUsername))
	statements = append(statements, "COMMIT")
	if _, err = s.exec(ctx, strings.Join(statements, ";\n")+";\n"); err != nil {
		return err
	}
	s.notifyCollaborationEvents(workspaceID)
	return nil
}

func (s *SQLiteStore) IsWorkspaceMemberActive(ctx context.Context, workspaceID, username string) (bool, error) {
	out, err := s.query(ctx, "SELECT 1 FROM users WHERE workspace_id="+sqlQuote(workspaceID)+" AND id="+sqlQuote(username)+" AND disabled_at IS NULL LIMIT 1;")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) == "1", nil
}

func HandleGetCurrentUser() gin.HandlerFunc {
	return func(c *gin.Context) {
		identity, ok := identityFromContext(c.Request.Context())
		if !ok {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"user": identity})
	}
}

func HandleListMembers(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		members, err := store.ListWorkspaceMembers(c.Request.Context(), workspaceIDFromContext(c.Request.Context()))
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to list members"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"members": members})
	}
}

func HandleCreateMember(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body CreateMemberRequest
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}
		err := store.CreateWorkspaceMember(c.Request.Context(), workspaceIDFromContext(c.Request.Context()), body.Username, body.DisplayName, body.Role, body.Password)
		if errors.Is(err, errMemberExists) {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error(), "code": "member_exists"})
			return
		}
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "code": "invalid_member"})
			return
		}
		c.JSON(http.StatusCreated, gin.H{"success": true})
	}
}

func HandleUpdateMember(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		identity, _ := identityFromContext(c.Request.Context())
		var body UpdateMemberRequest
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}
		err := store.UpdateWorkspaceMember(c.Request.Context(), workspaceIDFromContext(c.Request.Context()), c.Param("username"), identity.Username, body)
		switch {
		case errors.Is(err, errMemberNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": err.Error(), "code": "member_not_found"})
		case errors.Is(err, errLastAdmin), errors.Is(err, errSelfAdminChange):
			c.JSON(http.StatusConflict, gin.H{"error": err.Error(), "code": "admin_invariant"})
		case err != nil:
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "code": "invalid_member"})
		default:
			c.JSON(http.StatusOK, gin.H{"success": true})
		}
	}
}
