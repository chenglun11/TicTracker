package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// Web issues are a projection of Linear. Until Linear write-back is enabled,
// the web API must not create, mutate, claim, comment on, or delete issues.
func rejectIssueWrite(c *gin.Context) {
	c.AbortWithStatusJSON(http.StatusMethodNotAllowed, gin.H{
		"error": "issues are managed in Linear; the web workspace is read-only",
		"code":  "linear_read_only",
	})
}
