package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

const sessionTTL = 30 * 24 * time.Hour

type AuthStatusResponse struct {
	Initialized bool `json:"initialized"`
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginResponse struct {
	Token string       `json:"token"`
	User  AuthIdentity `json:"user"`
}

type ChangePasswordRequest struct {
	CurrentPassword string `json:"currentPassword"`
	NewPassword     string `json:"newPassword"`
}

type InitRequest struct {
	Username string       `json:"username"`
	Password string       `json:"password"`
	Setup    SetupRequest `json:"setup"`
}

func HandleAuthStatus(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		initialized, err := store.HasWebAccount(c.Request.Context(), defaultWorkspaceID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read auth status"})
			return
		}
		c.JSON(http.StatusOK, AuthStatusResponse{Initialized: initialized})
	}
}

func HandleAuthInit(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		initialized, err := store.HasWebAccount(c.Request.Context(), defaultWorkspaceID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read auth status"})
			return
		}
		if initialized {
			c.JSON(http.StatusConflict, gin.H{"error": "admin account already initialized"})
			return
		}

		var body InitRequest
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}
		username := strings.TrimSpace(body.Username)
		if username == "" || len(body.Password) < 8 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "username and password(>=8) are required"})
			return
		}

		displayName := strings.TrimSpace(body.Setup.CurrentMemberName)
		if displayName == "" {
			displayName = username
		}
		if err := store.CreateWorkspaceMember(c.Request.Context(), defaultWorkspaceID, username, displayName, RoleAdmin, body.Password); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create account"})
			return
		}
		if err := store.Update(withWorkspaceID(c.Request.Context(), defaultWorkspaceID), func(payload *SyncPayload) error {
			applySetup(payload, body.Setup)
			return nil
		}); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save setup"})
			return
		}

		token, err := store.CreateWebSession(c.Request.Context(), defaultWorkspaceID, username)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create session"})
			return
		}
		c.JSON(http.StatusOK, LoginResponse{Token: token, User: AuthIdentity{Username: username, DisplayName: displayName, Role: RoleAdmin}})
	}
}

func HandleAuthLogin(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body LoginRequest
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}
		username := strings.TrimSpace(body.Username)
		limitKey := c.ClientIP() + "|" + strings.ToLower(username)
		if allowed, retryAfter := webLoginFailures.allow(limitKey, time.Now()); !allowed {
			c.Header("Retry-After", strconv.Itoa(int(retryAfter.Seconds())+1))
			c.JSON(http.StatusTooManyRequests, gin.H{"error": "too many login attempts", "code": "login_rate_limited"})
			return
		}
		ok, err := store.CheckWebAccount(c.Request.Context(), defaultWorkspaceID, username, body.Password)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to check account"})
			return
		}
		if !ok {
			webLoginFailures.failed(limitKey, time.Now())
			c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid username or password"})
			return
		}
		webLoginFailures.reset(limitKey)
		token, err := store.CreateWebSession(c.Request.Context(), defaultWorkspaceID, username)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create session"})
			return
		}
		_, identity, resolveErr := store.ResolveWebSession(c.Request.Context(), token)
		if resolveErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to resolve session"})
			return
		}
		c.JSON(http.StatusOK, LoginResponse{Token: token, User: identity})
	}
}

func HandleAuthLogout(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		token := strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
		if token != "" {
			if err := store.RevokeWebSession(c.Request.Context(), token); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to revoke session"})
				return
			}
		}
		c.Status(http.StatusNoContent)
	}
}

func HandleChangePassword(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		identity, ok := identityFromContext(c.Request.Context())
		if !ok || identity.Username == "" {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}
		var body ChangePasswordRequest
		if err := c.ShouldBindJSON(&body); err != nil || len(body.NewPassword) < 8 || len(body.NewPassword) > 200 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "new password must be 8-200 characters"})
			return
		}
		if body.CurrentPassword == body.NewPassword {
			c.JSON(http.StatusBadRequest, gin.H{"error": "new password must differ from current password"})
			return
		}
		ctx := c.Request.Context()
		workspaceID := workspaceIDFromContext(ctx)
		valid, err := store.CheckWebAccount(ctx, workspaceID, identity.Username, body.CurrentPassword)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to check current password"})
			return
		}
		if !valid {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "current password is incorrect"})
			return
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(body.NewPassword), bcrypt.DefaultCost)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to hash password"})
			return
		}
		now := time.Now().Format("2006-01-02 15:04:05")
		if _, err := store.exec(ctx, "UPDATE web_accounts SET password_salt='',password_hash="+sqlQuote(string(hash))+",updated_at="+sqlQuote(now)+" WHERE workspace_id="+sqlQuote(workspaceID)+" AND username="+sqlQuote(identity.Username)+";"); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to save password"})
			return
		}
		// 让旧设备上的会话全部失效，再为当前设备签发新会话。
		_, _ = store.exec(ctx, "DELETE FROM web_sessions WHERE workspace_id="+sqlQuote(workspaceID)+" AND username="+sqlQuote(identity.Username)+";")
		token, err := store.CreateWebSession(ctx, workspaceID, identity.Username)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "password changed but failed to create session"})
			return
		}
		c.JSON(http.StatusOK, LoginResponse{Token: token, User: identity})
	}
}

func (s *SQLiteStore) HasWebAccount(ctx context.Context, workspaceID string) (bool, error) {
	out, err := s.query(ctx, "SELECT 1 FROM web_accounts WHERE workspace_id = "+sqlQuote(workspaceID)+" LIMIT 1;")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) == "1", nil
}

func (s *SQLiteStore) CreateWebAccount(ctx context.Context, workspaceID, username, password string) error {
	return s.CreateWorkspaceMember(ctx, workspaceID, username, username, RoleAdmin, password)
}

func (s *SQLiteStore) CheckWebAccount(ctx context.Context, workspaceID, username, password string) (bool, error) {
	out, err := s.query(ctx, `SELECT coalesce(nullif(a.password_salt,''),'-') || char(9) || a.password_hash
FROM web_accounts a LEFT JOIN users u ON u.workspace_id=a.workspace_id AND u.id=a.username
WHERE a.workspace_id = `+sqlQuote(workspaceID)+" AND a.username = "+sqlQuote(username)+" AND u.disabled_at IS NULL LIMIT 1;")
	if err != nil {
		return false, err
	}
	parts := strings.Split(strings.TrimSpace(string(out)), "\t")
	if len(parts) != 2 {
		return false, nil
	}
	stored := parts[1]
	if strings.HasPrefix(stored, "$2") {
		return bcrypt.CompareHashAndPassword([]byte(stored), []byte(password)) == nil, nil
	}
	got := hashPassword(parts[0], password)
	ok := subtle.ConstantTimeCompare([]byte(got), []byte(stored)) == 1
	if ok {
		// Successful legacy login upgrades the password hash without forcing a reset.
		if upgraded, hashErr := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost); hashErr == nil {
			now := time.Now().Format("2006-01-02 15:04:05")
			_, _ = s.exec(ctx, "UPDATE web_accounts SET password_salt='', password_hash="+sqlQuote(string(upgraded))+", updated_at="+sqlQuote(now)+" WHERE workspace_id="+sqlQuote(workspaceID)+" AND username="+sqlQuote(username)+";\n")
		}
	}
	return ok, nil
}

func (s *SQLiteStore) CreateWebSession(ctx context.Context, workspaceID, username string) (string, error) {
	token, err := randomHex(32)
	if err != nil {
		return "", err
	}
	now := time.Now()
	_, _ = s.exec(ctx, "DELETE FROM web_sessions WHERE expires_at <= "+sqlQuote(now.Format(time.RFC3339))+";\n")
	sql := fmt.Sprintf(`INSERT INTO web_sessions(token, workspace_id, username, expires_at, created_at)
VALUES(%s,%s,%s,%s,%s);`,
		sqlQuote(sessionTokenHash(token)), sqlQuote(workspaceID), sqlQuote(username), sqlQuote(now.Add(sessionTTL).Format(time.RFC3339)), sqlQuote(now.Format(time.RFC3339)))
	if _, err := s.exec(ctx, sql); err != nil {
		return "", err
	}
	return token, nil
}

func (s *SQLiteStore) ResolveWebSession(ctx context.Context, token string) (string, AuthIdentity, error) {
	now := time.Now().Format(time.RFC3339)
	tokenHash := sessionTokenHash(token)
	out, err := s.query(ctx, `SELECT s.workspace_id || char(9) || s.username || char(9) || coalesce(u.name,s.username) || char(9) || coalesce(u.role,'admin')
	FROM web_sessions s LEFT JOIN users u ON u.workspace_id=s.workspace_id AND u.id=s.username
	WHERE s.token IN (`+sqlQuote(tokenHash)+","+sqlQuote(token)+") AND s.expires_at > "+sqlQuote(now)+" AND u.disabled_at IS NULL LIMIT 1;")
	if err != nil {
		return "", AuthIdentity{}, err
	}
	parts := strings.Split(strings.TrimSpace(string(out)), "\t")
	if len(parts) != 4 {
		return "", AuthIdentity{}, nil
	}
	identity := AuthIdentity{Username: strings.TrimSpace(parts[1]), DisplayName: strings.TrimSpace(parts[2]), Role: strings.TrimSpace(parts[3])}
	if !validRole(identity.Role) {
		return "", AuthIdentity{}, nil
	}
	return strings.TrimSpace(parts[0]), identity, nil
}

func (s *SQLiteStore) RevokeWebSession(ctx context.Context, token string) error {
	_, err := s.exec(ctx, "DELETE FROM web_sessions WHERE token IN ("+sqlQuote(sessionTokenHash(token))+","+sqlQuote(token)+");\n")
	return err
}

func sessionTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func randomHex(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func hashPassword(salt, password string) string {
	sum := sha256.Sum256([]byte(salt + ":" + password))
	for i := 0; i < 120000; i++ {
		next := sha256.Sum256(append(sum[:], salt...))
		sum = next
	}
	return hex.EncodeToString(sum[:])
}
