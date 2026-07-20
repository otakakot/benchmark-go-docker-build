package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

func main() {
	engine := gin.Default()

	engine.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(http.StatusOK, "ok")
	})

	if err := engine.Run(); err != nil {
		panic(err)
	}
}
