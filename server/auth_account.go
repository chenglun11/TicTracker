package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
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
	Token string `json:"token"`
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

		if err := store.CreateWebAccount(c.Request.Context(), defaultWorkspaceID, username, body.Password); err != nil {
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
		c.JSON(http.StatusOK, LoginResponse{Token: token})
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
		ok, err := store.CheckWebAccount(c.Request.Context(), defaultWorkspaceID, username, body.Password)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to check account"})
			return
		}
		if !ok {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid username or password"})
			return
		}
		token, err := store.CreateWebSession(c.Request.Context(), defaultWorkspaceID, username)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create session"})
			return
		}
		c.JSON(http.StatusOK, LoginResponse{Token: token})
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
	salt, err := randomHex(16)
	if err != nil {
		return err
	}
	hash := hashPassword(salt, password)
	now := time.Now().Format("2006-01-02 15:04:05")
	sql := fmt.Sprintf(`INSERT INTO web_accounts(workspace_id, username, password_salt, password_hash, created_at, updated_at)
VALUES(%s,%s,%s,%s,%s,%s);`,
		sqlQuote(workspaceID), sqlQuote(username), sqlQuote(salt), sqlQuote(hash), sqlQuote(now), sqlQuote(now))
	_, err = s.exec(ctx, sql)
	return err
}

func (s *SQLiteStore) CheckWebAccount(ctx context.Context, workspaceID, username, password string) (bool, error) {
	out, err := s.query(ctx, "SELECT password_salt || char(9) || password_hash FROM web_accounts WHERE workspace_id = "+sqlQuote(workspaceID)+" AND username = "+sqlQuote(username)+" LIMIT 1;")
	if err != nil {
		return false, err
	}
	parts := strings.Split(strings.TrimSpace(string(out)), "\t")
	if len(parts) != 2 {
		return false, nil
	}
	got := hashPassword(parts[0], password)
	return subtle.ConstantTimeCompare([]byte(got), []byte(parts[1])) == 1, nil
}

func (s *SQLiteStore) CreateWebSession(ctx context.Context, workspaceID, username string) (string, error) {
	token, err := randomHex(32)
	if err != nil {
		return "", err
	}
	now := time.Now()
	sql := fmt.Sprintf(`INSERT INTO web_sessions(token, workspace_id, username, expires_at, created_at)
VALUES(%s,%s,%s,%s,%s);`,
		sqlQuote(token), sqlQuote(workspaceID), sqlQuote(username), sqlQuote(now.Add(sessionTTL).Format(time.RFC3339)), sqlQuote(now.Format(time.RFC3339)))
	if _, err := s.exec(ctx, sql); err != nil {
		return "", err
	}
	return token, nil
}

func (s *SQLiteStore) ResolveWebSession(ctx context.Context, token string) (string, error) {
	now := time.Now().Format(time.RFC3339)
	out, err := s.query(ctx, "SELECT workspace_id FROM web_sessions WHERE token = "+sqlQuote(token)+" AND expires_at > "+sqlQuote(now)+" LIMIT 1;")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
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
