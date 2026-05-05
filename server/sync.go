package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

func HandleGetSync(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		data, err := store.LoadRaw(c.Request.Context())
		if err != nil {
			if os.IsNotExist(err) {
				slog.Info("sync GET: no data file")
				c.JSON(http.StatusNotFound, gin.H{"error": "no data"})
				return
			}
			slog.Warn("sync GET error", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}

		slog.Info("sync GET", "bytes", len(data))
		c.Data(http.StatusOK, "application/json", data)
	}
}

func HandlePostSync(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		ctx := c.Request.Context()
		body, err := c.GetRawData()
		if err != nil {
			slog.Warn("sync POST read failed", "err", err)
			c.JSON(http.StatusBadRequest, gin.H{"error": "failed to read body"})
			return
		}

		slog.Info("sync POST", "bytes", len(body))

		var incoming SyncPayload
		if err := json.Unmarshal(body, &incoming); err != nil {
			slog.Warn("sync POST invalid json", "err", err)
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid json"})
			return
		}
		if incoming.LastModified == 0 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "lastModified is required"})
			return
		}

		slog.Info("sync POST incoming", "issues", len(incoming.TrackedIssues), "last_modified", incoming.LastModified)

		// 加载服务端当前数据，合并 Web 端变更
		server, _ := store.Load(ctx)
		if server != nil && len(server.TrackedIssues) > 0 {
			mergeWebChanges(&incoming, server)
		}

		// 保留服务端飞书发送时间（防止客户端覆盖导致重复发送）
		preserveFeishuSentTimes(&incoming, server)

		merged, err := json.MarshalIndent(&incoming, "", "  ")
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "marshal failed"})
			return
		}

		if err := store.ReplaceRaw(ctx, merged); err != nil {
			slog.Warn("sync POST save failed", "err", err)
			msg := err.Error()
			if strings.Contains(msg, "invalid json") || strings.Contains(msg, "lastModified") {
				c.JSON(http.StatusBadRequest, gin.H{"error": msg})
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": msg})
			return
		}

		slog.Info("sync POST saved", "issues", len(incoming.TrackedIssues))
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	}
}

// mergeWebChanges 将服务端 Web 创建/编辑的 issue 合并到客户端上传的数据中
func mergeWebChanges(incoming *SyncPayload, server *SyncPayload) {
	incomingIndex := make(map[string]int, len(incoming.TrackedIssues))
	for i, issue := range incoming.TrackedIssues {
		incomingIndex[issue.ID] = i
	}

	added, updated := 0, 0
	for _, sIssue := range server.TrackedIssues {
		idx, exists := incomingIndex[sIssue.ID]
		if !exists {
			if sIssue.Source == "Web" {
				incoming.TrackedIssues = append(incoming.TrackedIssues, sIssue)
				added++
			}
			continue
		}
		if sIssue.UpdatedAt != nil && (incoming.TrackedIssues[idx].UpdatedAt == nil ||
			compareUpdatedAt(sIssue.UpdatedAt, incoming.TrackedIssues[idx].UpdatedAt) > 0) {
			incoming.TrackedIssues[idx] = sIssue
			updated++
		}
	}
	if added > 0 || updated > 0 {
		slog.Info("sync merge", "added_web_issues", added, "updated_from_server", updated)
	}
}

// compareUpdatedAt 解析时间字符串后比较；解析失败回退到字典序
//
// 之前的字典序比较仅在时区一致时正确；现在用 time.Parse 转 Time 后比较更稳
func compareUpdatedAt(a, b *FlexTime) int {
	if a == nil || b == nil {
		return 0
	}
	ta, errA := parseFlexTime(a.Value)
	tb, errB := parseFlexTime(b.Value)
	if errA == nil && errB == nil {
		switch {
		case ta.After(tb):
			return 1
		case ta.Before(tb):
			return -1
		default:
			return 0
		}
	}
	// fallback: 字典序
	switch {
	case a.Value > b.Value:
		return 1
	case a.Value < b.Value:
		return -1
	}
	return 0
}

func parseFlexTime(s string) (time.Time, error) {
	for _, layout := range []string{
		"2006-01-02 15:04:05",
		time.RFC3339,
		time.RFC3339Nano,
		"2006-01-02T15:04:05",
	} {
		if t, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return t, nil
		}
	}
	return time.Time{}, &time.ParseError{Value: s}
}

// preserveFeishuSentTimes 保留服务端的飞书发送时间，取两端较新的值
func preserveFeishuSentTimes(incoming *SyncPayload, server *SyncPayload) {
	if server == nil || server.FeishuBotConfig == nil || incoming.FeishuBotConfig == nil {
		return
	}
	sCfg := server.FeishuBotConfig
	iCfg := incoming.FeishuBotConfig

	if compareSentDateTime(sCfg.LastSentDateTime, iCfg.LastSentDateTime) > 0 {
		slog.Info("preserve feishu lastSentDateTime",
			"server", sCfg.LastSentDateTime, "client", iCfg.LastSentDateTime)
		iCfg.LastSentDateTime = sCfg.LastSentDateTime
	}

	if iCfg.LastSentTimes == nil {
		iCfg.LastSentTimes = make(map[string]string)
	}
	for key, sDate := range sCfg.LastSentTimes {
		if iDate, ok := iCfg.LastSentTimes[key]; !ok || sDate > iDate {
			iCfg.LastSentTimes[key] = sDate
		}
	}
}

func compareSentDateTime(a, b string) int {
	ta, errA := time.ParseInLocation("2006-01-02 15:04:05", a, time.Local)
	tb, errB := time.ParseInLocation("2006-01-02 15:04:05", b, time.Local)
	if errA == nil && errB == nil {
		switch {
		case ta.After(tb):
			return 1
		case ta.Before(tb):
			return -1
		default:
			return 0
		}
	}
	switch {
	case a > b:
		return 1
	case a < b:
		return -1
	}
	return 0
}
