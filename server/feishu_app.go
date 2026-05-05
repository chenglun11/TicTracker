package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

const feishuAPIBase = "https://open.feishu.cn"

// FeishuApp 管理飞书应用凭证和 API 调用
type FeishuApp struct {
	cfg        *Config
	store      *Store
	httpClient *http.Client

	mu          sync.RWMutex
	token       string
	tokenExpire time.Time
}

func NewFeishuApp(cfg *Config, store *Store) *FeishuApp {
	return &FeishuApp{
		cfg:        cfg,
		store:      store,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

// VerificationToken 暴露给中间件做 token 校验
func (f *FeishuApp) VerificationToken() string {
	if v := f.cfg.FeishuVerificationToken; v != "" {
		return v
	}
	if payload, err := f.store.Load(context.Background()); err == nil &&
		payload.FeishuBotConfig != nil {
		return payload.FeishuBotConfig.VerificationToken
	}
	return ""
}

// EncryptKey 暴露给中间件做签名/解密
func (f *FeishuApp) EncryptKey() string {
	if v := f.cfg.FeishuEncryptKey; v != "" {
		return v
	}
	if payload, err := f.store.Load(context.Background()); err == nil &&
		payload.FeishuBotConfig != nil {
		return payload.FeishuBotConfig.EncryptKey
	}
	return ""
}

// allowedChatIDs 命令白名单（来自同步配置）
func (f *FeishuApp) allowedChatIDs() []string {
	payload, err := f.store.Load(context.Background())
	if err != nil || payload.FeishuBotConfig == nil {
		return nil
	}
	return payload.FeishuBotConfig.AllowedChatIDs
}

func (f *FeishuApp) Enabled() bool {
	appID, appSecret := f.credentials()
	return appID != "" && appSecret != ""
}

// credentials 获取凭证：config.yaml 优先，同步数据回退
func (f *FeishuApp) credentials() (appID, appSecret string) {
	appID = f.cfg.FeishuAppID
	appSecret = f.cfg.FeishuAppSecret
	if appID != "" && appSecret != "" {
		return
	}
	payload, err := f.store.Load(context.Background())
	if err != nil || payload.FeishuBotConfig == nil {
		return
	}
	if appID == "" {
		appID = payload.FeishuBotConfig.AppID
	}
	if appSecret == "" {
		appSecret = payload.FeishuBotConfig.AppSecret
		if appSecret == "" {
			// 兼容旧版本：曾经把 app_secret 写到 webhookSecrets["feishu-app-secret"]
			if secrets := payload.FeishuWebhookSecrets; secrets != nil {
				appSecret = secrets["feishu-app-secret"]
			}
		}
	}
	return
}

// invalidateToken 强制下次调用刷新 token；用于 token 失效后的恢复
func (f *FeishuApp) invalidateToken() {
	f.mu.Lock()
	f.token = ""
	f.tokenExpire = time.Time{}
	f.mu.Unlock()
}

// TenantAccessToken 获取或刷新 tenant_access_token
func (f *FeishuApp) TenantAccessToken(ctx context.Context) (string, error) {
	f.mu.RLock()
	if f.token != "" && time.Now().Before(f.tokenExpire) {
		token := f.token
		f.mu.RUnlock()
		return token, nil
	}
	f.mu.RUnlock()

	f.mu.Lock()
	defer f.mu.Unlock()

	// double check
	if f.token != "" && time.Now().Before(f.tokenExpire) {
		return f.token, nil
	}

	appID, appSecret := f.credentials()
	if appID == "" || appSecret == "" {
		return "", fmt.Errorf("feishu app credentials not configured")
	}

	body, err := json.Marshal(map[string]string{
		"app_id":     appID,
		"app_secret": appSecret,
	})
	if err != nil {
		return "", fmt.Errorf("encode auth body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		feishuAPIBase+"/open-apis/auth/v3/tenant_access_token/internal",
		bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build auth req: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := f.httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("fetch token: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Code              int    `json:"code"`
		Msg               string `json:"msg"`
		TenantAccessToken string `json:"tenant_access_token"`
		Expire            int    `json:"expire"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("decode token response: %w", err)
	}
	if result.Code != 0 {
		return "", fmt.Errorf("feishu auth error: code=%d msg=%s", result.Code, result.Msg)
	}

	f.token = result.TenantAccessToken
	expireSec := result.Expire - 60
	if expireSec < 60 {
		expireSec = 60
	}
	f.tokenExpire = time.Now().Add(time.Duration(expireSec) * time.Second)
	slog.Info("tenant_access_token refreshed", "expires_in_sec", result.Expire)
	return f.token, nil
}

// SendMessage 通过飞书 API 发送消息；token 失效时自动刷新一次
func (f *FeishuApp) SendMessage(ctx context.Context, chatID, msgType, content string) error {
	for attempt := 0; attempt < 2; attempt++ {
		err := f.sendMessageOnce(ctx, chatID, msgType, content)
		if err == nil {
			return nil
		}
		// token 失效：99991671 (invalid token) / 99991668 (token expired)
		if attempt == 0 && (errors.Is(err, errFeishuInvalidToken)) {
			f.invalidateToken()
			continue
		}
		return err
	}
	return nil
}

var errFeishuInvalidToken = errors.New("feishu token invalid, retry")

func (f *FeishuApp) sendMessageOnce(ctx context.Context, chatID, msgType, content string) error {
	token, err := f.TenantAccessToken(ctx)
	if err != nil {
		return err
	}

	body, err := json.Marshal(map[string]string{
		"receive_id": chatID,
		"msg_type":   msgType,
		"content":    content,
	})
	if err != nil {
		return fmt.Errorf("encode message body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		feishuAPIBase+"/open-apis/im/v1/messages?receive_id_type=chat_id",
		bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build send req: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := f.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send message: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Code int    `json:"code"`
		Msg  string `json:"msg"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return fmt.Errorf("decode send response: %w", err)
	}
	if result.Code == 99991671 || result.Code == 99991668 {
		return errFeishuInvalidToken
	}
	if result.Code != 0 {
		return fmt.Errorf("send message error: code=%d msg=%s", result.Code, result.Msg)
	}
	return nil
}

// Get 通用 GET，处理 token 注入与失效重试
func (f *FeishuApp) Get(ctx context.Context, url string, out any) error {
	for attempt := 0; attempt < 2; attempt++ {
		err := f.getOnce(ctx, url, out)
		if err == nil {
			return nil
		}
		if attempt == 0 && errors.Is(err, errFeishuInvalidToken) {
			f.invalidateToken()
			continue
		}
		return err
	}
	return nil
}

func (f *FeishuApp) getOnce(ctx context.Context, url string, out any) error {
	token, err := f.TenantAccessToken(ctx)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := f.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("feishu get: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read feishu response: %w", err)
	}
	// 探测错误码
	var probe struct {
		Code int `json:"code"`
	}
	_ = json.Unmarshal(body, &probe)
	if probe.Code == 99991671 || probe.Code == 99991668 {
		return errFeishuInvalidToken
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("decode feishu response: %w", err)
	}
	return nil
}

// handleMessageEvent 处理收到的消息事件（异步上下文，body 已通过中间件解密/验签）
func handleMessageEvent(ctx context.Context, app *FeishuApp, store *Store, body []byte) {
	var event struct {
		Event struct {
			Message struct {
				ChatID      string `json:"chat_id"`
				MessageType string `json:"message_type"`
				Content     string `json:"content"`
			} `json:"message"`
		} `json:"event"`
	}
	if err := json.Unmarshal(body, &event); err != nil {
		slog.Warn("decode message event failed", "err", err)
		return
	}

	if event.Event.Message.MessageType != "text" {
		return
	}

	var textContent struct {
		Text string `json:"text"`
	}
	_ = json.Unmarshal([]byte(event.Event.Message.Content), &textContent)
	text := strings.TrimSpace(textContent.Text)
	chatID := event.Event.Message.ChatID

	slog.Info("feishu message received", "chat_id", chatID, "text_len", len(text))

	// 命令白名单
	if allowed := app.allowedChatIDs(); len(allowed) > 0 {
		permitted := false
		for _, id := range allowed {
			if id == chatID {
				permitted = true
				break
			}
		}
		if !permitted {
			slog.Warn("feishu command rejected by chat allowlist", "chat_id", chatID)
			replyText(ctx, app, chatID, "本机器人未授权在该群响应命令")
			return
		}
	}

	// 命令路由
	switch {
	case text == "/help" || text == "帮助":
		replyText(ctx, app, chatID, "支持的命令：\n/list - 查看待处理工单\n/stats - 今日统计\n/help - 帮助")

	case text == "/list" || text == "待处理":
		handleListCommand(ctx, app, store, chatID)

	case text == "/stats" || text == "统计":
		handleStatsCommand(ctx, app, store, chatID)

	default:
		replyText(ctx, app, chatID, "未识别的命令，发送 /help 查看帮助")
	}
}

func handleListCommand(ctx context.Context, app *FeishuApp, store *Store, chatID string) {
	payload, err := store.Load(ctx)
	if err != nil {
		replyText(ctx, app, chatID, "读取数据失败")
		return
	}

	var lines []string
	for _, issue := range payload.TrackedIssues {
		if isResolvedStatus(issue.Status) {
			continue
		}
		dept := ""
		if issue.Department != nil && *issue.Department != "" {
			dept = " (" + *issue.Department + ")"
		}
		lines = append(lines, fmt.Sprintf("#%d [%s] %s%s", issue.IssueNumber, issue.Status, issue.Title, dept))
	}

	if len(lines) == 0 {
		replyText(ctx, app, chatID, "当前没有待处理工单")
		return
	}
	replyText(ctx, app, chatID, fmt.Sprintf("待处理工单（%d个）：\n%s", len(lines), strings.Join(lines, "\n")))
}

func handleStatsCommand(ctx context.Context, app *FeishuApp, store *Store, chatID string) {
	payload, err := store.Load(ctx)
	if err != nil {
		replyText(ctx, app, chatID, "读取数据失败")
		return
	}

	today := time.Now().Format("2006-01-02")
	newToday, resolvedToday, pending, scheduled, testing, observing := 0, 0, 0, 0, 0, 0
	for _, issue := range payload.TrackedIssues {
		isResolved := isResolvedStatus(issue.Status)
		if issue.DateKey == today && !isResolved {
			newToday++
		}
		if issue.ResolvedAt != nil && strings.HasPrefix(issue.ResolvedAt.Value, today) {
			resolvedToday++
		}
		switch issue.Status {
		case StatusScheduled:
			scheduled++
		case StatusTesting:
			testing++
		case StatusObserving:
			observing++
		default:
			if !isResolved {
				pending++
			}
		}
	}

	msg := fmt.Sprintf("今日统计：\n🟢 新建 %d  ✅ 解决 %d\n🔶 待处理 %d  📅 已排期 %d\n🧪 测试中 %d  👁 观测中 %d",
		newToday, resolvedToday, pending, scheduled, testing, observing)
	replyText(ctx, app, chatID, msg)
}

func handleCardStatusUpdate(ctx context.Context, store *Store, issueID, newStatus string) {
	if err := store.Update(ctx, func(payload *SyncPayload) error {
		for i := range payload.TrackedIssues {
			if payload.TrackedIssues[i].ID == issueID {
				applyIssueStatus(&payload.TrackedIssues[i], newStatus)
				now := FlexTime{Value: time.Now().Format("2006-01-02 15:04:05")}
				payload.TrackedIssues[i].UpdatedAt = &now
				slog.Info("issue status updated via card", "issue_id", issueID, "status", newStatus)
				break
			}
		}
		return nil
	}); err != nil {
		slog.Error("update issue from card failed", "issue_id", issueID, "err", err)
	}
}

func replyText(ctx context.Context, app *FeishuApp, chatID, text string) {
	content, _ := json.Marshal(map[string]string{"text": text})
	if err := app.SendMessage(ctx, chatID, "text", string(content)); err != nil {
		slog.Warn("feishu reply failed", "chat_id", chatID, "err", err)
	}
}

// HandleEventCallback 处理飞书事件回调（URL 验证 + 事件分发）
//
// 中间件已完成验签/解密/去重，body 通过 c.Get("feishu.body") 取出
func HandleEventCallback(app *FeishuApp, store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body []byte
		if v, exists := c.Get("feishu.body"); exists {
			if b, ok := v.([]byte); ok {
				body = b
			}
		}
		if body == nil {
			b, err := io.ReadAll(c.Request.Body)
			if err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "read body failed"})
				return
			}
			body = b
		}

		var raw map[string]json.RawMessage
		if err := json.Unmarshal(body, &raw); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid json"})
			return
		}

		// URL 验证挑战（schema 1.0 / 2.0 都使用顶层 challenge）
		if challengeRaw, ok := raw["challenge"]; ok {
			var challenge string
			_ = json.Unmarshal(challengeRaw, &challenge)
			c.JSON(http.StatusOK, gin.H{"challenge": challenge})
			return
		}

		// 解析事件类型
		var header struct {
			EventType string `json:"event_type"`
		}
		if h, ok := raw["header"]; ok {
			_ = json.Unmarshal(h, &header)
		}

		slog.Info("feishu event received", "event_type", header.EventType)

		// 立即响应 200，避免飞书 3s 超时重试；命令处理放后台
		c.JSON(http.StatusOK, gin.H{})

		switch header.EventType {
		case "im.message.receive_v1":
			go handleMessageEvent(context.Background(), app, store, body)
		case "task.task.update_v1", "task.task.update.v1",
			"task.task.create_v1", "task.task.create.v1":
			go handleTaskEvent(context.Background(), store, body)
		}
	}
}

// HandleCardAction 处理飞书卡片交互回调
//
// 中间件已完成验签/解密/去重，body 通过 c.Get("feishu.body") 取出
func HandleCardAction(app *FeishuApp, store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		var body []byte
		if v, exists := c.Get("feishu.body"); exists {
			if b, ok := v.([]byte); ok {
				body = b
			}
		}
		if body == nil {
			b, err := io.ReadAll(c.Request.Body)
			if err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "read body failed"})
				return
			}
			body = b
		}

		var action struct {
			Action struct {
				Tag    string                 `json:"tag"`
				Value  map[string]any         `json:"value"`
				Option string                 `json:"option"`
				Form   map[string]any         `json:"form_value"`
				Extra  map[string]interface{} `json:"-"`
			} `json:"action"`
		}
		if err := json.Unmarshal(body, &action); err != nil {
			c.JSON(http.StatusOK, gin.H{})
			return
		}

		issueID, _ := action.Action.Value["issue_id"].(string)
		actionType, _ := action.Action.Value["action"].(string)

		if issueID == "" || actionType == "" {
			c.JSON(http.StatusOK, gin.H{})
			return
		}

		slog.Info("feishu card action", "action", actionType, "issue_id", issueID)

		ctx := c.Request.Context()
		switch actionType {
		case "update_status":
			newStatus := action.Action.Option
			if newStatus == "" {
				if v, ok := action.Action.Value["status"].(string); ok {
					newStatus = v
				}
			}
			if newStatus != "" {
				handleCardStatusUpdate(ctx, store, issueID, newStatus)
				c.JSON(http.StatusOK, gin.H{
					"toast": gin.H{"type": "success", "content": "已更新状态：" + newStatus},
				})
				return
			}
		}

		c.JSON(http.StatusOK, gin.H{})
	}
}

// handleTaskEvent 处理飞书任务事件，回流到本地 issue
func handleTaskEvent(ctx context.Context, store *Store, body []byte) {
	var event struct {
		Header struct {
			EventType string `json:"event_type"`
		} `json:"header"`
		Event struct {
			ObjectType string `json:"object_type"`
			Task       struct {
				GUID        string `json:"guid"`
				Summary     string `json:"summary"`
				Description string `json:"description"`
				CompletedAt string `json:"completed_at"`
				Completed   bool   `json:"completed"`
			} `json:"task"`
			TaskID string `json:"task_id"` // 兼容旧 schema
		} `json:"event"`
	}
	if err := json.Unmarshal(body, &event); err != nil {
		slog.Warn("decode task event failed", "err", err)
		return
	}
	guid := event.Event.Task.GUID
	if guid == "" {
		guid = event.Event.TaskID
	}
	if guid == "" {
		slog.Warn("task event missing guid", "event_type", event.Header.EventType)
		return
	}
	completed := event.Event.Task.Completed ||
		(event.Event.Task.CompletedAt != "" && event.Event.Task.CompletedAt != "0")
	UpsertIssueFromFeishuTask(ctx, store, guid,
		strings.TrimSpace(event.Event.Task.Summary),
		event.Event.Task.Description,
		completed)
}
