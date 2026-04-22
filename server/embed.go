package main

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

//go:embed web/dist
var webFS embed.FS

func ServeWeb(r *gin.Engine) {
	distFS, err := fs.Sub(webFS, "web/dist")
	if err != nil {
		return
	}

	// 静态资源
	r.GET("/assets/*filepath", func(c *gin.Context) {
		c.FileFromFS(c.Request.URL.Path, http.FS(distFS))
	})

	// favicon
	r.GET("/favicon.ico", func(c *gin.Context) {
		c.FileFromFS("favicon.ico", http.FS(distFS))
	})

	// SPA fallback
	r.NoRoute(func(c *gin.Context) {
		path := c.Request.URL.Path
		if strings.HasPrefix(path, "/api") || strings.HasPrefix(path, "/sync") {
			c.JSON(404, gin.H{"error": "not found"})
			return
		}
		data, err := fs.ReadFile(distFS, "index.html")
		if err != nil {
			c.String(500, "page not found")
			return
		}
		c.Data(200, "text/html; charset=utf-8", data)
	})
}
