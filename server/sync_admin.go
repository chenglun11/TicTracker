package main

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type SyncAdminStatus struct {
	Revision            int64   `json:"revision"`
	LastModified        float64 `json:"lastModified"`
	LastModifiedBy      string  `json:"lastModifiedBy,omitempty"`
	EventCursor         int64   `json:"eventCursor"`
	SyncTokenConfigured bool    `json:"syncTokenConfigured"`
	SyncTokenHint       string  `json:"syncTokenHint,omitempty"`
	CheckedAt           string  `json:"checkedAt"`
}

type RotateSyncTokenResponse struct {
	Token     string `json:"token"`
	TokenHint string `json:"tokenHint"`
	RotatedAt string `json:"rotatedAt"`
}

func HandleGetSyncAdminStatus(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		ctx := c.Request.Context()
		payload, err := store.Load(ctx)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync status"})
			return
		}
		workspace, err := store.ResolveWorkspaceByID(ctx, workspaceIDFromContext(ctx))
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync credentials"})
			return
		}
		cursor, err := store.LatestCollaborationCursor(ctx, workspace.ID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync event cursor"})
			return
		}
		c.JSON(http.StatusOK, SyncAdminStatus{
			Revision:            payload.Revision,
			LastModified:        payload.LastModified,
			LastModifiedBy:      payload.LastModifiedBy,
			EventCursor:         cursor,
			SyncTokenConfigured: strings.TrimSpace(workspace.SyncToken) != "",
			SyncTokenHint:       tokenHint(workspace.SyncToken),
			CheckedAt:           time.Now().UTC().Format(time.RFC3339),
		})
	}
}

func HandleRotateSyncToken(store *SQLiteStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		var raw [32]byte
		if _, err := rand.Read(raw[:]); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate sync token"})
			return
		}
		token := hex.EncodeToString(raw[:])
		if err := store.RotateWorkspaceSyncToken(c.Request.Context(), workspaceIDFromContext(c.Request.Context()), token); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to rotate sync token"})
			return
		}
		c.JSON(http.StatusOK, RotateSyncTokenResponse{
			Token:     token,
			TokenHint: tokenHint(token),
			RotatedAt: time.Now().UTC().Format(time.RFC3339),
		})
	}
}

func tokenHint(token string) string {
	token = strings.TrimSpace(token)
	if token == "" {
		return "未配置"
	}
	if len(token) <= 8 {
		return "••••" + token
	}
	return "••••" + token[len(token)-8:]
}
