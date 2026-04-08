package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"

	"github.com/gin-gonic/gin"
)

func syncFilePath(dataDir string) string {
	return filepath.Join(dataDir, "sync.json")
}

func HandleGetSync(dataDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		data, err := os.ReadFile(syncFilePath(dataDir))
		if err != nil {
			if os.IsNotExist(err) {
				c.JSON(http.StatusNotFound, gin.H{"error": "no data"})
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		c.Data(http.StatusOK, "application/json", data)
	}
}

func HandlePostSync(dataDir string) gin.HandlerFunc {
	return func(c *gin.Context) {
		// 直接读取原始 body，不做结构体绑定，避免字段丢失
		body, err := io.ReadAll(c.Request.Body)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "failed to read body"})
			return
		}

		// 只验证是合法 JSON 且包含 lastModified
		var check map[string]interface{}
		if err := json.Unmarshal(body, &check); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid json"})
			return
		}
		if _, ok := check["lastModified"]; !ok {
			c.JSON(http.StatusBadRequest, gin.H{"error": "lastModified is required"})
			return
		}

		if err := os.MkdirAll(dataDir, 0755); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		tmpPath := syncFilePath(dataDir) + ".tmp"
		if err := os.WriteFile(tmpPath, body, 0644); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		if err := os.Rename(tmpPath, syncFilePath(dataDir)); err != nil {
			os.Remove(tmpPath)
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	}
}
