package main

import (
	"log"

	"github.com/gin-gonic/gin"
)

func main() {
	cfg, err := LoadConfig("config.yaml")
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	r := gin.Default()

	r.Use(AuthMiddleware(cfg.Token))

	r.GET("/sync", HandleGetSync(cfg.DataDir))
	r.POST("/sync", HandlePostSync(cfg.DataDir))

	scheduler := NewScheduler(cfg, cfg.DataDir)
	go scheduler.Start()

	log.Printf("starting server on :%s", cfg.Port)
	if err := r.Run(":" + cfg.Port); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
