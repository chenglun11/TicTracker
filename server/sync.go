package main

import (
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
)

func HandleGetSync(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		data, err := store.LoadRaw()
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

func HandlePostSync(store *Store) gin.HandlerFunc {
	return func(c *gin.Context) {
		body, err := c.GetRawData()
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "failed to read body"})
			return
		}

		if err := store.ReplaceRaw(body); err != nil {
			msg := err.Error()
			if strings.Contains(msg, "invalid json") || strings.Contains(msg, "lastModified") {
				c.JSON(http.StatusBadRequest, gin.H{"error": msg})
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": msg})
			return
		}

		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	}
}
