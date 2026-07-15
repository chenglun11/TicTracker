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
type actorContextKey struct{}
type identityContextKey struct{}

const (
	RoleAdmin  = "admin"
	RoleMember = "member"
	RoleViewer = "viewer"
)

type AuthIdentity struct {
	Username    string `json:"username"`
	DisplayName string `json:"displayName"`
	Role        string `json:"role"`
}

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

func withActor(ctx context.Context, actor string) context.Context {
	actor = strings.TrimSpace(actor)
	if len(actor) > 120 {
		actor = actor[:120]
	}
	return context.WithValue(ctx, actorContextKey{}, actor)
}

func actorFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	actor, _ := ctx.Value(actorContextKey{}).(string)
	return strings.TrimSpace(actor)
}

func withIdentity(ctx context.Context, identity AuthIdentity) context.Context {
	return context.WithValue(ctx, identityContextKey{}, identity)
}

func identityFromContext(ctx context.Context) (AuthIdentity, bool) {
	if ctx == nil {
		return AuthIdentity{}, false
	}
	identity, ok := ctx.Value(identityContextKey{}).(AuthIdentity)
	return identity, ok
}

func validRole(role string) bool {
	return role == RoleAdmin || role == RoleMember || role == RoleViewer
}

func RequireRoles(roles ...string) gin.HandlerFunc {
	allowed := make(map[string]bool, len(roles))
	for _, role := range roles {
		allowed[role] = true
	}
	return func(c *gin.Context) {
		identity, ok := identityFromContext(c.Request.Context())
		if !ok || !allowed[identity.Role] {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "insufficient permissions", "code": "forbidden"})
			return
		}
		c.Next()
	}
}

func authorizedContext(ctx context.Context, workspaceID, actor string, identity AuthIdentity) context.Context {
	ctx = withWorkspaceID(ctx, workspaceID)
	ctx = withActor(ctx, actor)
	return withIdentity(ctx, identity)
}

func capabilityActor(c *gin.Context, capability string) string {
	if capability == "sync" {
		if clientID := strings.TrimSpace(c.GetHeader("X-Client-ID")); clientID != "" {
			return "macOS:" + clientID
		}
	}
	return capability + "-token"
}

func WorkspaceAuthMiddleware(store *SQLiteStore, capability string, legacyToken string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if store == nil {
			AuthMiddleware(legacyToken)(c)
			return
		}

		auth := c.GetHeader("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}

		token := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
		workspace, err := store.ResolveWorkspace(c.Request.Context(), capability, token)
		if err == nil && workspace != nil {
			identity := AuthIdentity{Username: capability + "-token", DisplayName: capability + " token", Role: RoleAdmin}
			ctx := authorizedContext(c.Request.Context(), workspace.ID, capabilityActor(c, capability), identity)
			c.Request = c.Request.WithContext(ctx)
			c.Set("workspaceID", workspace.ID)
			c.Next()
			return
		}

		if capability == "web" {
			if workspaceID, identity, err := store.ResolveWebSession(c.Request.Context(), token); err == nil && workspaceID != "" {
				ctx := authorizedContext(c.Request.Context(), workspaceID, "web:"+identity.Username, identity)
				c.Request = c.Request.WithContext(ctx)
				c.Set("workspaceID", workspaceID)
				c.Next()
				return
			}
		}

		if legacyToken != "" && subtle.ConstantTimeCompare([]byte(token), []byte(legacyToken)) == 1 {
			identity := AuthIdentity{Username: capability + "-token", DisplayName: capability + " token", Role: RoleAdmin}
			ctx := authorizedContext(c.Request.Context(), defaultWorkspaceID, capabilityActor(c, capability), identity)
			c.Request = c.Request.WithContext(ctx)
			c.Set("workspaceID", defaultWorkspaceID)
			c.Next()
			return
		}

		c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
	}
}
