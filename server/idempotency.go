package main

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"strings"

	"github.com/gin-gonic/gin"
)

type operationIDContextKey struct{}

var (
	operationIDRegexp          = regexp.MustCompile(`^[A-Za-z0-9._:-]{8,128}$`)
	errOperationAlreadyApplied = errors.New("operation already applied")
)

func withOperationID(ctx context.Context, operationID string) context.Context {
	return context.WithValue(ctx, operationIDContextKey{}, strings.TrimSpace(operationID))
}

func operationIDFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	value, _ := ctx.Value(operationIDContextKey{}).(string)
	return strings.TrimSpace(value)
}

func RequireIdempotencyKey() gin.HandlerFunc {
	return func(c *gin.Context) {
		operationID := strings.TrimSpace(c.GetHeader("Idempotency-Key"))
		if !operationIDRegexp.MatchString(operationID) {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{
				"error": "a valid Idempotency-Key is required",
				"code":  "idempotency_key_required",
			})
			return
		}
		c.Request = c.Request.WithContext(withOperationID(c.Request.Context(), operationID))
		c.Next()
	}
}

func (s *SQLiteStore) OperationEntityID(ctx context.Context, workspaceID, operationID string) (string, error) {
	out, err := s.query(ctx, "SELECT entity_id FROM collaboration_events WHERE workspace_id="+sqlQuote(workspaceID)+" AND operation_id="+sqlQuote(operationID)+" LIMIT 1;")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func operationReplayMatches(store PayloadStore, ctx context.Context, entityID string) (bool, error) {
	sqliteStore, ok := store.(*SQLiteStore)
	if !ok {
		return true, nil
	}
	appliedEntityID, err := sqliteStore.OperationEntityID(ctx, workspaceIDFromContext(ctx), operationIDFromContext(ctx))
	if err != nil {
		return false, err
	}
	return appliedEntityID == entityID, nil
}
