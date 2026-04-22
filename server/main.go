package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

func main() {
	cfg, err := LoadConfig("config.yaml")
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	store := NewStore(cfg.DataDir)
	r := gin.Default()

	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})

	// 前端静态资源（无需认证）
	ServeWeb(r)

	// 需要认证的同步路由
	sync := r.Group("/", AuthMiddleware(cfg.SyncAccessToken()))
	sync.GET("/sync", HandleGetSync(store))
	sync.POST("/sync", HandlePostSync(store))

	registerWebAPI := func(group *gin.RouterGroup) {
		group.GET("/status", HandleGetStatus(store))
		group.GET("/issues", HandleGetIssues(store))
		group.POST("/feishu/send", HandleSendFeishu(store))
		group.PATCH("/issues/:id", HandleUpdateIssue(store))
		group.POST("/issues/:id/comments", HandleAddComment(store))
		group.POST("/issues", HandleCreateIssue(store))
		group.DELETE("/issues/:id", HandleDeleteIssue(store))
	}

	// Web API：保留 /api 兼容，同时提供新版 /api/v1
	api := r.Group("/api", AuthMiddleware(cfg.WebAccessToken()))
	registerWebAPI(api)
	apiV1 := r.Group("/api/v1", AuthMiddleware(cfg.WebAccessToken()))
	registerWebAPI(apiV1)

	scheduler := NewScheduler(cfg, store)
	go scheduler.Start()

	server := &http.Server{
		Addr:    ":" + cfg.Port,
		Handler: r,
	}

	go func() {
		log.Printf("starting server on :%s", cfg.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("shutting down server...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("server shutdown error: %v", err)
	}
	log.Println("server stopped")
}
