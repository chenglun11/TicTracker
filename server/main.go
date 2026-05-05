package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

func main() {
	// 结构化日志：默认 stderr + JSON；TICTRACKER_LOG=text 切换为人类可读
	var handler slog.Handler
	if os.Getenv("TICTRACKER_LOG") == "text" {
		handler = slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})
	} else {
		handler = slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})
	}
	slog.SetDefault(slog.New(handler))

	cfg, err := LoadConfig("config.yaml")
	if err != nil {
		slog.Error("failed to load config", "err", err)
		os.Exit(1)
	}

	store, err := NewStore(cfg.DataDir)
	if err != nil {
		slog.Error("failed to init store", "err", err)
		os.Exit(1)
	}

	// 生产模式默认关闭 gin debug 日志
	if os.Getenv("GIN_MODE") == "" {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.Recovery())

	// 全局请求体大小上限（DoS 防护）
	bodyLimit := cfg.MaxBodyBytes
	if bodyLimit <= 0 {
		bodyLimit = 10 << 20
	}
	r.Use(func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, bodyLimit)
		c.Next()
	})

	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})

	// 前端静态资源（无需认证）
	ServeWeb(r)

	// 同步路由（macOS 客户端 → /sync）
	sync := r.Group("/", AuthMiddleware(cfg.SyncAccessToken()))
	sync.GET("/sync", HandleGetSync(store))
	sync.POST("/sync", HandlePostSync(store))

	// 飞书应用回调
	feishuApp := NewFeishuApp(cfg, store)
	feishuTask := NewFeishuTaskClient(feishuApp)

	// 飞书事件 / 卡片回调：挂载验签中间件（验签失败/重放/重复事件直接拦截）
	feishuVerify := FeishuVerifyMiddleware(FeishuVerifyOptions{
		VerificationToken: feishuApp.VerificationToken(),
		EncryptKey:        feishuApp.EncryptKey(),
		BodyLimit:         bodyLimit,
		Dedup:             newEventDedup(),
	})
	r.POST("/feishu/event", feishuVerify, HandleEventCallback(feishuApp, store))
	r.POST("/feishu/card", feishuVerify, HandleCardAction(feishuApp, store))
	if feishuApp.Enabled() {
		slog.Info("feishu app enabled", "app_id", cfg.FeishuAppID)
	} else {
		slog.Warn("feishu app credentials missing — /feishu/event 处理事件需 app_id+app_secret")
	}
	if feishuApp.EncryptKey() == "" {
		slog.Warn("feishu encrypt_key not configured — /feishu/event 不会执行签名校验，强烈建议在飞书后台开启加密推送并填充配置")
	}

	registerWebAPI := func(group *gin.RouterGroup) {
		group.GET("/status", HandleGetStatus(store))
		group.GET("/issues", HandleGetIssues(store))
		group.GET("/feishu/tasks", HandleListFeishuTasks(store, feishuTask))
		group.GET("/feishu/tasks/test", HandleTestFeishuTasks(store, feishuTask))
		group.POST("/feishu/send", HandleSendFeishu(store))
		group.PATCH("/issues/:id", HandleUpdateIssue(store, feishuTask))
		group.POST("/issues/:id/comments", HandleAddComment(store))
		group.POST("/issues", HandleCreateIssue(store, feishuTask))
		group.DELETE("/issues/:id", HandleDeleteIssue(store))
	}

	api := r.Group("/api", AuthMiddleware(cfg.WebAccessToken()))
	registerWebAPI(api)
	apiV1 := r.Group("/api/v1", AuthMiddleware(cfg.WebAccessToken()))
	registerWebAPI(apiV1)

	// 调度器：可被 ctx 取消
	schedulerCtx, schedulerCancel := context.WithCancel(context.Background())
	scheduler := NewScheduler(cfg, store)
	go scheduler.Run(schedulerCtx)

	bind := cfg.Bind
	if bind == "" {
		bind = "127.0.0.1"
	}
	server := &http.Server{
		Addr:              bind + ":" + cfg.Port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	listenErr := make(chan error, 1)
	go func() {
		slog.Info("server starting", "addr", server.Addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			listenErr <- err
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	select {
	case <-quit:
		slog.Info("shutdown signal received")
	case err := <-listenErr:
		slog.Error("server listen error", "err", err)
	}

	// 优雅关闭：先停 scheduler，再 shutdown server
	schedulerCancel()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		slog.Error("server shutdown error", "err", err)
	}
	slog.Info("server stopped")
}
