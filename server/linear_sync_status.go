package main

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

type LinearSyncStatus struct {
	Enabled     bool   `json:"enabled"`
	Configured  bool   `json:"configured"`
	Mode        string `json:"mode"`
	Description string `json:"description"`
}

// HandleLinearSyncStatus deliberately reports capability only. The collector
// remains disabled until the server-side Linear ingestion worker is enabled.
func HandleLinearSyncStatus(cfg *Config) gin.HandlerFunc {
	return func(c *gin.Context) {
		configured := cfg != nil && strings.TrimSpace(cfg.LinearAPIToken) != ""
		enabled := cfg != nil && cfg.LinearSyncEnabled
		mode := "disabled"
		description := "服务端暂未启用 Linear 采集；当前只保留配置能力。"
		if enabled && configured {
			mode = "ready"
			description = "Linear 采集已开启，等待服务端采集器接入。"
		} else if enabled {
			mode = "missing_token"
			description = "已打开 Linear 采集开关，但尚未配置 API Token。"
		}
		c.JSON(http.StatusOK, LinearSyncStatus{Enabled: enabled, Configured: configured, Mode: mode, Description: description})
	}
}
