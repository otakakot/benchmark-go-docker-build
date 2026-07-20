package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

func main() {
	engine := gin.Default()

	engine.GET("/", func(ctx *gin.Context) {
		ctx.JSON(http.StatusOK, "ok")
	})

	engine.GET("/health", func(ctx *gin.Context) {
		ctx.JSON(http.StatusOK, "ok")
	})

	engine.GET("/ping", func(ctx *gin.Context) {
		ctx.JSON(http.StatusOK, "pong")
	})

	if err := engine.Run(); err != nil {
		panic(err)
	}
}
