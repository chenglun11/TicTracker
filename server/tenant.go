package main

import (
	"context"
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

const defaultWorkspaceID = "default"

type workspaceContextKey struct{}

type Workspace struct {
	ID        string
	Name      string
	SyncToken string
	WebToken  string
}

func withWorkspaceID(ctx context.Context, workspaceID string) context.Context {
	if workspaceID == "" {
		workspaceID = defaultWorkspaceID
	}
	return context.WithValue(ctx, workspaceContextKey{}, workspaceID)
}

func workspaceIDFromContext(ctx context.Context) string {
	if ctx == nil {
		return defaultWorkspaceID
	}
	if id, ok := ctx.Value(workspaceContextKey{}).(string); ok && id != "" {
		return id
	}
	return defaultWorkspaceID
}

func WorkspaceAuthMiddleware(store *SQLiteStore, capability string, legacyToken string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if store == nil {
			AuthMiddleware(legacyToken)(c)
			return
		}

		auth := c.GetHeader("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			if legacyToken == "" {
				c.Request = c.Request.WithContext(withWorkspaceID(c.Request.Context(), defaultWorkspaceID))
				c.Next()
				return
			}
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}

		token := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
		workspace, err := store.ResolveWorkspace(c.Request.Context(), capability, token)
		if err == nil && workspace != nil {
			c.Request = c.Request.WithContext(withWorkspaceID(c.Request.Context(), workspace.ID))
			c.Set("workspaceID", workspace.ID)
			c.Next()
			return
		}

		if capability == "web" {
			if workspaceID, err := store.ResolveWebSession(c.Request.Context(), token); err == nil && workspaceID != "" {
				c.Request = c.Request.WithContext(withWorkspaceID(c.Request.Context(), workspaceID))
				c.Set("workspaceID", workspaceID)
				c.Next()
				return
			}
		}

		if legacyToken != "" && subtle.ConstantTimeCompare([]byte(token), []byte(legacyToken)) == 1 {
			c.Request = c.Request.WithContext(withWorkspaceID(c.Request.Context(), defaultWorkspaceID))
			c.Set("workspaceID", defaultWorkspaceID)
			c.Next()
			return
		}

		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
	}
}
