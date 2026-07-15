package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

var errSyncRevisionConflict = errors.New("sync revision conflict")
var errSyncRevisionAlreadyInitialized = errors.New("sync revision already initialized")

func validateSyncUpload(body []byte, incoming *SyncPayload) error {
	if incoming.SchemaVersion != 2 {
		return errors.New("schemaVersion 2 is required")
	}
	if incoming.PayloadScope != "workspace-data" {
		return errors.New("payloadScope must be workspace-data")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return errors.New("invalid json")
	}
	for _, key := range []string{"departments", "records", "dailyNotes", "trackedIssues", "teamMembers"} {
		value, exists := fields[key]
		if !exists || string(value) == "null" {
			return errors.New("required workspace field is missing: " + key)
		}
	}
	var members []json.RawMessage
	if err := json.Unmarshal(fields["teamMembers"], &members); err != nil {
		return errors.New("teamMembers must be an array")
	}
	return nil
}

func loadVersionedPayload(ctx context.Context, store PayloadStore) (*SyncPayload, error) {
	payload, err := store.Load(ctx)
	if err != nil || payload.Revision > 0 || payload.LastModified == 0 {
		return payload, err
	}

	// 旧 SQLite/sync.json 数据没有 revision。首次由新客户端读取时原子地
	// 推进到 revision 1，避免它被误判为一个可随意初始化的空工作区。
	err = store.Update(ctx, func(current *SyncPayload) error {
		if current.Revision > 0 {
			return errSyncRevisionAlreadyInitialized
		}
		current.Revision = 1
		return nil
	})
	if err != nil && !errors.Is(err, errSyncRevisionAlreadyInitialized) {
		return nil, err
	}
	return store.Load(ctx)
}

func setSyncRevisionHeaders(c *gin.Context, revision int64) {
	value := strconv.FormatInt(revision, 10)
	c.Header("ETag", `"`+value+`"`)
	c.Header("X-Sync-Revision", value)
}

func parseExpectedRevision(value string) (int64, error) {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "W/")
	value = strings.Trim(value, `"`)
	if value == "" || value == "*" {
		return 0, errors.New("missing sync revision")
	}
	revision, err := strconv.ParseInt(value, 10, 64)
	if err != nil || revision < 0 {
		return 0, errors.New("invalid sync revision")
	}
	return revision, nil
}

func HandleGetSync(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := loadVersionedPayload(c.Request.Context(), store)
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

		data, err := json.Marshal(syncClientProjection(payload))
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to encode sync data"})
			return
		}
		setSyncRevisionHeaders(c, payload.Revision)
		slog.Info("sync GET", "bytes", len(data), "revision", payload.Revision)
		c.Data(http.StatusOK, "application/json", data)
	}
}

func HandlePostSync(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		ctx := c.Request.Context()
		expectedRevision, err := parseExpectedRevision(c.GetHeader("If-Match"))
		if err != nil {
			c.JSON(http.StatusPreconditionRequired, gin.H{
				"error": "If-Match sync revision is required; download the online snapshot before uploading",
			})
			return
		}
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
		if err := validateSyncUpload(body, &incoming); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error(), "code": "invalid_sync_snapshot"})
			return
		}

		slog.Info("sync POST incoming", "issues", len(incoming.TrackedIssues), "last_modified", incoming.LastModified)

		var currentRevision int64
		err = store.Update(ctx, func(server *SyncPayload) error {
			currentRevision = server.Revision
			if currentRevision != expectedRevision {
				return errSyncRevisionConflict
			}

			// 条件写入成功意味着客户端基于当前线上版本编辑。服务端集成
			// 配置仍由 setup API 管理，不能被同步快照写入或清空。
			preserveServerRuntimeConfiguration(&incoming, server)
			incoming.Revision = server.Revision + 1
			*server = incoming
			return nil
		})
		if errors.Is(err, errSyncRevisionConflict) {
			setSyncRevisionHeaders(c, currentRevision)
			c.JSON(http.StatusConflict, gin.H{
				"error":    "online data changed; download and reconcile before retrying",
				"revision": currentRevision,
			})
			return
		}
		if err != nil {
			slog.Warn("sync POST save failed", "err", err)
			msg := err.Error()
			if strings.Contains(msg, "invalid json") || strings.Contains(msg, "lastModified") {
				c.JSON(http.StatusBadRequest, gin.H{"error": msg})
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": msg})
			return
		}

		newRevision := expectedRevision + 1
		setSyncRevisionHeaders(c, newRevision)
		slog.Info("sync POST saved", "issues", len(incoming.TrackedIssues), "revision", newRevision)
		c.JSON(http.StatusOK, gin.H{"status": "ok", "revision": newRevision})
	}
}

// syncClientProjection exposes workspace data only. Integration settings and
// credentials belong to the server runtime/setup API and must never be returned
// through a bearer sync token.
func syncClientProjection(payload *SyncPayload) *SyncPayload {
	if payload == nil {
		return &SyncPayload{}
	}
	projected := *payload
	if projected.Departments == nil {
		projected.Departments = []string{}
	}
	if projected.Records == nil {
		projected.Records = map[string]map[string]int{}
	}
	if projected.DailyNotes == nil {
		projected.DailyNotes = map[string]string{}
	}
	if projected.TrackedIssues == nil {
		projected.TrackedIssues = []TrackedIssue{}
	}
	if len(projected.TeamMembers) == 0 || string(projected.TeamMembers) == "null" {
		projected.TeamMembers = json.RawMessage("[]")
	}
	projected.ConfigurationScope = ""
	projected.JiraConfig = nil
	projected.LinearConfig = nil
	projected.FeishuBotConfig = nil
	projected.FeishuWebhookSecrets = nil
	projected.AIConfig = nil
	projected.RSSFeeds = nil
	projected.TodoTasks = nil
	return &projected
}

// A full client snapshot replaces workspace data, but cannot set or erase
// server-side integrations. Those fields are managed by authenticated setup
// endpoints with their own redaction rules.
func preserveServerRuntimeConfiguration(incoming, server *SyncPayload) {
	if incoming == nil || server == nil {
		return
	}
	incoming.ConfigurationScope = server.ConfigurationScope
	incoming.JiraConfig = server.JiraConfig
	incoming.LinearConfig = server.LinearConfig
	incoming.FeishuBotConfig = server.FeishuBotConfig
	incoming.FeishuWebhookSecrets = server.FeishuWebhookSecrets
	incoming.AIConfig = server.AIConfig
	incoming.RSSFeeds = server.RSSFeeds
	incoming.TodoTasks = server.TodoTasks
}

// HandleGetSyncMeta 为 Web 和其他轻量客户端提供低成本变更探测。
// 客户端只在 revision 变化时重新拉取业务数据。
func HandleGetSyncMeta(store PayloadStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := loadVersionedPayload(c.Request.Context(), store)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read sync metadata"})
			return
		}
		setSyncRevisionHeaders(c, payload.Revision)
		c.JSON(http.StatusOK, gin.H{
			"revision":       payload.Revision,
			"lastModified":   payload.LastModified,
			"lastModifiedBy": payload.LastModifiedBy,
		})
	}
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
